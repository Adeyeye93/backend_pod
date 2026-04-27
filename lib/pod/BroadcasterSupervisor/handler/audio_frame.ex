defmodule Pod.BroadcasterSupervisor.Handler.AudioFrame do
  @moduledoc """
  Parses RTMP frames and dispatches audio to the transcoder pool.

  This is a plain module — no process, no state. It is called from
  Season.handle_info and always returns an updated state map back to Season.
  Season is the single owner of all state transitions.

  ## Return values from handle_audio_frame/2

  Always returns the updated state. Season pattern matches on
  `state.state` after the call to detect any transitions that occurred
  (e.g. :pending → :streaming after successful publish auth).

  The "publish" AMF command is a special case — instead of calling back
  into Season (which would deadlock since we are already inside a
  Season callback), AudioFrame extracts the stream key and returns it
  as a tagged value in the state:

      %{state | pending_auth: stream_key}

  Season then handles the authentication itself after handle_audio_frame
  returns, avoiding any re-entrant GenServer call.
  """

  alias Pod.BroadcasterSupervisor.Ingest
  alias Pod.BroadcasterSupervisor.Ingest.TranscoderPool
  alias Pod.BroadcasterSupervisor.Ingest.Transcoder
  require Logger

  # ---------------------------------------------------------------------------
  # RTMP frame parsing
  # ---------------------------------------------------------------------------

  def parse_rtmp_audio_frame(buffer) do
    case buffer do
      <<_fmt::2, _csid::6, _ts::24, len::24, type::8, _stream_id::32-little, rest::binary>> ->
        if byte_size(rest) >= len do
          <<payload::binary-size(len), remaining::binary>> = rest

          case type do
            8  -> {:ok, payload, remaining}
            20 -> {:amf_command, payload, remaining}
            t when t in [1, 2, 3, 4, 5, 6] -> {:control_message, t, remaining}
            _  -> {:control_message, type, remaining}
          end
        else
          {:incomplete, buffer}
        end

      _ ->
        {:incomplete, buffer}
    end
  end

  # ---------------------------------------------------------------------------
  # Main entry point — called from Season.handle_info(:start_reading)
  # Always returns updated state.
  # ---------------------------------------------------------------------------

  def handle_audio_frame(buffer, state) do
    case parse_rtmp_audio_frame(buffer) do
      {:ok, payload, remaining} ->
        handle_audio_payload(payload, remaining, state)

      {:amf_command, payload, remaining} ->
        Logger.info("[AudioFrame] AMF command received")
        new_state = handle_amf_command(payload, %{state | buffer: remaining})
        # Continue processing any remaining bytes after the AMF command
        handle_audio_frame(new_state.buffer, new_state)

      {:control_message, msg_type, remaining} ->
        Logger.debug("[AudioFrame] Skipping control message type #{msg_type}")
        handle_audio_frame(remaining, state)

      {:incomplete, _} ->
        Logger.debug("[AudioFrame] Incomplete frame, waiting for more data")
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Audio payload handling
  # ---------------------------------------------------------------------------

  defp handle_audio_payload(payload, remaining, state) do
    case extract_aac_audio(payload) do
      {:config, aac_config} ->
        Logger.info("[AudioFrame] ✓ AAC config received — profile: #{aac_config.profile}, " <>
          "sample_rate_index: #{aac_config.sample_rate_index}, channels: #{aac_config.channels}")
        %{state | aac_config: aac_config, buffer: remaining}

      {:frame, frame} ->
        Logger.debug("[AudioFrame] ✓ AAC frame #{byte_size(frame)} bytes")
        Ingest.AudioBuffer.push(state.audio_buffer, frame)

        # Update last_audio_at so health monitoring and circuit breaker
        # can detect stalled streams
        new_state = %{state |
          buffer: remaining,
          last_audio_at: DateTime.utc_now(),
          frames_in: state.frames_in + 1
        }

        case Ingest.AudioBuffer.status(new_state.audio_buffer) do
          {:full, frames} ->
            Logger.info("[AudioFrame] Buffer full — dispatching #{length(frames)} frames")
            flush_and_transcode(frames, new_state)
            Ingest.AudioBuffer.clear(new_state.audio_buffer)
            new_state

          {:not_full, count} ->
            Logger.debug("[AudioFrame] Buffer #{count}/3")
            new_state
        end

      :ignore ->
        %{state | buffer: remaining}
    end
  end

  # ---------------------------------------------------------------------------
  # Transcode dispatch
  # Called both from buffer-full path above and from Season's flush_timeout
  # ---------------------------------------------------------------------------

  @doc """
  Checks out a worker from the pool and dispatches frames for transcoding.
  The result arrives back in Season as {:transcoded, result}.

  Guards:
  - aac_config must be present — required to build ADTS headers for FFmpeg
  - live_stream_id must be set — means authentication succeeded
  - Pool must have an available worker — drops if all busy (backpressure TBD)
  """
  def flush_and_transcode(_frames, %{aac_config: nil}) do
    Logger.warning("[AudioFrame] Cannot transcode — no AAC config yet, dropping")
    :ok
  end

  def flush_and_transcode(_frames, %{live_stream_id: nil}) do
    Logger.warning("[AudioFrame] Cannot transcode — stream not authenticated yet, dropping")
    :ok
  end

  def flush_and_transcode(frames, state) do
    case TranscoderPool.checkout() do
      {:ok, worker} ->
        Transcoder.transcode(worker, frames, state.aac_config, self())

      :busy ->
        Logger.warning("[AudioFrame] Transcoder pool busy — dropping #{length(frames)} " <>
          "frames for stream #{state.live_stream_id}")
    end
  end

  # ---------------------------------------------------------------------------
  # AAC audio extraction
  # ---------------------------------------------------------------------------

  # AAC sequence header — carries the config, not playable audio
  defp extract_aac_audio(<<_sound::8, 0, config::binary>>) do
    {:config, parse_aac_config(config)}
  end

  # Raw AAC frame — actual audio data
  defp extract_aac_audio(<<_sound::8, 1, aac::binary>>) when byte_size(aac) > 0 do
    {:frame, aac}
  end

  defp extract_aac_audio(payload) do
    Logger.warning("[AudioFrame] Unknown format: " <>
      inspect(binary_part(payload, 0, min(4, byte_size(payload))), base: :hex))
    :ignore
  end

  defp parse_aac_config(<<audio_object_type::5, sampling_freq_index::4, channel_config::4, _::bitstring>>) do
    %{
      profile: audio_object_type - 1,
      sample_rate_index: sampling_freq_index,
      channels: channel_config
    }
  end

  defp parse_aac_config(_) do
    Logger.warning("[AudioFrame] Could not parse AAC config — using defaults")
    %{profile: 1, sample_rate_index: 3, channels: 2}
  end

  # ---------------------------------------------------------------------------
  # AMF command handling
  #
  # Returns updated state. The "publish" command is the key one —
  # instead of calling back into Season (deadlock), it sets
  # state.pending_auth = stream_key and returns. Season picks this up
  # after handle_audio_frame returns and handles auth itself.
  # ---------------------------------------------------------------------------

  defp handle_amf_command(payload, state) do
    case payload do
      <<2::8, cmd_len::16, cmd::binary-size(cmd_len), rest::binary>> ->
        Logger.info("[AudioFrame] AMF command: #{cmd}")

        case cmd do
          "connect" ->
            handle_connect(rest, state)

          "createStream" ->
            Logger.info("[AudioFrame] ✓ createStream")
            send_amf_create_stream_response(state.socket)
            state

          "publish" ->
            Logger.info("[AudioFrame] ✓ publish — extracting stream key")
            handle_publish(rest, state)

          other ->
            Logger.warning("[AudioFrame] Unknown AMF command: #{other}")
            state
        end

      _ ->
        Logger.warning("[AudioFrame] Could not parse AMF payload")
        state
    end
  end

  defp handle_connect(rest, state) do
    case parse_connect_properties(rest) do
      {:ok, properties} ->
        Logger.info("[AudioFrame] ✓ connect — app: #{properties["app"]}")
      :error ->
        Logger.warning("[AudioFrame] connect — could not parse properties")
    end

    send_amf_connect_response(state.socket)
    state
  end

  # ---------------------------------------------------------------------------
  # Publish — stream key extraction
  #
  # AMF publish payload after the command name:
  #   [0x00][float64]  — transaction ID
  #   [0x05]           — AMF null
  #   [0x02][u16][str] — stream key as AMF string
  #   [0x02][u16][str] — publish type ("live") — ignored
  #
  # We do NOT call Season.authenticate here to avoid a deadlock.
  # We set pending_auth on state and return — Season handles auth
  # after this function returns.
  # ---------------------------------------------------------------------------

  defp handle_publish(rest, state) do
    case rest do
      <<0::8, _txn::float-64, 5::8, 2::8, key_len::16,
        stream_key::binary-size(key_len), _rest::binary>> ->
        Logger.info("[AudioFrame] Stream key extracted — signalling Season to authenticate")
        # Tag the state — Season will see this and call Stream.authenticate_stream
        %{state | pending_auth: stream_key}

      _ ->
        Logger.warning("[AudioFrame] Could not parse publish payload — closing")
        send_amf_publish_error(state.socket, "Could not read stream key.")
        :gen_tcp.close(state.socket)
        state
    end
  end

  # ---------------------------------------------------------------------------
  # AMF property parsers
  # ---------------------------------------------------------------------------

  defp parse_connect_properties(buffer) do
    case buffer do
      <<0::8, _txn::float-64, rest::binary>> ->
        case rest do
          <<3::8, obj_rest::binary>> -> parse_amf_object(obj_rest, %{})
          _ -> :error
        end
      _ -> :error
    end
  end

  defp parse_amf_object(buffer, acc) do
    case buffer do
      <<0::16, 9::8, _rest::binary>> ->
        {:ok, acc}

      <<key_len::16, key::binary-size(key_len), rest::binary>> ->
        case parse_amf_value(rest) do
          {:ok, value, remaining} ->
            parse_amf_object(remaining, Map.put(acc, key, value))
          error ->
            error
        end

      _ -> :error
    end
  end

  defp parse_amf_value(buffer) do
    case buffer do
      <<0::8, value::float-64, rest::binary>>            -> {:ok, value, rest}
      <<1::8, value::8, rest::binary>>                   -> {:ok, value != 0, rest}
      <<2::8, len::16, value::binary-size(len), rest::binary>> -> {:ok, value, rest}
      <<5::8, rest::binary>>                             -> {:ok, nil, rest}
      <<3::8, rest::binary>>                             -> parse_amf_object(rest, %{})
      _                                                  -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # AMF response builders
  # ---------------------------------------------------------------------------

  defp send_amf_connect_response(socket) do
    response =
      amf_string("_result") <>
      amf_number(1.0) <>
      amf_object(%{"fmsVer" => "FMS/3,5,7,7009", "capabilities" => 31.0}) <>
      amf_object(%{
        "level"          => "status",
        "code"           => "NetConnection.Connect.Success",
        "description"    => "Connection succeeded.",
        "objectEncoding" => 0.0
      })

    :gen_tcp.send(socket, response)
  end

  defp send_amf_create_stream_response(socket) do
    response = amf_string("_result") <> amf_number(2.0) <> amf_null() <> amf_number(1.0)
    :gen_tcp.send(socket, response)
  end

  def send_amf_publish_response(socket) do
    response =
      amf_string("onStatus") <>
      amf_number(0.0) <>
      amf_null() <>
      amf_object(%{
        "level"       => "status",
        "code"        => "NetStream.Publish.Start",
        "description" => "Stream is now published.",
        "clientid"    => 1.0
      })

    :gen_tcp.send(socket, response)
  end

  def send_amf_publish_error(socket, description) do
    response =
      amf_string("onStatus") <>
      amf_number(0.0) <>
      amf_null() <>
      amf_object(%{
        "level"       => "error",
        "code"        => "NetStream.Publish.BadName",
        "description" => description
      })

    :gen_tcp.send(socket, response)
  end

  # ---------------------------------------------------------------------------
  # AMF encoders
  # ---------------------------------------------------------------------------

  defp amf_string(str) do
    bytes = :binary.list_to_bin(String.to_charlist(str))
    <<2::8, byte_size(bytes)::16>> <> bytes
  end

  defp amf_number(num) when is_number(num), do: <<0::8, num::float-64>>

  defp amf_null, do: <<5::8>>

  defp amf_object(map) when is_map(map) do
    pairs =
      Enum.reduce(map, <<>>, fn {key, value}, acc ->
        key_bytes = :binary.list_to_bin(String.to_charlist(key))
        acc <> <<byte_size(key_bytes)::16>> <> key_bytes <> encode_value(value)
      end)

    <<3::8>> <> pairs <> <<0::16, 9::8>>
  end

  defp encode_value(v) when is_number(v),  do: amf_number(v)
  defp encode_value(v) when is_binary(v),  do: amf_string(v)
  defp encode_value(true),                 do: <<1::8, 1::8>>
  defp encode_value(false),                do: <<1::8, 0::8>>
  defp encode_value(nil),                  do: <<5::8>>
end
