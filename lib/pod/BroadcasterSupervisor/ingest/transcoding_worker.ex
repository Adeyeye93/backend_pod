defmodule Pod.BroadcasterSupervisor.Ingest.TranscodingWorker do
  def start_link(_) do
    Pod.BroadcasterSupervisor.Ingest.Transcoder.start_link()
  end
end
