defmodule Pod.BroadcasterSupervisor.Ingest.CircuitBreaker do
  defstruct failures: 0, state: :closed

  def new, do: %__MODULE__{}

  def trip(%{failures: f} = cb) when f > 5,
    do: %{cb | state: :open}

  def record_failure(cb),
    do: trip(%{cb | failures: cb.failures + 1})
end
