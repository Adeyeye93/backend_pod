defmodule Pod.BroadcasterSupervisor.Ingest.TranscoderPool do
  @moduledoc """
  Thread-safe worker pool backed by a GenServer.

  All checkout/checkin operations are serialized through this process so there
  is never a race between finding an idle worker and marking it busy — the
  root cause of the original ETS-only implementation's concurrency bug.

  The ETS table is kept for O(1) reads during monitoring/introspection, but
  all mutations go through this GenServer.
  """

  use GenServer
  require Logger

  @table :transcoder_pool

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check out an idle worker. Returns `{:ok, pid}` or `:busy`."
  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  @doc "Register a newly started worker into the pool as idle."
  def register(pid) do
    GenServer.cast(__MODULE__, {:register, pid})
  end

  @doc "Return a worker to the idle pool after completing a job."
  def checkin(pid) do
    GenServer.cast(__MODULE__, {:checkin, pid})
  end

  @doc "Current pool snapshot — useful for health checks / metrics."
  def stats do
    all = :ets.tab2list(@table)
    idle = Enum.count(all, fn {_, status} -> status == :idle end)
    busy = Enum.count(all, fn {_, status} -> status == :busy end)
    %{idle: idle, busy: busy, total: length(all)}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # TranscoderPool owns the ETS table — create it here so it exists
    # before any worker calls register/1 in their own init.
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    case :ets.match(@table, {:"$1", :idle}) do
      [[pid] | _] ->
        :ets.insert(@table, {pid, :busy})
        {:reply, {:ok, pid}, state}

      [] ->
        {:reply, :busy, state}
    end
  end

  @impl true
  def handle_cast({:register, pid}, state) do
    # Fresh worker joining the pool for the first time (or after a restart).
    # Insert unconditionally — no prior entry needed.
    :ets.insert(@table, {pid, :idle})
    Logger.debug("[TranscoderPool] Worker registered: #{inspect(pid)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:checkin, pid}, state) do
    if :ets.member(@table, pid) do
      :ets.insert(@table, {pid, :idle})
    else
      Logger.warning("[TranscoderPool] checkin from unknown pid #{inspect(pid)}")
    end

    {:noreply, state}
  end
end
