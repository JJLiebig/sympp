defmodule SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    OperationalProjection,
    Sanitizer,
    WorkRequestCards
  }

  alias SymphonyElixir.SymphonyPlusPlus.DeploymentObservation
  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.OperatorConfig
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Retention
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @local_operator_actor "local-operator"

  @spec operator_dashboard_payload(module()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_payload(repo) do
    operator_config = OperatorConfig.load()

    with {:ok, context} <- operator_dashboard_context(repo),
         {:ok, work_requests} <- WorkRequestRepository.list(repo) do
      priority_dashboard_payload(repo, Map.put(context, :operator_config, operator_config), work_requests)
    end
  end

  defp priority_dashboard_payload(repo, context, work_requests) do
    priority_dashboard_payload(repo, context, work_requests, %{})
  end

  defp priority_dashboard_payload(repo, context, work_requests, projection_context) do
    ordered_work_requests = WorkRequestCards.ordered_work_requests(work_requests)

    with {:ok, cards} <-
           WorkRequestCards.priority_cards(repo, ordered_work_requests, dashboard_opts(context, projection_context)) do
      {:ok,
       context
       |> base_payload()
       |> Map.merge(%{
         work_requests: %{
           work_requests: Enum.map(cards, &put_work_request_location(put_area_path(&1, context), context, projection_context)),
           total_count: length(cards)
         },
         deferred: %{dashboard_sections: true}
       })}
    end
  end

  @spec operator_dashboard_deferred_payload(module()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_deferred_payload(repo) do
    operator_config = OperatorConfig.load()

    with {:ok, work_requests} <- WorkRequestRepository.list(repo),
         {:ok, context} <- operator_execution_context(repo, work_requests),
         {:ok, projection_context} <- operator_projection_context(repo, work_requests, context) do
      execution_dashboard_payload(repo, Map.put(context, :operator_config, operator_config), work_requests, projection_context)
    end
  end

  defp execution_dashboard_payload(repo, context, work_requests, projection_context) do
    opts = dashboard_opts(context, projection_context)

    board_detail_opts =
      opts
      |> Keyword.put(:work_requests, work_requests)
      |> Keyword.put(:work_packages_by_request, projection_context.work_packages_by_request)

    with {:ok, execution_signals} <-
           Dashboard.operator_work_package_signals(repo, context.active_work_request_work_package_ids, opts),
         {:ok, work_request_details} <-
           operator_work_request_board_details(repo, work_requests, context.repo_identity_catalog, board_detail_opts) do
      {:ok,
       %{
         generated_at: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
         active_blocking_edges: execution_signals.active_blocking_edges,
         work_packages: execution_signals.work_packages,
         work_request_details: operator_board_labels(work_request_details, context, projection_context),
         deferred: %{dashboard_sections: false}
       }}
    end
  end

  @spec operator_dashboard_surface_payload(module(), String.t()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_surface_payload(repo, surface) when surface in ["archived", "solo"] do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo) do
      opts = [repo_identity_catalog: repo_identity_catalog]
      dashboard_surface_payload(repo, surface, opts)
    end
  end

  defp dashboard_surface_payload(repo, "archived", opts) do
    with {:ok, archived_work_requests} <- Dashboard.archived_work_requests(repo, opts) do
      {:ok, %{generated_at: timestamp(DateTime.utc_now(:microsecond)), archived_work_requests: archived_work_requests}}
    end
  end

  defp dashboard_surface_payload(repo, "solo", opts) do
    with {:ok, solo_sessions} <- Dashboard.solo_sessions(repo, %{}, opts) do
      {:ok, %{generated_at: timestamp(DateTime.utc_now(:microsecond)), solo_sessions: solo_sessions}}
    end
  end

  @spec operator_dashboard_hydrated_payload(module()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_hydrated_payload(repo) do
    operator_config = OperatorConfig.load()

    case repo.transaction(fn -> hydrated_dashboard_payload(repo, operator_config) end) do
      {:ok, {:ok, payload}} -> {:ok, DeploymentObservation.enrich(payload, operator_config)}
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrated_dashboard_payload(repo, operator_config) do
    with {:ok, work_requests} <- WorkRequestRepository.list(repo),
         {:ok, context} <- operator_execution_context(repo, work_requests),
         context = Map.put(context, :operator_config, operator_config),
         {:ok, projection_context} <- operator_projection_context(repo, work_requests, context),
         {:ok, base} <- priority_dashboard_payload(repo, context, work_requests, projection_context),
         {:ok, active} <- execution_dashboard_payload(repo, context, work_requests, projection_context) do
      {:ok, Map.merge(base, active) |> Map.put(:runtime, %{offline: OfflineSandbox.enabled?()})}
    end
  end

  @spec herdr_dashboard_payload(module()) :: {:ok, map()} | {:error, term()}
  def herdr_dashboard_payload(repo) do
    operator_config = OperatorConfig.load()

    case repo.transaction(fn -> native_dashboard_payload(repo, operator_config) end) do
      {:ok, {:ok, payload}} -> {:ok, payload |> DeploymentObservation.enrich(operator_config) |> native_projection()}
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp native_dashboard_payload(repo, operator_config) do
    with {:ok, work_requests} <- WorkRequestRepository.list(repo),
         {:ok, context} <- operator_execution_context(repo, work_requests),
         context = Map.put(context, :operator_config, operator_config),
         {:ok, projection_context} <- operator_projection_context(repo, work_requests, context),
         {:ok, active} <- execution_dashboard_payload(repo, context, work_requests, projection_context) do
      details = Enum.map(active.work_request_details, &native_attention_detail/1)

      {:ok,
       active
       |> Map.put(:work_request_details, details)
       |> Map.take([:generated_at, :work_request_details])
       |> Map.put(:work_packages, Enum.map(active.work_packages, &Map.take(&1, [:id, :active_agent_run])))
       |> Map.put(:runtime, %{offline: OfflineSandbox.enabled?(), repos_root: SymphonyElixir.Config.factory_repos_root()})}
    end
  end

  defp native_attention_detail(detail) do
    detail
    |> Map.put(:asks, native_asks(detail))
    |> Map.put(:decisions_to_review, native_decisions_to_review(detail))
  end

  # Keep this projection aligned with parseBoard/buildJob/buildPackage in Herdr's model.js.
  # The web inspector continues to receive the complete detail projection.
  defp native_projection(payload) do
    Map.update!(payload, :work_request_details, &Enum.map(&1, fn detail -> native_detail(detail) end))
  end

  defp native_detail(detail) do
    detail
    |> Map.take([:work_request, :work_packages, :product_tree, :asks, :decisions_to_review])
    |> Map.update!(
      :work_request,
      &Map.take(&1, [
        :id,
        :title,
        :phase,
        :repo,
        :repo_display,
        :area_path,
        :base_branch,
        :default_branch,
        :inserted_at,
        :completed_at,
        :operator_report,
        :worked_on,
        :dispatched_by,
        :deployments
      ])
    )
    |> Map.update!(:work_packages, fn packages ->
      Enum.map(
        packages,
        &Map.take(&1, [
          :id,
          :work_package_id,
          :title,
          :repo,
          :repo_display,
          :sequence,
          :group,
          :status,
          :raw_status,
          :dispatched_at,
          :inserted_at,
          :dispatched_by,
          :delivery,
          :board_state,
          :repo_signal,
          :pr_signal,
          :review_signal,
          :review,
          :activity_signal,
          :operational_state,
          :dependency_signal,
          :session_location
        ])
      )
    end)
    |> Map.update!(:product_tree, &native_product_tree/1)
  end

  @doc false
  @spec native_asks(map()) :: [map()]
  def native_asks(detail) do
    for ask <- detail.asks, ask.state == "open", is_binary(ask.question) and String.trim(ask.question) != "" do
      %{
        id: ask.id,
        kind: "ask",
        text: ask.question,
        work_package_id: ask.work_package_id,
        decision_prompt: ask.decision_prompt,
        asked_by: ask.asked_by,
        asked_at: ask.asked_at,
        answer_route: "/api/v1/sympp/herdr/asks/#{URI.encode_www_form(ask.id)}/answer"
      }
    end
  end

  @doc false
  @spec native_decisions_to_review(map()) :: [map()]
  def native_decisions_to_review(detail) do
    for decision <- detail.decisions_to_review do
      base = "/api/v1/sympp/herdr/decisions/#{URI.encode_www_form(decision.id)}"
      Map.merge(decision, native_decision_routes(decision.next_action, base))
    end
  end

  defp native_decision_routes("ack or feedback", base), do: %{ack_route: base <> "/ack", feedback_route: base <> "/feedback"}
  defp native_decision_routes("dismiss", base), do: %{dismiss_route: base <> "/dismiss"}
  defp native_decision_routes(_wait, _base), do: %{}

  defp native_product_tree(tree) do
    tree
    |> Map.take([:execution_graph])
    |> Map.update!(:execution_graph, &Map.take(&1, [:effective_edges]))
  end

  defp put_area_path(work_request, context) do
    Map.put(work_request, :area_path, OperatorConfig.area_path(context.operator_config, work_request))
  end

  defp operator_board_labels(details, context, projection_context) do
    Enum.map(details, fn detail ->
      work_packages =
        Enum.map(detail.work_packages, &put_session_location(&1, context.operator_config, projection_context))

      work_request =
        detail.work_request
        |> put_area_path(context)
        |> put_work_request_location(context, projection_context)

      %{detail | work_request: work_request, work_packages: work_packages}
    end)
  end

  defp put_session_location(work_package, operator_config, projection_context) do
    session = get_in(projection_context, [:work_package_contexts, work_package.id, :current_worker_session])

    case OperatorConfig.session_location(operator_config, session) do
      nil -> work_package
      location -> Map.put(work_package, :session_location, location)
    end
  end

  # Which Herdr terminal works on the WorkRequest, with live / unknown /
  # finished liveness.
  defp put_work_request_location(work_request, _context, projection_context) do
    case get_in(projection_context, [:worked_on, work_request.id]) do
      nil -> work_request
      owner -> Map.put(work_request, :worked_on, owner)
    end
  end

  defp operator_projection_context(repo, work_requests, context) do
    with {:ok, projection} <- Dashboard.operator_projection_context(repo, work_requests, context.work_packages) do
      {:ok, Map.put(projection, :worked_on, Ownership.owners(repo, Enum.map(work_requests, & &1.id)))}
    end
  end

  defp operator_dashboard_context(repo) do
    operator_dashboard_context(repo, false, nil)
  end

  defp operator_dashboard_context(repo, false, _work_requests) do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
         {:ok, settings} <- OperatorSettingsRepository.get(repo),
         {:ok, work_request_work_package_id_sets} <- work_request_work_package_id_sets(repo, false) do
      {:ok, operator_dashboard_context_map(repo, repo_identity_catalog, settings, work_request_work_package_id_sets)}
    end
  end

  defp operator_dashboard_context(repo, true, work_requests) do
    with {:ok, settings} <- OperatorSettingsRepository.get(repo),
         {:ok, work_request_work_package_id_sets} <- work_request_work_package_id_sets(repo, true),
         {:ok, repo_identity_catalog} <-
           execution_repo_identity_catalog(repo, work_request_work_package_id_sets, work_requests) do
      {:ok, operator_dashboard_context_map(repo, repo_identity_catalog, settings, work_request_work_package_id_sets)}
    end
  end

  defp execution_repo_identity_catalog(repo, work_request_work_package_id_sets, work_requests) do
    Dashboard.local_operator_repo_identity_catalog(
      repo,
      work_request_work_package_id_sets.work_packages,
      work_requests
    )
  end

  defp operator_dashboard_context_map(repo, repo_identity_catalog, settings, work_request_work_package_id_sets) do
    context = %{
      repo: repo,
      repo_identity_catalog: repo_identity_catalog,
      settings_record: settings,
      settings: operator_settings_payload(settings),
      active_work_request_work_package_ids: work_request_work_package_id_sets.active |> MapSet.to_list() |> Enum.sort(),
      archived_work_request_work_package_ids: work_request_work_package_id_sets.archived_only
    }

    maybe_put_work_packages(context, work_request_work_package_id_sets)
  end

  defp operator_execution_context(repo, work_requests) do
    with {:ok, context} <- operator_dashboard_context(repo, true, work_requests),
         {:ok, expired_unwork_request_work_package_ids} <-
           expired_unwork_request_work_package_ids_for_local_operator(
             repo,
             context.settings_record,
             MapSet.new(context.active_work_request_work_package_ids)
           ) do
      hidden_work_package_ids =
        context.settings_record
        |> effective_hidden_work_package_ids(MapSet.new(context.active_work_request_work_package_ids))
        |> MapSet.union(expired_unwork_request_work_package_ids)
        |> MapSet.union(context.archived_work_request_work_package_ids)

      {:ok, Map.put(context, :hidden_work_package_ids, hidden_work_package_ids)}
    end
  end

  defp maybe_put_work_packages(context, %{work_packages: work_packages}),
    do: Map.put(context, :work_packages, work_packages)

  defp maybe_put_work_packages(context, _work_request_work_package_id_sets), do: context

  defp dashboard_opts(context, projection_context) do
    projection_opts =
      case projection_context do
        %{
          work_packages: work_packages,
          work_package_contexts: work_package_contexts,
          product_trees_by_request: product_trees_by_request,
          deliveries_by_slice_id: deliveries_by_slice_id
        } ->
          [
            work_packages: work_packages,
            work_package_contexts: work_package_contexts,
            product_trees_by_request: product_trees_by_request,
            deliveries_by_slice_id: deliveries_by_slice_id
          ]

        _other ->
          []
      end

    [
      repo_identity_catalog: context.repo_identity_catalog,
      hidden_work_package_ids: Map.get(context, :hidden_work_package_ids, MapSet.new())
    ] ++ projection_opts
  end

  defp base_payload(context) do
    %{
      generated_at: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
      ledger: %{database: dashboard_ledger_database(context.repo)},
      settings: context.settings,
      linked_work_package_ids: context.active_work_request_work_package_ids
    }
  end

  defp effective_hidden_work_package_ids(%OperatorSettings{} = settings, work_request_work_package_ids) do
    settings.hidden_work_package_ids
    |> MapSet.new()
    |> MapSet.difference(work_request_work_package_ids)
  end

  defp expired_unwork_request_work_package_ids_for_local_operator(repo, %OperatorSettings{} = settings, work_request_work_package_ids) do
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -settings.work_request_archive_after_days * 24 * 60 * 60, :second)

    WorkPackage
    |> expired_terminal_work_package_query(cutoff)
    |> repo.all()
    |> MapSet.new()
    |> MapSet.difference(work_request_work_package_ids)
    |> then(&{:ok, &1})
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp expired_terminal_work_package_query(queryable, cutoff) do
    from(work_package in queryable,
      where: work_package.status == "ended",
      where: is_nil(work_package.parent_id),
      where: is_nil(work_package.phase_id),
      where: is_nil(work_package.work_request_id),
      where: work_package.updated_at <= ^cutoff,
      select: work_package.id
    )
  end

  defp work_request_work_package_id_sets(repo, include_work_packages?) do
    {rows, work_packages} =
      if include_work_packages? do
        rows =
          repo.all(
            from(work_package in WorkPackage,
              left_join: work_request in WorkRequest,
              on: work_request.id == work_package.work_request_id,
              order_by: [asc: work_package.inserted_at, asc: work_package.id],
              select: {work_package, work_request.id, work_request.archived_at}
            )
          )

        {rows, Enum.map(rows, &elem(&1, 0))}
      else
        rows =
          repo.all(
            from(work_package in WorkPackage,
              left_join: work_request in WorkRequest,
              on: work_request.id == work_package.work_request_id,
              where: not is_nil(work_package.work_request_id),
              select: {work_package.id, work_request.id, work_request.archived_at}
            )
          )

        {rows, nil}
      end

    sets =
      Enum.reduce(rows, %{active: MapSet.new(), archived: MapSet.new()}, fn
        {%WorkPackage{}, nil, _archived_at}, sets ->
          sets

        {%WorkPackage{id: work_package_id}, _work_request_id, archived_at}, sets when is_nil(archived_at) ->
          %{sets | active: MapSet.put(sets.active, work_package_id)}

        {%WorkPackage{id: work_package_id}, _work_request_id, _archived_at}, sets ->
          %{sets | archived: MapSet.put(sets.archived, work_package_id)}

        {_work_package_id, nil, _archived_at}, sets ->
          sets

        {work_package_id, _work_request_id, nil}, sets ->
          %{sets | active: MapSet.put(sets.active, work_package_id)}

        {work_package_id, _work_request_id, _archived_at}, sets ->
          %{sets | archived: MapSet.put(sets.archived, work_package_id)}
      end)

    result = %{
      active: sets.active,
      archived_only: MapSet.difference(sets.archived, sets.active)
    }

    result =
      if is_nil(work_packages) do
        result
      else
        Map.put(result, :work_packages, work_packages)
      end

    {:ok, result}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec operator_work_request_detail_payload(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def operator_work_request_detail_payload(repo, work_request_id, opts \\ []) when is_binary(work_request_id) do
    with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
         {:ok, phase} <- Phase.load_one(repo, work_request),
         {:ok, decisions} <- WorkRequestRepository.list_decisions(repo, work_request_id),
         {:ok, selected_work_package} <- operator_selected_work_package(repo, work_request_id, opts) do
      newest_decisions = Enum.reverse(decisions)
      visible_decisions = if Keyword.get(opts, :all_decisions?, false), do: newest_decisions, else: Enum.take(newest_decisions, 3)
      asks = Map.get(Asks.by_work_request(repo, [work_request_id]), work_request_id, [])

      payload =
        %{
          work_request: operator_work_request_enrichment(work_request, phase),
          asks: Enum.map(asks, &Dashboard.ask/1),
          decision_logs: Enum.map(visible_decisions, &Dashboard.decision_log_entry/1),
          summary: %{
            open_ask_count: Enum.count(asks, &(&1.state == "open")),
            decision_count: length(decisions)
          }
        }

      {:ok,
       if selected_work_package do
         Map.put(
           payload,
           :work_packages,
           Dashboard.work_package_payloads([selected_work_package], %{}, false, delivery_board: nil)
         )
       else
         payload
       end}
    end
  end

  @spec herdr_work_request_detail_payload(module(), String.t()) :: {:ok, map()} | {:error, term()}
  def herdr_work_request_detail_payload(repo, work_request_id) when is_binary(work_request_id) do
    with {:ok, payload} <- operator_work_request_detail_payload(repo, work_request_id, all_decisions?: true),
         {:ok, [board_detail]} <- operator_work_request_board_details(repo, [%{id: work_request_id}], nil),
         {:ok, work_packages} <- WorkRequestRepository.list_work_packages(repo, work_request_id),
         {:ok, contexts} <- Dashboard.work_package_work_package_contexts(repo, work_packages) do
      graph = get_in(board_detail, [:product_tree, :execution_graph])

      {:ok,
       payload
       |> Map.put(:work_packages, board_detail.work_packages)
       |> Map.put(:product_tree, board_detail.product_tree)
       |> Map.put(:execution_graph, graph)
       |> Map.put(:attention_keys, herdr_attention_keys(board_detail))
       |> Map.put(:worker_sessions, herdr_worker_sessions(work_packages, contexts))}
    end
  end

  # A package needing attention marks itself and every group on its path, so
  # the inspector opens the groups that lead to it. A group's id is its path.
  defp herdr_attention_keys(board_detail) do
    board_detail.work_packages
    |> Enum.filter(&((get_in(&1, [:operational_state, :attention_items]) || []) != []))
    |> Enum.flat_map(fn package -> ["work_package:#{package.id}" | Enum.map(group_path_prefixes(package[:group]), &"group:#{&1}")] end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp group_path_prefixes(path) do
    path
    |> WorkPackage.group_segments()
    |> Enum.scan(&"#{&2} / #{&1}")
  end

  defp herdr_worker_sessions(work_packages, contexts) do
    work_packages
    |> Enum.flat_map(fn work_package ->
      contexts
      |> Map.get(work_package.id, %{})
      |> Map.get(:agent_runs, [])
      |> OperationalProjection.latest_active_agent_run()
      |> case do
        %{session_id: session_id} when is_binary(session_id) and session_id != "" ->
          [%{work_package_id: work_package.id, agent_session_id: session_id}]

        _run ->
          []
      end
    end)
  end

  defp operator_selected_work_package(repo, work_request_id, opts) do
    case Keyword.get(opts, :work_package_id) do
      nil -> {:ok, nil}
      work_package_id -> WorkRequestRepository.get_work_package(repo, work_request_id, work_package_id)
    end
  end

  defp operator_work_request_enrichment(%WorkRequest{} = work_request, phase) do
    %{
      id: work_request.id,
      title: Sanitizer.redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      human_description: Sanitizer.redacted_text(work_request.human_description),
      constraints: Sanitizer.redacted_json(work_request.constraints || %{}),
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: %{
        kind: work_request.creator_kind,
        name: Sanitizer.redacted_text(work_request.creator_name),
        via: work_request.created_via
      },
      phase: phase.phase,
      completed_at: timestamp(phase.completed_at),
      operator_completed_at: timestamp(work_request.operator_completed_at),
      archived_at: timestamp(work_request.archived_at),
      archive_reason: work_request.archive_reason,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    }
    |> Dashboard.put_attribution(:dispatched_by, work_request.dispatched_by)
  end

  @spec operator_work_request_board_details(module(), [map()], term()) :: {:ok, [map()]} | {:error, term()}
  def operator_work_request_board_details(repo, work_request_cards, repo_identity_catalog)
      when is_list(work_request_cards) do
    operator_work_request_board_details(repo, work_request_cards, repo_identity_catalog, [])
  end

  @spec operator_work_request_board_details(module(), [map()], term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def operator_work_request_board_details(repo, work_request_cards, repo_identity_catalog, opts)
      when is_list(work_request_cards) and is_list(opts) do
    work_request_ids =
      work_request_cards
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)

    Dashboard.work_request_board_details(repo, work_request_ids, Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog))
  end

  @spec work_request_attrs(map()) :: map()
  def work_request_attrs(params) do
    %{
      "title" => text_param(params, "title"),
      "repo" => text_param(params, "repo"),
      "base_branch" => text_param(params, "base_branch"),
      "work_type" => text_param(params, "work_type", "feature"),
      "human_description" => text_param(params, "human_description"),
      "desired_dispatch_shape" => text_param(params, "desired_dispatch_shape", "architect_led_feature_branch"),
      "creator_kind" => text_param(params, "creator_kind", "human"),
      "creator_name" => text_param(params, "creator_name", @local_operator_actor),
      "created_via" => text_param(params, "created_via", "cockpit"),
      "constraints" => constraints_param(params)
    }
  end

  @spec operator_settings_attrs(map()) :: map()
  def operator_settings_attrs(params) do
    %{}
    |> put_settings_param(params, "work_request_archive_after_days")
    |> put_settings_param(params, "work_request_never_started_archive_after_days")
    |> put_settings_param(params, "solo_session_delete_after_days")
    |> put_settings_param(params, "open_dashboard_on_boot")
    |> put_settings_param(params, "capture_failed_mcp_calls")
  end

  defp put_settings_param(attrs, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> put_atom_settings_param(attrs, params, key)
    end
  end

  defp put_atom_settings_param(attrs, params, key) do
    atom_key = String.to_existing_atom(key)

    case Map.fetch(params, atom_key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  @spec operator_settings_payload(OperatorSettings.t()) :: map()
  def operator_settings_payload(%OperatorSettings{} = settings) do
    %{
      work_request_archive_after_days: settings.work_request_archive_after_days,
      work_request_never_started_archive_after_days: settings.work_request_never_started_archive_after_days,
      solo_session_delete_after_days: settings.solo_session_delete_after_days,
      open_dashboard_on_boot: settings.open_dashboard_on_boot,
      capture_failed_mcp_calls: settings.capture_failed_mcp_calls,
      hidden_work_package_ids: Enum.uniq(settings.hidden_work_package_ids)
    }
  end

  @spec run_operator_retention(module(), OperatorSettings.t(), keyword()) :: :ok | {:error, term()}
  def run_operator_retention(repo, %OperatorSettings{} = settings, opts \\ []) do
    Retention.run(repo, settings, opts)
  end

  @doc "The WorkRequest after an operator complete, archive or restore."
  @spec work_request_mutation_payload(module(), WorkRequest.t()) :: {:ok, map()} | {:error, term()}
  def work_request_mutation_payload(repo, %WorkRequest{} = work_request) do
    with {:ok, phase} <- Phase.load_one(repo, work_request) do
      {:ok,
       %{
         id: work_request.id,
         phase: phase.phase,
         completed_at: timestamp(phase.completed_at),
         operator_completed_at: timestamp(work_request.operator_completed_at),
         archived_at: timestamp(work_request.archived_at),
         archive_reason: work_request.archive_reason
       }}
    end
  end

  defp dashboard_ledger_database(repo) do
    Repo.operator_database_path(repo)
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  defp constraints_param(%{"constraints" => constraints}) when is_map(constraints), do: constraints
  defp constraints_param(%{constraints: constraints}) when is_map(constraints), do: constraints

  defp constraints_param(params) do
    params
    |> Map.take(["allowed_paths", "forbidden_paths", "stop_conditions", "compatibility_stance", "validation_expectations", "dependencies_notes"])
    |> Enum.reject(fn {_key, value} -> blank_param?(value) end)
    |> Map.new(fn {key, value} -> {key, normalize_constraint_value(value)} end)
  end

  defp normalize_constraint_value(value) when is_list(value), do: value |> Enum.map(&text_value/1) |> Enum.reject(&(&1 == ""))
  defp normalize_constraint_value(value) when is_binary(value), do: newline_list(value)
  defp normalize_constraint_value(value), do: value

  defp newline_list(value) do
    value
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp text_param(params, key, default \\ nil) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp text_value(value) when is_binary(value), do: String.trim(value)
  defp text_value(nil), do: ""
  defp text_value(value), do: to_string(value)

  defp blank_param?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_param?(value) when is_list(value), do: value |> Enum.map(&text_value/1) |> Enum.all?(&(&1 == ""))
  defp blank_param?(nil), do: true
  defp blank_param?(_value), do: false

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
end
