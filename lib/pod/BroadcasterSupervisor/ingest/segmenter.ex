defmodule Pod.BroadcasterSupervisor.Ingest.Segmenter do
  def write_segment(stream_id, data) do
    path = "segments/#{stream_id}/#{System.system_time(:millisecond)}.aac"
    File.write!(path, data)
  end
end
