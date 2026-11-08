defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Writer do
  @moduledoc """
  The terminal writing to one WorkPackage in an owner-gated tool call.
  Ownership of the package's WorkRequest is checked before a handler builds it.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor

  @enforce_keys [:actor, :work_package_id]
  defstruct [:actor, :work_package_id]

  @type t :: %__MODULE__{actor: Actor.t(), work_package_id: String.t()}

  @spec new(Terminal.t(), String.t()) :: t()
  def new(%Terminal{} = terminal, work_package_id) when is_binary(work_package_id),
    do: %__MODULE__{actor: Actor.from_terminal(terminal), work_package_id: work_package_id}
end
