defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.OperatorReport do
  @moduledoc """
  The architect's operator report, stored on `sympp_work_requests.report`.

  `set_report` patches `brief`, `eta` and `parking`; `null` clears a field.
  Parking keeps its interval: clearing it records `resumed_at`. A
  `pending_ask` carried over from the old human escalation is shown as
  `human_escalation` until asks replace it.
  """

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{ProgressEvent, Redactor}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @fields ["brief", "eta", "parking"]

  @doc "Applies a report patch to a WorkRequest and returns the stored report."
  @spec set(repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, term()} | {:tool_error, String.t()}
  def set(repo, work_request_id, arguments) when is_map(arguments) do
    with {:ok, patch} <- normalize_patch(arguments) do
      repo.transaction(fn -> store_patch(repo, work_request_id, patch) end, mode: :immediate)
      |> DashboardPubSub.broadcast_changed_on_success()
    end
  end

  defp store_patch(repo, work_request_id, patch) do
    case repo.get(WorkRequest, work_request_id) do
      nil ->
        repo.rollback(:not_found)

      %WorkRequest{} = work_request ->
        now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        repo.update!(Ecto.Changeset.change(work_request, report: apply_patch(work_request.report || %{}, patch, now)))
    end
  end

  @doc "Public reports by WorkRequest id."
  @spec load_many(repo(), [WorkRequest.t()]) :: {:ok, %{String.t() => map() | nil}}
  def load_many(_repo, work_requests), do: {:ok, Map.new(work_requests, &{&1.id, public(&1.report)})}

  @spec public(map() | nil) :: map() | nil
  def public(nil), do: nil

  def public(report) when is_map(report) do
    report
    |> Map.take(@fields)
    |> maybe_put_escalation(report["pending_ask"])
    |> case do
      empty when map_size(empty) == 0 -> nil
      public -> Redactor.redact_output(public)
    end
  end

  defp maybe_put_escalation(report, %{"question" => question, "raised_at" => raised_at}),
    do: Map.put(report, "human_escalation", %{"question" => question, "raised_at" => raised_at, "resolved_at" => nil})

  defp maybe_put_escalation(report, _pending_ask), do: report

  defp apply_patch(report, patch, now) do
    patch
    |> Enum.reduce(report, fn {field, value}, acc -> apply_field(acc, field, value, now) end)
    |> Map.put("updated_at", now)
  end

  defp apply_field(report, field, nil, _now) when field in ["brief", "eta"], do: Map.delete(report, field)
  defp apply_field(report, field, text, now) when field in ["brief", "eta"], do: Map.put(report, field, %{"text" => text, "written_at" => now})

  defp apply_field(report, "parking", nil, now) do
    case report["parking"] do
      %{"resumed_at" => nil} = parking -> Map.put(report, "parking", %{parking | "resumed_at" => now})
      _closed_or_missing -> report
    end
  end

  defp apply_field(report, "parking", %{"reason" => reason}, now) do
    parked_at =
      case report["parking"] do
        %{"resumed_at" => nil, "parked_at" => parked_at} -> parked_at
        _closed_or_missing -> now
      end

    Map.put(report, "parking", %{"reason" => reason, "parked_at" => parked_at, "resumed_at" => nil})
  end

  defp normalize_patch(arguments) do
    patch = Map.take(arguments, @fields)

    if map_size(patch) == 0,
      do: {:tool_error, "empty_operator_report"},
      else: Enum.reduce_while(patch, {:ok, %{}}, &normalize_entry/2)
  end

  defp normalize_entry({field, value}, {:ok, acc}) do
    case normalize_field(field, value) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
      :error -> {:halt, {:tool_error, "invalid_operator_report_#{field}"}}
    end
  end

  defp normalize_field(_field, nil), do: {:ok, nil}
  defp normalize_field(field, text) when field in ["brief", "eta"], do: normalize_text(text)

  defp normalize_field("parking", %{"reason" => reason}) do
    with {:ok, reason} <- normalize_text(reason), do: {:ok, %{"reason" => reason}}
  end

  defp normalize_field(_field, _value), do: :error

  defp normalize_text(text) when is_binary(text) do
    text = text |> String.trim() |> Redactor.redact_text()

    if text != "" and String.length(text) <= ProgressEvent.payload_string_limit(), do: {:ok, text}, else: :error
  end

  defp normalize_text(_text), do: :error
end
