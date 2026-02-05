defmodule Pod.BroadcasterSupervisor.Handler.AudioFrame do
  alias Pod.BroadcasterSupervisor.Ingest
  require Logger
  import Bitwise

  def parse_rtmp_audio_frame(buffer) do
    Logger.debug("parse_rtmp_audio_frame called, buffer: #{byte_size(buffer)} bytes")

    case buffer do
      <<_fmt::2, _csid::6, _ts::24, len::24, type::8, _stream_id::32-little, rest::binary>> ->
        Logger.info("=== MESSAGE HEADER ===")
        Logger.info("Type: #{type}, Length: #{len}")

        if byte_size(rest) >= len do
          <<payload::binary-size(len), remaining::binary>> = rest

          case type do
            8 ->
              Logger.info("✓ AUDIO FRAME")
              {:ok, payload, remaining}

            type when type in [1, 2, 3, 4, 5, 6] ->
              Logger.debug("Control message type #{type}")
              {:control_message, type, remaining}

            20 ->
              Logger.info("AMF COMMAND")
              {:amf_command, payload, remaining}

            _ ->
              Logger.warning("Unknown message type: #{type}")
              {:control_message, type, remaining}
          end
        else
          {:incomplete, buffer}
        end

      _ ->
        {:incomplete, buffer}
    end
  end

  def handle_audio_frame(buffer, state) do
    case parse_rtmp_audio_frame(buffer) do
      {:ok, payload, remaining} ->
        # Extract and classify the audio
        case extract_aac_audio(payload, state) do
          {:config, aac_config, new_state} ->
            Logger.info("✓ Received AAC config, storing it")
            %{new_state | aac_config: aac_config, buffer: remaining}

          {:frame, frame, new_state} ->
            Logger.debug("✓ Received AAC frame: #{byte_size(frame)} bytes")
            Ingest.AudioBuffer.push(new_state.audio_buffer, frame)

            case Ingest.AudioBuffer.status(new_state.audio_buffer) do
              {:full, frames} ->
                Logger.info("✓ Buffer full! Saving #{length(frames)} frames")
                save_audio_to_file(frames, new_state.aac_config, new_state.id)
                Ingest.AudioBuffer.clear(new_state.audio_buffer)
                %{new_state | buffer: remaining}

              {:not_full, count} ->
                Logger.debug("Buffer: #{count}/3 frames")
                %{new_state | buffer: remaining}
            end

          {:ignore, new_state} ->
            Logger.debug("Ignoring audio frame")
            %{new_state | buffer: remaining}
        end

      {:control_message, msg_type, remaining} ->
        Logger.debug("Skipping control message #{msg_type}")
        handle_audio_frame(remaining, state)

      {:amf_command, payload, remaining} ->
        Logger.info("Processing AMF command")
        handle_amf_command(payload, state.socket)
        handle_audio_frame(remaining, state)

      {:incomplete, _} ->
        Logger.debug("Incomplete frame, waiting for more data")
        state
    end
  end

  # ===== Audio Extraction =====

  # AAC sequence header (AudioSpecificConfig)
  defp extract_aac_audio(<<_sound::8, 0, config::binary>>, state) do
    Logger.info("✓ AAC config frame received (#{byte_size(config)} bytes)")
    Logger.info("Config hex: #{inspect(config, base: :hex)}")
    aac_config = parse_aac_config(config)
    Logger.info("Parsed AAC config: #{inspect(aac_config)}")
    {:config, aac_config, state}
  end

  # AAC raw frame
  defp extract_aac_audio(<<_sound::8, 1, aac::binary>>, state) when byte_size(aac) > 0 do
    Logger.debug("✓ AAC raw frame received (#{byte_size(aac)} bytes)")
    {:frame, aac, state}
  end

  # Fallback
  defp extract_aac_audio(payload, state) do
    Logger.warning("Unknown audio frame format: #{inspect(binary_part(payload, 0, min(4, byte_size(payload))), base: :hex)}")
    {:ignore, state}
  end

  defp parse_aac_config(<<
         audio_object_type::5,
         sampling_freq_index::4,
         channel_config::4,
         _::bitstring
       >>) do
    %{
      profile: audio_object_type - 1,
      sample_rate_index: sampling_freq_index,
      channels: channel_config
    }
  end

  defp parse_aac_config(_) do
    Logger.warning("Failed to parse AAC config")
    %{profile: 1, sample_rate_index: 3, channels: 2}
  end

  # ===== File Saving =====

  def save_audio_to_file(frames, aac_config, broadcaster_id)
      when not is_nil(aac_config) do
    try do
      file_dir = "tmp/broadcasts"
      File.mkdir_p!(file_dir)

      filename = "#{file_dir}/broadcast_#{broadcaster_id}.aac"

      frames
      |> Enum.map(&add_adts_header(&1, aac_config))
      |> IO.iodata_to_binary()
      |> then(&File.write!(filename, &1, [:append]))

      file_stat = File.stat!(filename)

      Logger.info("✓ Saved #{length(frames)} frames to: #{filename}")
      Logger.info("  File size: #{file_stat.size} bytes")
      Logger.info("  AAC config: #{inspect(aac_config)}")
    rescue
      e ->
        Logger.error("Error saving file: #{inspect(e)}")
    end
  end

  def save_audio_to_file(_frames, nil, _stream_id) do
    Logger.warning("AAC config not yet received, skipping write")
    :ok
  end

  defp add_adts_header(frame, %{
         profile: profile,
         sample_rate_index: sr_index,
         channels: channels
       }) do
    frame_length = byte_size(frame) + 7

    # Build ADTS header with correct bit layout
    byte0 = 0xFF
    byte1 = 0xF1
    byte2 = (profile <<< 6) ||| (sr_index <<< 2) ||| (channels >>> 2)
    byte3 = ((channels &&& 3) <<< 6) ||| (frame_length >>> 11)
    byte4 = (frame_length >>> 3) &&& 0xFF
    byte5 = ((frame_length &&& 7) <<< 5) ||| 0x1F
    byte6 = 0xFC

    Logger.debug("ADTS header: #{inspect(<<byte0, byte1, byte2, byte3, byte4, byte5, byte6>>, base: :hex)}")

    <<byte0, byte1, byte2, byte3, byte4, byte5, byte6>> <> frame
  end

  # ===== AMF Commands =====

  defp handle_amf_command(payload, socket) do
    case payload do
      <<2::8, cmd_len::16, cmd::binary-size(cmd_len), rest::binary>> ->
        Logger.info("AMF Command: #{cmd}")

        case cmd do
          "connect" ->
            Logger.info("✓ CONNECT command")

            case parse_connect_properties(rest) do
              {:ok, properties} ->
                Logger.info("CONNECT properties: #{inspect(properties)}")
                send_amf_connect_response(socket)

              :error ->
                Logger.warning("Could not parse CONNECT properties")
                send_amf_connect_response(socket)
            end

          "createStream" ->
            Logger.info("✓ CREATE_STREAM")
            send_amf_create_stream_response(socket)

          "publish" ->
            Logger.info("✓ PUBLISH")
            send_amf_publish_response(socket)

          cmd ->
            Logger.warning("Unknown AMF command: #{cmd}")
        end

      _ ->
        Logger.warning("Could not parse AMF command")
    end
  end

  defp parse_connect_properties(buffer) do
    case buffer do
      <<0::8, _txn::float-64, rest::binary>> ->
        case rest do
          <<3::8, obj_rest::binary>> ->
            parse_amf_object(obj_rest, %{})

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_amf_object(buffer, acc) do
    case buffer do
      <<0::16, 9::8, rest::binary>> ->
        {:ok, acc, rest}

      <<key_len::16, key::binary-size(key_len), rest::binary>> ->
        case parse_amf_value(rest) do
          {:ok, value, remaining} ->
            new_acc = Map.put(acc, key, value)
            parse_amf_object(remaining, new_acc)

          error ->
            error
        end

      _ ->
        :error
    end
  end

  defp parse_amf_value(buffer) do
    case buffer do
      <<0::8, value::float-64, rest::binary>> -> {:ok, value, rest}
      <<1::8, value::8, rest::binary>> -> {:ok, value != 0, rest}
      <<2::8, len::16, value::binary-size(len), rest::binary>> -> {:ok, value, rest}
      <<5::8, rest::binary>> -> {:ok, nil, rest}
      <<3::8, rest::binary>> -> parse_amf_object(rest, %{})
      _ -> :error
    end
  end

  # ===== AMF Response Builders =====

  defp send_amf_connect_response(socket) do
    response =
      amf_string("_result") <>
        amf_number(1.0) <>
        amf_object(%{
          "fmsVer" => "FMS/3,5,7,7009",
          "capabilities" => 31.0
        }) <>
        amf_object(%{
          "level" => "status",
          "code" => "NetConnection.Connect.Success",
          "description" => "Connection succeeded.",
          "objectEncoding" => 0.0
        })

    Logger.info("✓ Sending CONNECT response")
    :gen_tcp.send(socket, response)
  end

  defp send_amf_create_stream_response(socket) do
    response =
      amf_string("_result") <>
        amf_number(2.0) <>
        amf_null() <>
        amf_number(1.0)

    Logger.info("✓ Sending CREATE_STREAM response")
    :gen_tcp.send(socket, response)
  end

  defp send_amf_publish_response(socket) do
    response =
      amf_string("onStatus") <>
        amf_number(0.0) <>
        amf_null() <>
        amf_object(%{
          "level" => "status",
          "code" => "NetStream.Publish.Start",
          "description" => "Stream is now published.",
          "details" => "test-broadcast",
          "clientid" => 1.0
        })

    Logger.info("✓ Sending PUBLISH response")
    :gen_tcp.send(socket, response)
  end

  # ===== AMF Encoders =====

  defp amf_string(str) do
    bytes = str |> String.to_charlist() |> Enum.map(&<<&1>>) |> IO.iodata_to_binary()
    <<2::8, byte_size(bytes)::16>> <> bytes
  end

  defp amf_number(num) when is_number(num) do
    <<0::8, num::float-64>>
  end

  defp amf_null() do
    <<5::8>>
  end

  defp amf_object(map) when is_map(map) do
    obj = <<3::8>>

    obj =
      Enum.reduce(map, obj, fn {key, value}, acc ->
        key_bytes = key |> String.to_charlist() |> Enum.map(&<<&1>>) |> IO.iodata_to_binary()
        acc <> <<byte_size(key_bytes)::16>> <> key_bytes <> encode_value(value)
      end)

    obj <> <<0::16, 9::8>>
  end

  defp encode_value(value) when is_number(value), do: amf_number(value)
  defp encode_value(value) when is_binary(value), do: amf_string(value)
  defp encode_value(true), do: <<1::8, 1::8>>
  defp encode_value(false), do: <<1::8, 0::8>>
  defp encode_value(nil), do: <<5::8>>
end
