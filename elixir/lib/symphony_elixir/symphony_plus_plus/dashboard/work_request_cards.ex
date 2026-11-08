defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestCards do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Chiefs

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    DeliveryWorkPackageProjection,
    OperationalProjection,
    Sanitizer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @work_request_slice_state_priority [
    "blocked",
    "active",
    "needs_attention",
    "started_paused",
    "merge_ready",
    "ready_to_finish",
    "merging",
    "needs_closeout",
    "prepared",
    "dispatched",
    "dependency_blocked",
    "planned",
    "merged",
    "delivered",
    "completed_no_pr",
    "finished",
    "ended",
    "legacy",
    "superseded",
    "abandoned",
    "skipped"
  ]
  @work_request_count_chunk_size 500

  @type repo :: module()
  @type dashboard_error :: Dashboard.dashboard_error()

  @spec cards(repo(), [WorkRequest.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def cards(repo, work_requests, opts) do
    with {:ok, summaries} <- card_summaries(repo, work_requests, opts) do
      repo_identity_catalog = Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
      {:ok, Enum.map(work_requests, &card(&1, summaries, repo_identity_catalog))}
    end
  end

  @spec priority_cards(repo(), [WorkRequest.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def priority_cards(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- question_context(repo, work_request_ids),
         {:ok, work_packages} <- work_packages(repo, work_request_ids, opts),
         {:ok, phases} <- Phase.load(repo, work_requests, work_packages) do
      work_packages_by_request = Enum.group_by(work_packages, & &1.work_request_id)
      work_package_counts = work_packages |> Enum.map(&{&1.work_request_id, &1.status}) |> status_counts()

      summaries =
        Map.new(work_requests, fn work_request ->
          request_work_packages = Map.get(work_packages_by_request, work_request.id, [])

          {work_request.id,
           Map.merge(phase_fields(work_request, Map.fetch!(phases, work_request.id)), %{
             open_question_count: status_count(question_context.counts, work_request.id, "open"),
             answered_question_count: status_count(question_context.counts, work_request.id, "answered"),
             work_package_count: length(request_work_packages),
             planned_work_package_count: Enum.count(request_work_packages, &(&1.status == "planned")),
             dispatched_work_package_count: Enum.count(request_work_packages, &(not is_nil(&1.dispatched_at))),
             ended_work_package_count: status_count(work_package_counts, work_request.id, "ended")
           })}
        end)

      repo_identity_catalog = Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
      {:ok, Enum.map(work_requests, &card(&1, summaries, repo_identity_catalog))}
    end
  end

  @spec visible_cards([map()]) :: [map()]
  def visible_cards(cards), do: Enum.reject(cards, &(not is_nil(&1.archived_at)))

  @spec ordered_work_requests([WorkRequest.t()]) :: [WorkRequest.t()]
  def ordered_work_requests(work_requests) do
    Enum.sort_by(work_requests, fn %WorkRequest{} = work_request ->
      {sortable_timestamp(work_request.inserted_at), work_request.id || ""}
    end)
  end

  @spec visible_work_packages([WorkPackage.t()], map() | nil) :: [WorkPackage.t()]
  def visible_work_packages(work_packages, nil), do: work_packages

  def visible_work_packages(work_packages, delivery_board) do
    visible_by_id = DeliveryWorkPackageProjection.work_packages_by_id(delivery_board)

    Enum.filter(work_packages, &Map.has_key?(visible_by_id, &1.id))
  end

  @spec work_request_payload(
          WorkRequest.t(),
          [ClarificationQuestion.t()],
          [WorkPackage.t()],
          map(),
          map(),
          keyword()
        ) :: map()
  def work_request_payload(
        %WorkRequest{} = work_request,
        _questions,
        work_packages,
        work_package_contexts,
        repo_identity_catalog,
        opts
      ) do
    phase = Keyword.fetch!(opts, :phase)

    work_request
    |> base_payload(repo_identity_catalog)
    |> Map.merge(phase_fields(work_request, phase))
    |> Map.put(:operator_report, Keyword.get(opts, :operator_report))
    |> Map.put(
      :operational_state,
      operational_state(
        work_request,
        work_packages,
        work_package_contexts,
        phase.phase,
        Keyword.get(opts, :delivery_board),
        Keyword.get(opts, :delivery_state_opts, [])
      )
    )
  end

  defp phase_fields(%WorkRequest{} = work_request, %{phase: phase, completed_at: completed_at}) do
    %{
      phase: phase,
      completed_at: timestamp(completed_at),
      operator_completed_at: timestamp(work_request.operator_completed_at),
      archived_at: timestamp(work_request.archived_at),
      archive_reason: work_request.archive_reason
    }
  end

  defp card_summaries(_repo, [], _opts), do: {:ok, %{}}

  defp card_summaries(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- question_context(repo, work_request_ids),
         {:ok, decision_counts} <- decision_counts(repo, work_request_ids),
         {:ok, work_packages} <- work_packages(repo, work_request_ids),
         {:ok, phases} <- Phase.load(repo, work_requests, work_packages),
         {:ok, work_package_contexts} <- card_work_package_contexts(repo, work_packages, opts) do
      question_counts = question_context.counts
      work_packages_by_request = Enum.group_by(work_packages, & &1.work_request_id)

      with {:ok, delivery_boards} <-
             card_delivery_boards(repo, work_requests, work_packages_by_request, work_package_contexts) do
        delivery_state_opts = delivery_state_opts(opts)

        card_summaries(
          work_requests,
          phases,
          question_counts,
          decision_counts,
          work_packages_by_request,
          work_package_contexts,
          %{boards: delivery_boards, state_opts: delivery_state_opts}
        )
      end
    end
  end

  defp card_summaries(
         work_requests,
         phases,
         question_counts,
         decision_counts,
         work_packages_by_request,
         work_package_contexts,
         delivery_context
       ) do
    delivery_boards = Map.fetch!(delivery_context, :boards)
    delivery_state_opts = Map.fetch!(delivery_context, :state_opts)

    visible_work_packages_by_request =
      visible_work_packages_by_request(work_requests, work_packages_by_request, delivery_boards)

    work_package_counts =
      visible_work_packages_by_request
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> Enum.map(&{&1.work_request_id, &1.status})
      |> status_counts()

    summaries =
      Map.new(work_requests, fn %WorkRequest{} = work_request ->
        work_packages = Map.get(visible_work_packages_by_request, work_request.id, [])
        phase = Map.fetch!(phases, work_request.id)

        operational_state =
          operational_state(
            work_request,
            work_packages,
            work_package_contexts,
            phase.phase,
            Map.get(delivery_boards, work_request.id),
            delivery_state_opts
          )

        {work_request.id,
         Map.merge(phase_fields(work_request, phase), %{
           open_question_count: status_count(question_counts, work_request.id, "open"),
           answered_question_count: status_count(question_counts, work_request.id, "answered"),
           closed_question_count: status_count(question_counts, work_request.id, "closed"),
           decision_count: Map.get(decision_counts, work_request.id, 0),
           work_package_count: length(work_packages),
           planned_work_package_count: Enum.count(work_packages, &(&1.status == "planned")),
           dispatched_work_package_count: Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
           ended_work_package_count: status_count(work_package_counts, work_request.id, "ended"),
           operational_state: operational_state
         })}
      end)

    {:ok, summaries}
  end

  defp card_delivery_boards(repo, work_requests, work_packages_by_request, work_package_contexts) do
    DeliveryBoard.project_many(
      repo,
      work_requests,
      work_packages_by_request,
      delivery_board_card_opts(work_package_contexts)
    )
  end

  defp delivery_board_card_opts(work_package_contexts) do
    [
      slice_projection: :operational_state,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  defp delivery_state_opts(opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} -> [include_package_fields?: false]
      _other -> []
    end
  end

  defp card_work_package_contexts(repo, work_packages, opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} = grant -> work_package_work_package_contexts_for_grant(repo, work_packages, grant)
      _grant -> Dashboard.work_package_work_package_contexts(repo, work_packages)
    end
  end

  defp work_package_work_package_contexts_for_grant(repo, work_packages, %AccessGrant{} = grant) do
    with {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant),
         {:ok, work_package_contexts} <- Dashboard.work_package_work_package_contexts(repo, work_packages) do
      {:ok,
       Map.filter(work_package_contexts, fn
         {_work_package_id, %{work_package: %WorkPackage{} = work_package}} ->
           Dashboard.phase_work_package_matches_filters?(work_package, filters)

         _context ->
           false
       end)}
    end
  end

  defp visible_work_packages_by_request(work_requests, work_packages_by_request, delivery_boards) do
    Map.new(work_requests, fn %WorkRequest{} = work_request ->
      work_packages = Map.get(work_packages_by_request, work_request.id, [])
      delivery_board = Map.get(delivery_boards, work_request.id)

      {work_request.id, visible_work_packages(work_packages, delivery_board)}
    end)
  end

  defp question_context(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(question in ClarificationQuestion,
          where: question.work_request_id in ^chunk,
          select: {question.work_request_id, question.status}
        )
        |> repo.all()
      end)

    counts =
      rows
      |> status_counts()

    {:ok, %{counts: counts}}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp decision_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(decision in DecisionLogEntry,
          where: decision.work_request_id in ^chunk,
          select: decision.work_request_id
        )
        |> repo.all()
      end)

    {:ok, Enum.frequencies(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_packages(repo, work_request_ids) do
    work_packages(repo, work_request_ids, [])
  end

  defp work_packages(repo, work_request_ids, opts) do
    case Keyword.fetch(opts, :work_packages) do
      {:ok, work_packages} when is_list(work_packages) ->
        work_request_id_set = MapSet.new(work_request_ids)
        {:ok, Enum.filter(work_packages, &MapSet.member?(work_request_id_set, &1.work_request_id))}

      :error ->
        rows =
          chunked_work_request_rows(work_request_ids, fn chunk ->
            from(work_package in WorkPackage,
              where: work_package.work_request_id in ^chunk,
              order_by: [asc: work_package.work_request_id, asc: work_package.sequence, asc: work_package.inserted_at]
            )
            |> repo.all()
          end)

        {:ok, rows}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp chunked_work_request_rows(work_request_ids, fetch_chunk) do
    work_request_ids
    |> Enum.chunk_every(@work_request_count_chunk_size)
    |> Enum.flat_map(fetch_chunk)
  end

  defp status_counts(rows) do
    Enum.reduce(rows, %{}, fn {work_request_id, status}, counts ->
      Map.update(counts, work_request_id, %{status => 1}, &Map.update(&1, status, 1, fn count -> count + 1 end))
    end)
  end

  defp status_count(counts, work_request_id, status) do
    counts
    |> Map.get(work_request_id, %{})
    |> Map.get(status, 0)
  end

  defp card(%WorkRequest{} = work_request, summaries, repo_identity_catalog) do
    Map.merge(Map.fetch!(summaries, work_request.id), %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: creator(work_request),
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    })
    |> Chiefs.put_attribution(:dispatched_by, work_request.dispatched_by)
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp base_payload(%WorkRequest{} = work_request, repo_identity_catalog) do
    %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      human_description: redacted_text(work_request.human_description),
      constraints: redacted_json(work_request.constraints || %{}),
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: creator(work_request),
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    }
    |> Chiefs.put_attribution(:dispatched_by, work_request.dispatched_by)
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp creator(%WorkRequest{} = work_request) do
    %{
      kind: work_request.creator_kind,
      name: redacted_text(work_request.creator_name),
      via: work_request.created_via
    }
  end

  defp operational_state(
         %WorkRequest{} = work_request,
         work_packages,
         work_package_contexts,
         phase,
         delivery_board,
         delivery_state_opts
       ) do
    slice_states =
      work_package_operational_states(work_packages, work_package_contexts, delivery_board, delivery_state_opts)

    attention_items = aggregate_operational_attention(slice_states)
    promoted_state = primary_work_request_slice_state(slice_states)

    cond do
      phase == "archived" ->
        archived_operational_state(work_request, attention_items)

      phase == "done" and not is_nil(work_request.operator_completed_at) ->
        operational_state_map("completed", "Completed", "success", "The operator marked this WorkRequest done.", phase, attention_items)

      true ->
        derived_operational_state(promoted_state, work_packages, phase, attention_items, delivery_state_opts)
    end
  end

  defp derived_operational_state(promoted_state, work_packages, phase, attention_items, delivery_state_opts) do
    cond do
      match?(%{key: "needs_closeout"}, promoted_state) ->
        promoted_operational_state(promoted_state, work_packages, phase, attention_items)
        |> DeliveryWorkPackageProjection.redact_reasons(delivery_state_opts)

      phase == "unresolved" ->
        operational_state_map(
          "unresolved",
          "Unresolved",
          "warning",
          "Every package ended, but not all of them resolve the WorkRequest. Complete or archive it.",
          phase,
          attention_items
        )

      delivery_truth_operational_state?(promoted_state) ->
        promoted_operational_state(promoted_state, work_packages, phase, attention_items)
        |> DeliveryWorkPackageProjection.redact_reasons(delivery_state_opts)

      phase == "done" ->
        operational_state_map("completed", "Completed", "success", "Every package ended and the WorkRequest is resolved.", phase, attention_items)

      promoted_state ->
        promoted_operational_state(promoted_state, work_packages, phase, attention_items)

      true ->
        operational_state_map("intake", "Intake", "neutral", "No packages are planned yet.", phase, attention_items)
    end
  end

  defp archived_operational_state(%WorkRequest{archive_reason: "never_started"}, attention_items) do
    operational_state_map("archived", "Archived", "neutral", "Goal was archived because no package was ever started.", "archived", attention_items)
  end

  defp archived_operational_state(%WorkRequest{}, attention_items) do
    operational_state_map("archived", "Archived", "neutral", "The WorkRequest is archived.", "archived", attention_items)
  end

  defp work_package_operational_states(work_packages, work_package_contexts, delivery_board, delivery_state_opts) do
    delivery_work_packages_by_id = DeliveryWorkPackageProjection.work_packages_by_id(delivery_board)

    Enum.map(work_packages, fn %WorkPackage{} = work_package ->
      OperationalProjection.work_package_operational_state(
        work_package,
        Map.get(work_package_contexts, work_package.id),
        Map.get(delivery_work_packages_by_id, work_package.id),
        delivery_state_opts
      )
    end)
  end

  defp primary_work_request_slice_state([]), do: nil

  defp primary_work_request_slice_state(slice_states) do
    Enum.find_value(@work_request_slice_state_priority, fn key ->
      Enum.find(slice_states, &(Map.get(&1, :key) == key))
    end)
  end

  defp delivery_truth_operational_state?(%{key: "needs_closeout"}), do: true
  defp delivery_truth_operational_state?(%{delivery_outcome: outcome}) when is_binary(outcome), do: true
  defp delivery_truth_operational_state?(_state), do: false

  defp promoted_operational_state(promoted_state, work_packages, phase, attention_items) do
    promoted_state
    |> OperationalProjection.operational_activity_fields()
    |> Map.merge(
      operational_state_map(
        promoted_state.key,
        promoted_state.label,
        promoted_state.tone,
        "Most actionable WorkPackage state is #{promoted_state.label} across #{length(work_packages)} package(s).",
        phase,
        attention_items
      )
    )
  end

  defp aggregate_operational_attention(operational_states) do
    operational_states
    |> Enum.flat_map(&Map.get(&1, :attention_items, []))
    |> Enum.uniq_by(&Map.get(&1, :key))
  end

  defp operational_state_map(key, label, tone, reason, phase, attention_items) do
    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      phase: phase,
      attention_items: attention_items
    }
  end

  defp put_repo_identity_fields(payload, repo_identity_catalog, repo_value) when is_map(payload) do
    Map.merge(payload, RepoIdentity.fields(repo_identity_catalog, repo_value))
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp sortable_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp sortable_timestamp(_timestamp), do: ""

  defp redacted_json(value), do: Sanitizer.redacted_json(value)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
