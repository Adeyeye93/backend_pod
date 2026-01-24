defmodule Pod.BroadcasterSupervisor.RTMP.HandsakeProtocol do
  @rtmp_version 3
  @hs_size 1536

  def handle(%{hs: :c0, buffer: <<@rtmp_version, rest::binary>>} = st) do
    s1 = s1()
    s0 = <<@rtmp_version>>

    {
      :ok,
      %{st | hs: :c1, buffer: rest, s1: s1},
      [{:send, s0 <> s1}]
    }
  end

  def handle(%{hs: :c1, buffer: buffer} = st)
      when byte_size(buffer) >= @hs_size do
    <<c1::binary-size(@hs_size), rest::binary>> = buffer

    s2 = c1

    {
      :ok,
      %{st | hs: :c2, buffer: rest},
      [{:send, s2}]
    }
  end

  def handle(%{hs: :c2, buffer: buffer} = st)
      when byte_size(buffer) >= @hs_size do
    <<_c2::binary-size(@hs_size), rest::binary>> = buffer

    {
      :done,
      %{st | hs: :ready, buffer: rest}
    }
  end

  def handle(st), do: {:more, st}

  defp s1 do
    time = System.system_time(:second)
    <<time::32, 0::32, :crypto.strong_rand_bytes(@hs_size - 8)::binary>>
  end
end
