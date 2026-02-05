defmodule Pod.BroadcasterSupervisor.Ingest.TranscoderPool do
  def checkout do
    case :ets.match(:transcoder_pool, {:"$1", :idle}) do
      [[pid] | _] ->
        :ets.insert(:transcoder_pool, {pid, :busy})
        {:ok, pid}

      [] ->
        :busy
    end
  end

  def checkin(pid) do
    :ets.insert(:transcoder_pool, {pid, :idle})
  end

end
