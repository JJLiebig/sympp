defmodule SymphonyElixir.SymphonyPlusPlus.OperatorAudit.Target do
  @moduledoc "What a local operator action acted on, as recorded in the operator audit."

  @enforce_keys [:type]
  defstruct [:type, :id, :work_request_id, :work_package_id]

  @type t :: %__MODULE__{
          type: atom(),
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          work_package_id: String.t() | nil
        }

  @spec new(atom()) :: t()
  def new(type) when is_atom(type), do: %__MODULE__{type: type}

  @spec ledger() :: t()
  def ledger, do: new(:ledger)

  @spec work_request(String.t()) :: t()
  def work_request(id) when is_binary(id), do: %__MODULE__{type: :work_request, id: id, work_request_id: id}

  @spec work_package(String.t(), String.t() | nil) :: t()
  def work_package(id, work_request_id \\ nil) when is_binary(id),
    do: %__MODULE__{type: :work_package, id: id, work_package_id: id, work_request_id: work_request_id}
end
