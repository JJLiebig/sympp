defmodule SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal do
  @moduledoc """
  The calling Herdr terminal, as asserted by the sympp bridge in `_meta.herdr`.

  The bridge verifies the identity against its local herdr-core before sending
  it. The key is the core id plus the terminal address, without the process id,
  so restarting, compacting or clearing an agent in the same terminal keeps the
  same key. Callers without this identity are read-only.
  """

  @enforce_keys [:key, :core_id, :address, :display_address, :role]
  defstruct [:key, :core_id, :address, :display_address, :role, :domain]

  @type t :: %__MODULE__{
          key: String.t(),
          core_id: String.t(),
          address: String.t(),
          display_address: String.t(),
          role: String.t(),
          domain: String.t() | nil
        }

  @max_length 256

  @doc "Reads the bridge-asserted terminal from a request's params, if present and well formed."
  @spec from_params(term()) :: t() | nil
  def from_params(%{"_meta" => %{"herdr" => herdr}}), do: from_meta(herdr)
  def from_params(_params), do: nil

  @spec from_meta(term()) :: t() | nil
  def from_meta(%{"core_id" => core_id, "terminal_id" => address} = herdr) do
    with {:ok, core_id} <- text(core_id),
         {:ok, address} <- text(address) do
      labels = labels(herdr["labels"])
      role = if labels["sympp.role"] == "chief", do: "chief", else: "architect"

      %__MODULE__{
        key: key(core_id, address),
        core_id: core_id,
        address: address,
        display_address: display_address(herdr["core_name"], address),
        role: role,
        domain: if(role == "chief", do: optional_text(labels["sympp.domain"]))
      }
    else
      _invalid -> nil
    end
  end

  def from_meta(_herdr), do: nil

  @spec key(String.t(), String.t()) :: String.t()
  def key(core_id, address), do: core_id <> "/" <> address

  @doc "Splits a terminal key back into its core id and address."
  @spec split_key(String.t()) :: {String.t(), String.t()} | :error
  def split_key(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [core_id, address] when core_id != "" and address != "" -> {core_id, address}
      _parts -> :error
    end
  end

  @doc "Chief attribution recorded as `dispatched_by` on WorkRequests and packages."
  @spec attribution(t() | nil) :: map() | nil
  def attribution(%__MODULE__{role: "chief", domain: domain}) when is_binary(domain), do: %{"kind" => "chief", "domain" => domain}
  def attribution(_terminal), do: nil

  defp display_address(core_name, address) do
    case optional_text(core_name) do
      nil -> address
      name -> name <> "/" <> address
    end
  end

  defp labels(labels) when is_map(labels), do: labels
  defp labels(_labels), do: %{}

  defp optional_text(value) do
    case text(value) do
      {:ok, text} -> text
      :error -> nil
    end
  end

  defp text(value) when is_binary(value) do
    trimmed = String.trim(value)

    valid? = trimmed != "" and byte_size(trimmed) <= @max_length and String.printable?(trimmed)
    if valid? and not String.contains?(trimmed, ["\n", "\r"]), do: {:ok, trimmed}, else: :error
  end

  defp text(_value), do: :error
end
