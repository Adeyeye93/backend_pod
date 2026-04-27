defmodule Pod.BroadcasterSupervisor.Ingest.TranscoderSupervisor do
  @moduledoc """
  Supervises the fixed pool of TranscodingWorker processes.

  ## Why a separate PoolInitializer child

  DynamicSupervisor does not support handle_info — it is not a full
  GenServer and messages sent to it fall through to an unhandled default,
  producing the "unexpected message" warning.

  The correct pattern is to add a lightweight child GenServer —
  PoolInitializer — whose only job is to start all the workers after
  the supervisor is fully up. It starts, spawns the workers, then
  stops itself cleanly. This is the standard OTP way to run post-init
  work under a supervisor.
  """

  use DynamicSupervisor
  require Logger

  alias Pod.BroadcasterSupervisor.Ingest.TranscodingWorker
  alias Pod.BroadcasterSupervisor.Ingest.TranscoderSupervisor.PoolInitializer

  @pool_size 100

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # TranscoderPool owns the ETS table and creates it in its own init.
    # Since TranscoderPool starts before this supervisor in application.ex,
    # the table is guaranteed to exist before any worker calls checkin/1.
    spec = DynamicSupervisor.init(strategy: :one_for_one)

    Task.start(fn ->
      Process.sleep(100)
      PoolInitializer.populate(@pool_size)
    end)

    spec
  end
end


defmodule Pod.BroadcasterSupervisor.Ingest.TranscoderSupervisor.PoolInitializer do
  @moduledoc """
  Populates the TranscoderSupervisor pool after it is fully started.
  Called from a Task spawned in TranscoderSupervisor.init/1.
  """

  require Logger

  alias Pod.BroadcasterSupervisor.Ingest.TranscoderSupervisor
  alias Pod.BroadcasterSupervisor.Ingest.TranscodingWorker

  def populate(pool_size) do
    Logger.info("[TranscoderSupervisor] Starting #{pool_size} transcoding workers")

    results =
      Enum.map(1..pool_size, fn _ ->
        DynamicSupervisor.start_child(TranscoderSupervisor, {TranscodingWorker, []})
      end)

    succeeded = Enum.count(results, &match?({:ok, _}, &1))
    failed    = pool_size - succeeded

    if failed > 0 do
      Logger.error("[TranscoderSupervisor] Pool started with #{failed} failures — #{succeeded}/#{pool_size} workers running")
    else
      Logger.info("[TranscoderSupervisor] ✓ Pool ready — #{succeeded} workers started")
    end
  end
end
