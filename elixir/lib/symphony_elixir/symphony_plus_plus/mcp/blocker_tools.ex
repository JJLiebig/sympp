defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerTools do
  @moduledoc """
  `set_blocker` declares or clears a blocker on a package of a WorkRequest the
  caller owns. The server takes or confirms ownership before this runs.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ErrorDetails, ToolResult}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Blockers

  @spec call(String.t(), Config.t(), Terminal.t(), map()) :: {:ok, map()} | {:error, integer(), String.t(), map()}
  def call("set_blocker", %Config{} = config, %Terminal{} = terminal, arguments) do
    case arguments["active"] do
      active when is_boolean(active) ->
        config.repo
        |> Blockers.set(Actor.from_terminal(terminal), arguments["work_package_id"], arguments["blocker_id"], active, arguments["summary"])
        |> result()

      _other ->
        ErrorDetails.invalid_params_error("set_blocker", :invalid_active)
    end
  end

  defp result({:ok, blocker, how}) do
    {:ok,
     ToolResult.tool_result(%{
       "blocker" => blocker |> Map.take([:id, :active, :summary, :updated_at]) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
       "changed" => how == :changed
     })}
  end

  defp result({:error, :not_found}), do: {:error, -32_004, "Not found", %{"tool" => "set_blocker", "reason" => "not_found"}}
  defp result({:error, :work_request_archived}), do: ErrorDetails.lifecycle_error("set_blocker", :work_request_archived, %{"phase" => "archived"})

  defp result({:error, :work_package_ended}),
    do: precondition("work_package_ended", "ended", "The package has ended; its blockers were cleared.")

  defp result({:error, :blocker_not_found}),
    do: precondition("blocker_not_found", "none", "No blocker with this id exists on the package; declare it with active: true.")

  defp result({:error, reason}) when reason == :database_busy or (is_tuple(reason) and elem(reason, 0) in [:storage_failed, :migration_failed]),
    do: {:error, -32_000, "Server error", %{"resource" => "set_blocker", "reason" => "ledger_unavailable"}}

  defp result({:error, reason}), do: ErrorDetails.invalid_params_error("set_blocker", reason)

  defp precondition(reason, state, next_action),
    do: {:error, -32_009, "Precondition Failed", %{"tool" => "set_blocker", "reason" => reason, "state" => state, "next_action" => next_action}}
end
