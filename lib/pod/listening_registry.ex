defmodule Pod.ListeningRegistry do
  use GenServer

  @table :listening_active_recordings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc "Mark a recording as having at least one active listener."
  def touch(recording_id), do: :ets.insert(@table, {recording_id, true})

  @doc "Returns all recording IDs that have ever had a listener (may include empty topics)."
  def list_all do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(fn {id, _} -> id end)
    end
  end
end
