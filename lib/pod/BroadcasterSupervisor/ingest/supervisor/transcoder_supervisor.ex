defmodule Pod.BroadcasterSupervisor.Ingest.Supervisor.TranscoderSupervisor do
  alias Pod.BroadcasterSupervisor.Ingest.TranscodingWorker
  use DynamicSupervisor

  @pool_size 32

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(:transcoder_pool, [:set, :public, :named_table])

    for _ <- 1..@pool_size do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          __MODULE__,
          {TranscodingWorker, []}
        )

      :ets.insert(:transcoder_pool, {pid, :idle})
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
