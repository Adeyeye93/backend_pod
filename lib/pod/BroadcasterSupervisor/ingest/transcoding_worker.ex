defmodule Pod.BroadcasterSupervisor.Ingest.TranscodingWorker do
  @moduledoc """
  Thin shim that lets the DynamicSupervisor start a Transcoder under a
  child spec with a stable module name.

  Keeping this as a separate module means the supervisor's child spec and
  the Transcoder's own implementation stay decoupled — useful if you later
  want to swap in a different worker implementation without touching the
  supervisor.
  """

  def start_link(opts) do
    Pod.BroadcasterSupervisor.Ingest.Transcoder.start_link(opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end
end
