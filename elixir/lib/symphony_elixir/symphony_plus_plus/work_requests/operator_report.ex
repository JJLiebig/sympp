defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.OperatorReport do
  @moduledoc """
  The architect's operator report, stored on `sympp_work_requests.report`.

  `set_report` patches `brief`, `eta` and `parking`; `null` clears a field.
  Parking keeps its interval and records either observable targets or a chief hold.
  """

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{ProgressEvent, Redactor}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerObservations, BlockerTarget, WorkRequest}

  @type repo :: module()
  @type set_error :: {:error, term()} | {:tool_error, String.t()}
  @fields ["brief", "eta", "parking"]

  @doc "Applies a report patch and returns the WorkRequest and the field operations."
  @spec set(repo(), String.t(), map(), String.t()) :: {:ok, WorkRequest.t(), map()} | set_error()
  def set(repo, work_request_id, arguments, role) when is_map(arguments) do
    with :ok <- authorize_hold(arguments["parking"], role),
         {:ok, patch} <- normalize_patch(arguments),
         snapshots = BlockerTarget.initial_snapshot(patch["parking"]["targets"] || []),
         {:ok, work_request} <-
           repo.transaction(fn -> store_patch(repo, work_request_id, patch, snapshots) end, mode: :immediate)
           |> DashboardPubSub.broadcast_changed_on_success() do
      applied =
        Map.new(patch, fn
          {field, nil} -> {field, "cleared"}
          {field, _value} -> {field, "set"}
        end)

      {:ok, work_request, applied}
    else
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      error -> error
    end
  end

  defp authorize_hold(%{"hold" => _}, role) when role != "chief", do: {:tool_error, "hold_requires_chief"}
  defp authorize_hold(_parking, _role), do: :ok

  defp store_patch(repo, work_request_id, patch, snapshots) do
    case repo.get(WorkRequest, work_request_id) do
      nil ->
        repo.rollback(:not_found)

      %WorkRequest{archived_at: %DateTime{}} ->
        repo.rollback(:work_request_archived)

      %WorkRequest{} = work_request ->
        patch = observe_targets(repo, work_request_id, patch, snapshots)
        now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        repo.update!(Ecto.Changeset.change(work_request, report: apply_patch(work_request.report || %{}, patch, now)))
    end
  end

  defp observe_targets(repo, request_id, %{"parking" => %{"targets" => targets}} = patch, snapshots) do
    if Enum.any?(targets, &outside_request?(repo, request_id, &1)), do: repo.rollback({:tool_error, "blocker_package_outside_request"})

    case BlockerObservations.require_acyclic(repo, request_id, targets) do
      :ok -> put_in(patch, ["parking", "targets"], BlockerObservations.evaluate(repo, targets, snapshots))
      {:error, reason} -> repo.rollback({:tool_error, Atom.to_string(reason)})
    end
  end

  defp observe_targets(_repo, _request_id, patch, _snapshots), do: patch

  defp outside_request?(repo, request_id, %{"kind" => "work_package", "id" => id}),
    do: not match?(%WorkPackage{work_request_id: ^request_id}, repo.get(WorkPackage, id))

  defp outside_request?(_repo, _request_id, _target), do: false

  @doc "Public reports by WorkRequest id."
  @spec load_many(repo(), [WorkRequest.t()]) :: {:ok, %{String.t() => map() | nil}}
  def load_many(_repo, work_requests), do: {:ok, Map.new(work_requests, &{&1.id, public(&1.report)})}

  @spec public(map() | nil) :: map() | nil
  def public(nil), do: nil

  def public(report) when is_map(report) do
    report
    |> Map.take(@fields)
    |> case do
      empty when map_size(empty) == 0 -> nil
      public -> Redactor.redact_output(public)
    end
  end

  @spec blockers(map() | nil) :: [map()]
  def blockers(%{"parking" => %{"resumed_at" => nil, "targets" => targets}}) do
    Enum.map(targets, fn %{"state" => state} = entry ->
      target = Map.delete(entry, "state")
      BlockerTarget.present(target, state, nil) |> Map.put(:id, BlockerTarget.id(target))
    end)
  end

  def blockers(%{"parking" => %{"resumed_at" => nil, "hold" => hold}}), do: [hold(hold, "operator", "wait")]
  def blockers(%{"parking" => %{"resumed_at" => nil, "reason" => reason}}), do: [hold(reason, "legacy", "reclassify")]
  def blockers(_report), do: []

  defp hold(summary, kind, action), do: %{id: "hold", summary: Redactor.redact_text(summary), state: "waiting", hold: kind, next_action: action}

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

  defp apply_field(report, "parking", parking, now) do
    parked_at =
      case report["parking"] do
        %{"resumed_at" => nil, "parked_at" => parked_at} -> parked_at
        _closed_or_missing -> now
      end

    Map.put(report, "parking", Map.merge(parking, %{"parked_at" => parked_at, "resumed_at" => nil}))
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

  defp normalize_field("parking", %{"hold" => hold} = parking) when not is_map_key(parking, "targets") do
    with {:ok, hold} <- normalize_text(hold), do: {:ok, %{"hold" => hold}}
  end

  defp normalize_field("parking", %{"targets" => [_ | _] = targets} = parking) when not is_map_key(parking, "hold") do
    with normalized <- Enum.map(targets, &BlockerTarget.normalize/1),
         true <- Enum.all?(normalized, &match?({:ok, _}, &1)) do
      {:ok, %{"targets" => normalized |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}}
    else
      false -> :error
    end
  end

  defp normalize_field(_field, _value), do: :error

  defp normalize_text(text) when is_binary(text) do
    text = text |> String.trim() |> Redactor.redact_text()

    if text != "" and String.length(text) <= ProgressEvent.payload_string_limit(), do: {:ok, text}, else: :error
  end

  defp normalize_text(_text), do: :error
end
