defmodule Pod.HandshakeTest do
  use ExUnit.Case

  test "completes simple handshake" do
    c1 = :crypto.strong_rand_bytes(1536)

    state = %{
      handshake_state: :c0,
      buffer: <<3>> <> c1,
      socket: nil
    }

    {:ok, state} = RTMP.Protocol.Handshake.handle(state)
    assert state.handshake_state == :c1
  end
end
