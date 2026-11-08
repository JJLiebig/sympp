defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Actor do
  @moduledoc """
  Who wrote a progress event: a Herdr terminal (by display address and role),
  with idempotency keys scoped to that terminal.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @enforce_keys [:id, :type, :idempotency_scope]
  defstruct [:id, :type, :idempotency_scope]

  @type t :: %__MODULE__{id: String.t(), type: String.t(), idempotency_scope: String.t()}

  @spec from_terminal(Terminal.t()) :: t()
  def from_terminal(%Terminal{} = terminal),
    do: %__MODULE__{id: terminal.display_address, type: terminal.role, idempotency_scope: "terminal:" <> terminal.key}
end
