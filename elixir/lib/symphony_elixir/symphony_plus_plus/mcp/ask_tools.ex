defmodule SymphonyElixir.SymphonyPlusPlus.MCP.AskTools do
  @moduledoc """
  `ask` opens a "Needs you" ask for the operator; `resolve_ask` records a
  conversational answer or withdraws one. Neither needs ownership: any Herdr
  terminal may ask, and the asker or the WorkRequest owner may resolve.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ErrorDetails, ToolResult, WorkRequestPayloads}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @tools ["ask", "resolve_ask"]

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t(), map()) :: {:ok, map()} | {:error, integer(), String.t(), map()}
  def call("ask", %Config{} = config, %Terminal{} = terminal, arguments) do
    case Asks.open(config.repo, terminal, arguments) do
      {:ok, ask} ->
        {:ok,
         ToolResult.tool_result(%{
           "ask" => Asks.public(ask),
           "next_action" => "The operator answers on the board and the answer is typed into this terminal. Withdraw it with resolve_ask if it stops mattering."
         })}

      {:error, reason} ->
        error("ask", reason)
    end
  end

  def call("resolve_ask", %Config{} = config, %Terminal{} = terminal, arguments) do
    case Asks.resolve(config.repo, terminal, arguments["ask_id"], arguments["to"], arguments["answer"], arguments["decision"]) do
      {:ok, ask, decision} ->
        {:ok,
         ToolResult.tool_result(
           %{"ask" => Asks.public(ask)}
           |> then(&if(decision, do: Map.put(&1, "decision_log_entry", WorkRequestPayloads.decision_log_entry(decision)), else: &1))
         )}

      {:error, reason} ->
        error("resolve_ask", reason)
    end
  end

  defp error(tool, :not_found), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  defp error(tool, :work_request_archived), do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp error(tool, :work_package_ended),
    do: precondition(tool, "work_package_ended", "ended", "The package has ended; ask on the WorkRequest without work_package_id.")

  defp error(tool, {:ask_not_open, state}), do: precondition(tool, "ask_not_open", state, "Nothing to do: the ask is already #{state}.")

  defp error(tool, {:not_asker_or_owner, ask}) do
    asker = if ask.asked_by_address, do: "#{ask.asked_by_address} or ", else: ""

    {:error, -32_003, "Forbidden",
     %{
       "tool" => tool,
       "reason" => "not_asker_or_owner",
       "state" => "open",
       "next_action" => "Only #{asker}the WorkRequest owner can resolve this ask; the operator answers it on the board."
     }}
  end

  defp error(tool, {:invalid_decision_prompt, message}),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "invalid_decision_prompt", "message" => message}}

  defp error(tool, %Ecto.Changeset{} = changeset), do: ErrorDetails.changeset_invalid_params_error(tool, "invalid_decision", changeset)

  defp error(tool, reason) when reason in [:database_busy] or (is_tuple(reason) and elem(reason, 0) in [:storage_failed, :migration_failed]),
    do: {:error, -32_000, "Server error", %{"resource" => tool, "reason" => "ledger_unavailable"}}

  defp error(tool, reason), do: ErrorDetails.invalid_params_error(tool, reason)

  defp precondition(tool, reason, state, next_action),
    do: {:error, -32_009, "Precondition Failed", %{"tool" => tool, "reason" => reason, "state" => state, "next_action" => next_action}}
end
