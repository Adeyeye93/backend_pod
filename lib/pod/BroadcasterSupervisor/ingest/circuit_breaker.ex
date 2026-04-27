defmodule Pod.BroadcasterSupervisor.Ingest.CircuitBreaker do
  defstruct failures: 0, state: :closed

  def new, do: %__MODULE__{}

  # Already open — stay open
  def trip(%{state: :open} = cb), do: cb

  # Threshold reached — open the circuit
  def trip(%{failures: f} = cb) when f > 5, do: %{cb | state: :open}

  # Below threshold — stay closed
  def trip(cb), do: cb

  def record_failure(cb), do: trip(%{cb | failures: cb.failures + 1})

  def open?(%{state: :open}), do: true
  def open?(_), do: false
end
