defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolError do
  @moduledoc """
  The one shape of a tool error. The JSON-RPC error keeps its numeric code
  and class message; its `data` always carries:

  - `code`: the machine reason, such as `owned_by_other_terminal`;
  - `message`: one sentence for the caller;
  - `state`: the actual lifecycle state of what the call names (a
    WorkPackage's status, a WorkRequest's phase or an ask's state), or `null`
    when it names nothing that exists;
  - `next_action`: what to do next. Lifecycle refusals take it from the
    WorkPackage lifecycle or WorkRequest phase tables.

  Fields a caller needs to fix the call (an owner, an op index, missing
  fields) follow. Handlers report a `reason` and optional `state` and
  `next_action`; this module is the only place that builds the shape.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @replaced ["reason", "tool", "resource"]
  # Callers refused before they may read the ledger learn nothing about it;
  # neither do calls refused before authorization, which set `state` to nil.
  @no_lookup_codes [-32_000, -32_001, -32_601]

  @type error :: {:error, integer(), String.t(), map()}

  @doc "Puts a tool call's error into the contract shape; results pass through."
  @spec contract({:ok, map()} | error(), String.t(), map(), module()) :: {:ok, map()} | error()
  def contract({:error, code, message, data}, tool, arguments, repo) when is_map(data) do
    reason = data["code"] || data["reason"] || class_code(code)
    state = data["state"]
    next_action = data["next_action"]
    arguments = if is_map(arguments), do: arguments, else: %{}
    target = if needs_target?(code, data), do: target(repo, tool, arguments)

    data =
      data
      |> Map.drop(@replaced)
      |> Map.merge(%{
        "code" => reason,
        "message" => data["message"] || message(reason, code, data),
        "state" => state || target_state(target),
        "next_action" => next_action || default_next_action(code, target)
      })

    {:error, code, message, data}
  end

  def contract(result, _tool, _arguments, _repo), do: result

  # A handler that sets `state` (even to nil) has said all there is to say.
  defp needs_target?(code, _data) when code in @no_lookup_codes, do: false
  defp needs_target?(_code, data), do: not Map.has_key?(data, "state") or is_nil(data["next_action"])

  defp target(repo, _tool, %{"work_package_id" => id}) when is_binary(id) and id != "", do: lookup(fn -> repo.get(WorkPackage, id) end)
  defp target(repo, _tool, %{"ask_id" => id}) when is_binary(id) and id != "", do: lookup(fn -> repo.get(Ask, id) end)
  defp target(repo, _tool, %{"work_request_id" => id}) when is_binary(id) and id != "", do: lookup(fn -> work_request_target(repo, id) end)
  defp target(_repo, _tool, _arguments), do: nil

  defp work_request_target(repo, id) do
    with %WorkRequest{} = work_request <- repo.get(WorkRequest, id),
         {:ok, %{phase: phase}} <- Phase.load_one(repo, work_request) do
      {:phase, phase}
    else
      _missing_or_unreadable -> nil
    end
  end

  # The state is a courtesy on an error path: an unreadable ledger leaves it out.
  defp lookup(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp target_state(%WorkPackage{status: status}), do: status
  defp target_state(%Ask{state: state}), do: state
  defp target_state({:phase, phase}), do: phase
  defp target_state(_target), do: nil

  defp default_next_action(-32_009, %WorkPackage{} = package), do: Lifecycle.next_action(package).action || "none"
  defp default_next_action(-32_009, {:phase, phase}), do: Phase.next_action(phase) || "read_work_request"
  defp default_next_action(-32_009, _target), do: "read_work_request"
  defp default_next_action(-32_602, _target), do: "fix_arguments"
  defp default_next_action(-32_004, _target), do: "check_id"
  defp default_next_action(-32_601, _target), do: "list_tools"
  defp default_next_action(-32_001, _target), do: "run_in_herdr_terminal"
  defp default_next_action(-32_003, _target), do: "read_work_request"
  defp default_next_action(_code, _target), do: "retry"

  defp message("owned_by_other_terminal", _code, _data), do: "Another terminal works on this WorkRequest."
  defp message("work_request_archived", _code, _data), do: "The WorkRequest is archived."
  defp message("delivery_outcome_conflict", _code, %{"outcome" => outcome}), do: "The package already ended as #{outcome}."
  defp message("ending_not_allowed", _code, %{"outcome" => outcome}), do: "This package can't close as #{outcome} in its current state."
  defp message("not_found", _code, _data), do: "Nothing with that id exists."
  defp message("blank_ci_override", _code, _data), do: "ci_override needs a reason: why CI can be skipped for this head."
  defp message("ci_failing", _code, _data), do: "CI is failing on this head; ci_override never skips failing checks."
  defp message("unexpected_argument", _code, %{"arguments" => [_ | _] = names}), do: "Unknown arguments: #{Enum.join(names, ", ")}."
  defp message("invalid_field", _code, %{"field" => field}), do: "#{field} has an invalid value."
  defp message("missing_" <> field, -32_602, _data), do: "#{field} is required."
  defp message("invalid_" <> field, -32_602, _data), do: "#{field} has an invalid value."
  defp message(_reason, code, _data), do: class_message(code)

  defp class_message(-32_602), do: "The arguments are invalid."
  defp class_message(-32_601), do: "No such tool."
  defp class_message(-32_004), do: "Not found."
  defp class_message(-32_001), do: "This caller may not make this call."
  defp class_message(-32_003), do: "Refused."
  defp class_message(-32_009), do: "Not allowed in the current state."
  defp class_message(_code), do: "The ledger is unavailable; retry."

  defp class_code(-32_602), do: "invalid_params"
  defp class_code(-32_601), do: "method_not_found"
  defp class_code(-32_004), do: "not_found"
  defp class_code(-32_001), do: "unauthorized"
  defp class_code(-32_003), do: "forbidden"
  defp class_code(-32_009), do: "precondition_failed"
  defp class_code(_code), do: "server_error"
end
