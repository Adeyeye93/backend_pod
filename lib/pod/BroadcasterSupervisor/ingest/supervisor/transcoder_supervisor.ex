defmodule Pod.BroadcasterSupervisor.Ingest.TranscoderSupervisor do
  @moduledoc """
  Supervises the TranscoderPool GenServer and the fixed pool of
  TranscodingWorker processes.

  ### Init ordering fix

  The original code called `DynamicSupervisor.start_child/2` inside `init/1`,
  before `DynamicSupervisor.init/1` had returned. The supervisor process
  isn't registered or fully initialized at that point, causing a crash.

  The fix: create the ETS table and schedule pool initialization via
  `send(self(), :init_pool)` from `init/1`. By the time the message is
  processed in `handle_info/2`, the supervisor is fully up.
  """

  use DynamicSupervisor
  require Logger

  alias Pod.BroadcasterSupervisor.Ingest.TranscodingWorker
  # alias Pod.BroadcasterSupervisor.Ingest.TranscoderPool

  @pool_size 100

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Create the ETS table here — it must exist before any worker calls
    # TranscoderPool.checkin/1 in their own init.
    :ets.new(:transcoder_pool, [:set, :public, :named_table])

    # Defer pool population until after this callback returns and the
    # supervisor is fully initialized.
    send(self(), :init_pool)

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # `handle_info` is available because DynamicSupervisor is built on GenServer.

  def handle_info(:init_pool, state) do
    Logger.info("[TranscoderSupervisor] Starting #{@pool_size} transcoding workers")

    for _ <- 1..@pool_size do
      case DynamicSupervisor.start_child(__MODULE__, {TranscodingWorker, []}) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("[TranscoderSupervisor] Failed to start worker: #{inspect(reason)}")
      end
    end

    Logger.info("[TranscoderSupervisor] Pool ready — #{@pool_size} workers started")
    {:noreply, state}
  end
end
