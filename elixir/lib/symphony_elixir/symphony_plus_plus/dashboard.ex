defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    BlockerProjection,
    DeliveryWorkPackageProjection,
    MetadataProjection,
    OperationalProjection,
    Sanitizer,
    SoloSessionProjection,
    WorkRequestCards,
    WorkRequestDetails
  }

  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @ready_statuses ["ready"]
  @work_package_context_chunk_size 500
  @operator_finished_work_package_limit 80
  @finished_work_package_candidate_multiplier 3
  @finished_work_package_min_candidate_limit 40
  @finished_progress_lookup_chunk_size 500
  @operator_work_package_signal_keys [
    :active_agent_run,
    :active_blocker_count,
    :active_blockers,
    :id,
    :inserted_at,
    :latest_progress_at,
    :metadata,
    :runtime,
    :updated_at
  ]
  @operator_work_package_metadata_keys [:pr, :review_progress, :review_suite_result]

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo) when is_atom(repo) do
    board(repo, [])
  end

  @spec board(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn -> build_board(repo, opts) end)
  end

  @spec operator_board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_board(repo) when is_atom(repo) do
    operator_board(repo, [])
  end

  @spec operator_board(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_board(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      opts
      |> Keyword.put(:active_blocking_edges?, true)
      |> Keyword.put_new(:finished_work_package_limit, @operator_finished_work_package_limit)
      |> then(&build_board(repo, &1))
    end)
  end

  @spec operator_projection_context(repo(), [WorkRequest.t()]) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_projection_context(repo, work_requests)
      when is_atom(repo) and is_list(work_requests) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo) do
      operator_projection_context(repo, work_requests, work_packages)
    end
  end

  @spec operator_projection_context(repo(), [WorkRequest.t()], [WorkPackage.t()]) ::
          {:ok, map()} | {:error, dashboard_error()}
  def operator_projection_context(repo, work_requests, work_packages)
      when is_atom(repo) and is_list(work_requests) and is_list(work_packages) do
    safe_read(fn ->
      work_request_ids = MapSet.new(work_requests, & &1.id)

      work_packages_by_request =
        work_packages
        |> Enum.filter(&MapSet.member?(work_request_ids, &1.work_request_id))
        |> Enum.group_by(& &1.work_request_id)

      linked_work_packages = all_work_packages(work_requests, work_packages_by_request)

      with {:ok, work_package_contexts} <- work_package_work_package_contexts(repo, linked_work_packages),
           {:ok, product_trees_by_request} <-
             product_tree_contexts_for_work_requests(repo, MapSet.to_list(work_request_ids)),
           {:ok, deliveries_by_slice_id} <-
             DeliveryBoard.work_package_deliveries_by_id(repo, linked_work_packages) do
        {:ok,
         %{
           work_packages: work_packages,
           work_packages_by_request: work_packages_by_request,
           work_package_contexts: work_package_contexts,
           product_trees_by_request: product_trees_by_request,
           deliveries_by_slice_id: deliveries_by_slice_id
         }}
      end
    end)
  end

  @spec operator_work_package_signals(repo(), [String.t()], keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_work_package_signals(repo, work_package_ids, opts)
      when is_atom(repo) and is_list(work_package_ids) and is_list(opts) do
    safe_read(fn ->
      visible_ids = MapSet.difference(MapSet.new(work_package_ids), hidden_work_package_ids(opts))

      with {:ok, all_work_packages} <- operator_signal_work_packages(repo, opts),
           work_packages = Enum.filter(all_work_packages, &MapSet.member?(visible_ids, &1.id)),
           {:ok, repo_identity_catalog} <-
             operator_signal_repo_identity_catalog(repo, opts, work_packages),
           {:ok, contexts} <- card_contexts_for_packages(repo, work_packages, repo_identity_catalog, opts),
           {:ok, active_blocking_edges} <-
             operator_signal_blocking_edges(repo, contexts, all_work_packages) do
        signals =
          contexts
          |> Enum.map(&compact_operator_work_package_signal(&1.card))
          |> Enum.sort_by(& &1.id)

        {:ok, %{work_packages: signals, active_blocking_edges: active_blocking_edges}}
      end
    end)
  end

  defp operator_signal_blocking_edges(repo, contexts, all_work_packages) do
    active_blocking_edges_from_card_contexts(repo, contexts, all_work_packages)
  end

  defp operator_signal_work_packages(repo, opts) do
    case Keyword.fetch(opts, :work_packages) do
      {:ok, work_packages} when is_list(work_packages) -> {:ok, work_packages}
      :error -> WorkPackageRepository.list(repo)
    end
  end

  defp operator_signal_repo_identity_catalog(repo, opts, work_packages) do
    repo_identity_catalog_from_repo(repo, opts, Enum.map(work_packages, & &1.repo))
  end

  defp product_tree_contexts_for_work_requests(repo, work_request_ids) do
    case ProductTree.trees_for_work_requests(repo, work_request_ids) do
      {:ok, trees} ->
        {:ok, Map.new(trees, fn {work_request_id, tree} -> {work_request_id, {:ok, tree}} end)}

      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason) do
          {:ok, Map.new(work_request_ids, &{&1, error})}
        else
          error
        end
    end
  end

  defp missing_product_tree_schema_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
  end

  defp compact_operator_work_package_signal(card) do
    card
    |> Map.take(@operator_work_package_signal_keys)
    |> Map.update(:metadata, nil, fn
      metadata when is_map(metadata) -> Map.take(metadata, @operator_work_package_metadata_keys)
      _metadata -> nil
    end)
  end

  @spec repo_identity_catalog(repo()) :: {:ok, RepoIdentity.catalog()} | {:error, dashboard_error()}
  def repo_identity_catalog(repo) when is_atom(repo) do
    safe_read(fn ->
      {:ok,
       repo
       |> repo_identity_repo_values()
       |> build_repo_identity_catalog()}
    end)
  end

  @spec local_operator_repo_identity_catalog(repo()) :: {:ok, RepoIdentity.catalog()} | {:error, dashboard_error()}
  def local_operator_repo_identity_catalog(repo) when is_atom(repo) do
    safe_read(fn ->
      {:ok,
       repo
       |> repo_identity_repo_values()
       |> build_repo_identity_catalog(local_operator_trusted_repo_remotes(), local_path_remotes?: true)}
    end)
  end

  @spec local_operator_repo_identity_catalog(repo(), [WorkPackage.t()], [WorkRequest.t()]) ::
          {:ok, RepoIdentity.catalog()} | {:error, dashboard_error()}
  def local_operator_repo_identity_catalog(repo, work_packages, work_requests)
      when is_atom(repo) and is_list(work_packages) and is_list(work_requests) do
    safe_read(fn ->
      repo_values =
        Enum.map(work_packages, & &1.repo) ++
          Enum.map(work_requests, & &1.repo) ++
          repo_values(repo, WorkRequest) ++ repo_values(repo, SoloSession)

      {:ok, build_repo_identity_catalog(repo_values, local_operator_trusted_repo_remotes(), local_path_remotes?: true)}
    end)
  end

  @spec phase_board(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    phase_board(repo, phase_id, [])
  end

  @spec phase_board(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id, filters) when is_atom(repo) and is_binary(phase_id) and is_list(filters) do
    safe_read(fn -> build_phase_board(repo, phase_id, filters) end)
  end

  @spec work_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests(repo) when is_atom(repo) do
    work_requests(repo, [])
  end

  @spec work_requests(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(work_requests, & &1.repo)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests), Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)) do
        cards = visible_work_request_cards(cards)

        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec archived_work_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def archived_work_requests(repo) when is_atom(repo) do
    archived_work_requests(repo, [])
  end

  @doc false
  @spec work_request_sections(repo(), keyword()) ::
          {:ok, %{active: map(), archived: map()}} | {:error, dashboard_error()}
  def work_request_sections(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(work_requests, & &1.repo)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests), Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)) do
        active_cards = visible_work_request_cards(cards)
        archived_cards = Enum.filter(cards, &(not is_nil(&1.archived_at)))

        {:ok,
         %{
           active: %{work_requests: active_cards, total_count: length(active_cards)},
           archived: %{work_requests: archived_cards, total_count: length(archived_cards)}
         }}
      end
    end)
  end

  @spec archived_work_requests(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def archived_work_requests(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           archived_work_requests = Enum.filter(work_requests, &(not is_nil(&1.archived_at))),
           {:ok, repo_identity_catalog} <-
             repo_identity_catalog_from_repo(repo, opts, Enum.map(archived_work_requests, & &1.repo)),
           {:ok, cards} <-
             work_request_cards(
               repo,
               ordered_work_requests(archived_work_requests),
               Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)
             ) do
        cards = Enum.filter(cards, &(not is_nil(&1.archived_at)))

        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec solo_sessions(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  @spec solo_sessions(repo(), map()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_sessions(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    solo_sessions(repo, filters, [])
  end

  @spec solo_sessions(repo(), map(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_sessions(repo, filters, opts) when is_atom(repo) and is_map(filters) and is_list(opts) do
    SoloSessionProjection.list(repo, filters, opts)
  end

  @spec solo_session_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id) when is_atom(repo) and is_binary(solo_session_id) do
    solo_session_detail(repo, solo_session_id, [])
  end

  @spec solo_session_detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id, opts) when is_atom(repo) and is_binary(solo_session_id) and is_list(opts) do
    SoloSessionProjection.detail(repo, solo_session_id, opts)
  end

  @spec solo_session_repos(repo()) :: {:ok, [String.t()]} | {:error, dashboard_error()}
  def solo_session_repos(repo) when is_atom(repo) do
    SoloSessionProjection.repos(repo)
  end

  @spec solo_session_streams(repo()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo) when is_atom(repo) do
    solo_session_streams(repo, [])
  end

  @spec solo_session_streams(repo(), keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo, opts) when is_atom(repo) and is_list(opts) do
    SoloSessionProjection.streams(repo, opts)
  end

  @spec solo_session_count(repo()) :: {:ok, non_neg_integer()} | {:error, dashboard_error()}
  def solo_session_count(repo) when is_atom(repo) do
    SoloSessionProjection.count(repo)
  end

  defp put_repo_identity_fields(payload, repo_identity_catalog, repo_value) when is_map(payload) do
    Map.merge(payload, RepoIdentity.fields(repo_identity_catalog, repo_value))
  end

  @spec work_request_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    work_request_detail(repo, work_request_id, [])
  end

  @spec work_request_detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, work_request_id, opts) when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with {:ok, [detail]} <- work_request_details(repo, [work_request_id], opts) do
      {:ok, detail}
    end
  end

  @spec work_request_board_details(repo(), [String.t()]) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_board_details(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    work_request_board_details(repo, work_request_ids, [])
  end

  @spec work_request_board_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_board_details(repo, work_request_ids, opts)
      when is_atom(repo) and is_list(work_request_ids) and is_list(opts) do
    safe_read(fn -> WorkRequestDetails.board_details(repo, work_request_ids, opts) end)
  end

  @spec work_request_details(repo(), [String.t()]) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_details(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    work_request_details(repo, work_request_ids, [])
  end

  @spec work_request_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_details(repo, work_request_ids, opts)
      when is_atom(repo) and is_list(work_request_ids) and is_list(opts) do
    safe_read(fn -> WorkRequestDetails.details(repo, work_request_ids, opts) end)
  end

  @doc false
  @spec work_requests_in_input_order([String.t()], map()) :: {:ok, [WorkRequest.t()]} | {:error, dashboard_error()}
  def work_requests_in_input_order(work_request_ids, work_requests_by_id) do
    work_request_ids
    |> Enum.reduce_while({:ok, []}, fn work_request_id, {:ok, work_requests} ->
      case Map.fetch(work_requests_by_id, work_request_id) do
        {:ok, %WorkRequest{} = work_request} -> {:cont, {:ok, [work_request | work_requests]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, work_requests} -> {:ok, Enum.reverse(work_requests)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec all_work_packages([WorkRequest.t()], map()) :: [WorkPackage.t()]
  def all_work_packages(work_requests, work_packages_by_request) do
    Enum.flat_map(work_requests, &Map.get(work_packages_by_request, &1.id, []))
  end

  @spec detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    detail(repo, work_package_id, [])
  end

  @spec detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id, opts) when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id) do
        repo_identity_catalog = repo_identity_catalog_from_opts(opts, [state.work_package.repo])
        blockers = OperationalProjection.blockers(state.progress_events)
        summary = summary(state, agent_runs, blockers)

        {:ok,
         %{
           work_package: work_package_detail(state.work_package, repo_identity_catalog),
           lineage: OperationalProjection.package_lineage(repo, work_package_id),
           summary: summary,
           plan: Enum.map(state.plan_nodes, &plan_node/1),
           findings: Enum.map(state.findings, &finding/1),
           progress: Enum.map(state.progress_events, &progress_event/1),
           artifacts: Enum.map(state.artifacts, &artifact/1),
           blockers: blockers,
           agent_runs: Enum.map(agent_runs, &agent_run/1),
           metadata: MetadataProjection.metadata(state.progress_events),
           alert_indicators: OperationalProjection.alert_indicators(repo, state, summary.runtime)
         }}
      end
    end)
  end

  @spec card(repo(), WorkPackage.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def card(repo, %WorkPackage{} = work_package) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, context} <- card_context(repo, work_package) do
        {:ok, context.card}
      end
    end)
  end

  defp card_context(repo, %WorkPackage{} = work_package) do
    with {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, [], [work_package.repo]) do
      card_context(repo, work_package, OperationalProjection.package_lineage(repo, work_package.id), repo_identity_catalog)
    end
  end

  defp card_context(repo, %WorkPackage{} = work_package, lineage, repo_identity_catalog) do
    with {:ok, status_summary} <- PlanningRepository.get_status_summary(repo, work_package.id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, readiness_collections} <- readiness_collections(repo, work_package),
         {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package.id) do
      %{artifacts: artifacts, findings: findings} = readiness_collections
      activity_context = WorkPackageActivity.project_context(agent_runs, progress_events, work_package)

      {:ok,
       build_card_context(repo, work_package, repo_identity_catalog, %{
         plan_nodes: status_summary.plan_nodes,
         progress_events: progress_events,
         artifacts: artifacts,
         artifact_count: status_summary.artifact_count,
         findings: findings,
         finding_count: status_summary.finding_count,
         agent_runs: agent_runs,
         lineage: lineage,
         worker_signal: activity_context.worker_signal
       })}
    end
  end

  defp build_card_context(repo, work_package, repo_identity_catalog, context) do
    plan_nodes = context.plan_nodes
    progress_events = context.progress_events
    artifacts = context.artifacts
    findings = context.findings
    agent_runs = context.agent_runs
    lineage = context.lineage
    blockers = OperationalProjection.blockers(progress_events)
    runtime = OperationalProjection.runtime_summary(agent_runs)
    metadata = MetadataProjection.metadata(progress_events)

    readiness_context =
      OperationalProjection.readiness_context(repo, work_package, plan_nodes, progress_events, artifacts, findings)

    operational_state =
      OperationalProjection.work_package_operational_state(work_package, %{
        agent_runs: agent_runs,
        progress_events: progress_events,
        blockers: blockers,
        runtime: runtime,
        metadata: metadata,
        readiness_context: readiness_context,
        lineage: lineage,
        worker_signal: context.worker_signal
      })

    %{
      work_package: work_package,
      blockers: blockers,
      card:
        %{
          id: work_package.id,
          title: redacted_text(work_package.title),
          kind: work_package.kind,
          status: work_package.status,
          merge_required: merge_required?(work_package),
          pr_required: pr_required?(work_package),
          repo: work_package.repo,
          base_branch: work_package.base_branch,
          parent_id: work_package.parent_id,
          phase_id: work_package.phase_id,
          owner_id: work_package.owner_id,
          active_agent_run: OperationalProjection.latest_active_agent_run(agent_runs),
          runtime: runtime,
          latest_progress_at: latest_progress_at(progress_events),
          active_blocker_count: Enum.count(blockers, & &1.active),
          active_blockers: active_blockers(blockers),
          artifact_count: context.artifact_count,
          finding_count: context.finding_count,
          plan: OperationalProjection.plan_summary(plan_nodes),
          metadata: metadata,
          lineage: lineage,
          operational_state: operational_state,
          alert_indicators: OperationalProjection.alert_indicators(readiness_context, blockers, runtime),
          inserted_at: timestamp(work_package.inserted_at),
          updated_at: timestamp(work_package.updated_at)
        }
        |> put_repo_identity_fields(repo_identity_catalog, work_package.repo)
    }
  end

  defp readiness_collections(repo, %WorkPackage{} = work_package) do
    with {:ok, artifacts} <- readiness_artifacts(repo, work_package),
         {:ok, findings} <- readiness_findings(repo, work_package) do
      {:ok, %{artifacts: artifacts, findings: findings}}
    end
  end

  defp readiness_artifacts(repo, %WorkPackage{status: status} = work_package) when status in @ready_statuses do
    PlanningRepository.list_artifacts(repo, work_package.id)
  end

  defp readiness_artifacts(repo, %WorkPackage{} = work_package) do
    if artifact_backed_readiness_gate_required?(work_package) do
      PlanningRepository.list_artifacts(repo, work_package.id)
    else
      {:ok, []}
    end
  end

  defp artifact_backed_readiness_gate_required?(%WorkPackage{} = work_package) do
    merge_required?(work_package)
  end

  defp readiness_findings(repo, %WorkPackage{status: status, id: work_package_id}) when status in @ready_statuses do
    PlanningRepository.list_findings(repo, work_package_id)
  end

  defp readiness_findings(_repo, %WorkPackage{}), do: {:ok, []}

  @spec work_package_detail(WorkPackage.t()) :: map()
  def work_package_detail(%WorkPackage{} = work_package) do
    work_package_detail(work_package, build_repo_identity_catalog([work_package.repo]))
  end

  @spec work_package_detail(WorkPackage.t(), RepoIdentity.catalog()) :: map()
  def work_package_detail(%WorkPackage{} = work_package, repo_identity_catalog) when is_map(repo_identity_catalog) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: redacted_text(work_package.title),
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: redacted_text(work_package.product_description),
      engineering_scope: redacted_text(work_package.engineering_scope),
      allowed_file_globs: work_package.allowed_file_globs || [],
      policy_template: redacted_text(work_package.policy_template),
      acceptance_criteria: Enum.map(work_package.acceptance_criteria || [], &redacted_text/1),
      status: work_package.status,
      parent_id: work_package.parent_id,
      phase_id: work_package.phase_id,
      owner_id: work_package.owner_id,
      inserted_at: timestamp(work_package.inserted_at),
      updated_at: timestamp(work_package.updated_at)
    }
    |> put_repo_identity_fields(repo_identity_catalog, work_package.repo)
  end

  @doc false
  @spec collect_or_error([{:ok, term()} | {:error, term()}]) :: {:ok, [term()]} | {:error, term()}
  def collect_or_error(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, items} -> {:cont, {:ok, [item | items]}}
      {:error, reason}, {:ok, _items} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_board(repo, opts) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo),
         source_work_packages = board_source_work_packages(work_packages, opts),
         visible_work_packages = board_work_packages(repo, source_work_packages, opts),
         {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(visible_work_packages, & &1.repo)),
         {:ok, contexts} <- card_contexts_for_packages(repo, visible_work_packages, repo_identity_catalog) do
      cards = Enum.map(contexts, & &1.card)
      groups = group_cards(cards)

      board = %{
        groups: groups,
        package_limits: package_limits(source_work_packages, visible_work_packages, opts),
        visible_count: length(cards),
        statuses: group_statuses(groups),
        total_count: length(source_work_packages)
      }

      maybe_put_active_blocking_edges(repo, board, contexts, opts)
    end
  end

  defp board_source_work_packages(work_packages, opts) do
    hidden_ids = hidden_work_package_ids(opts)
    Enum.reject(work_packages, &MapSet.member?(hidden_ids, &1.id))
  end

  defp hidden_work_package_ids(opts) do
    case Keyword.get(opts, :hidden_work_package_ids, MapSet.new()) do
      %MapSet{} = ids -> ids
      ids when is_list(ids) -> MapSet.new(ids)
      _ids -> MapSet.new()
    end
  end

  defp board_work_packages(repo, work_packages, opts) do
    case finished_work_package_limit(opts) do
      :all ->
        work_packages

      limit ->
        {finished, active} = Enum.split_with(work_packages, &finished_work_package?/1)
        active ++ visible_finished_work_packages(repo, finished, limit)
    end
  end

  defp package_limits(work_packages, visible_work_packages, opts) do
    finished_total_count = Enum.count(work_packages, &finished_work_package?/1)
    finished_visible_count = Enum.count(visible_work_packages, &finished_work_package?/1)
    limit = finished_work_package_limit(opts)

    %{
      finished_work_packages: %{
        limit: if(limit == :all, do: nil, else: limit),
        shown_count: finished_visible_count,
        total_count: finished_total_count,
        truncated: finished_visible_count < finished_total_count
      }
    }
  end

  defp finished_work_package_limit(opts) do
    case Keyword.get(opts, :finished_work_package_limit, :all) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _limit -> :all
    end
  end

  defp finished_work_package?(%WorkPackage{} = work_package), do: Lifecycle.ended?(work_package)

  defp visible_finished_work_packages(_repo, _finished, 0), do: []
  defp visible_finished_work_packages(_repo, [], _limit), do: []

  defp visible_finished_work_packages(repo, finished, limit) do
    candidate_limit = finished_work_package_candidate_limit(limit)
    latest_progress_by_id = recent_finished_progress_by_work_package_id(repo, finished, candidate_limit)
    candidates_by_id = Map.new(finished, &{&1.id, &1})

    package_candidate_ids =
      finished
      |> sort_finished_work_packages(%{})
      |> Enum.take(candidate_limit)
      |> Enum.map(& &1.id)

    (package_candidate_ids ++ Map.keys(latest_progress_by_id))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Map.fetch(candidates_by_id, id) do
        {:ok, work_package} -> [work_package]
        :error -> []
      end
    end)
    |> sort_finished_work_packages(latest_progress_by_id)
    |> Enum.take(limit)
  end

  defp finished_work_package_candidate_limit(limit), do: max(limit * @finished_work_package_candidate_multiplier, @finished_work_package_min_candidate_limit)

  defp recent_finished_progress_by_work_package_id(repo, finished, limit) do
    finished
    |> Enum.map(& &1.id)
    |> Enum.chunk_every(@finished_progress_lookup_chunk_size)
    |> Enum.flat_map(&recent_finished_progress_rows(repo, &1, limit))
    |> Enum.sort_by(fn {_work_package_id, created_at} -> timestamp_sort_value(created_at) end, :desc)
    |> Enum.take(limit)
    |> Map.new()
  end

  defp recent_finished_progress_rows(repo, work_package_ids, limit) do
    from(progress_event in ProgressEvent,
      where: progress_event.work_package_id in ^work_package_ids,
      group_by: progress_event.work_package_id,
      order_by: [desc: max(progress_event.created_at)],
      limit: ^limit,
      select: {progress_event.work_package_id, max(progress_event.created_at)}
    )
    |> repo.all()
  end

  defp sort_finished_work_packages(work_packages, latest_progress_by_id) do
    Enum.sort_by(work_packages, &recent_work_package_sort_key(&1, latest_progress_by_id), :desc)
  end

  defp recent_work_package_sort_key(%WorkPackage{} = work_package, latest_progress_by_id) do
    {
      timestamp_sort_value(recent_work_package_at(work_package, latest_progress_by_id)),
      timestamp_sort_value(work_package.updated_at),
      timestamp_sort_value(work_package.inserted_at),
      work_package.id || ""
    }
  end

  defp recent_work_package_at(%WorkPackage{} = work_package, latest_progress_by_id) do
    [Map.get(latest_progress_by_id, work_package.id), work_package.updated_at, work_package.inserted_at]
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp maybe_put_active_blocking_edges(repo, board, contexts, opts) do
    if Keyword.get(opts, :active_blocking_edges?, false) do
      put_active_blocking_edges(repo, board, contexts)
    else
      {:ok, board}
    end
  end

  defp put_active_blocking_edges(repo, board, contexts) do
    with {:ok, active_blocking_edges} <- active_blocking_edges_from_card_contexts(repo, contexts) do
      {:ok, Map.put(board, :active_blocking_edges, active_blocking_edges)}
    end
  end

  defp build_phase_board(repo, phase_id, filters) do
    with {:ok, phase} <- PhaseRepository.get(repo, phase_id),
         {:ok, work_packages} <- WorkPackageRepository.list_for_phase(repo, phase_id),
         summary_work_packages = filter_phase_work_packages(work_packages, phase_scope_filters(filters)),
         scoped_work_packages = filter_phase_work_packages(work_packages, filters),
         repo_identity_catalog = build_repo_identity_catalog(Enum.map(summary_work_packages, & &1.repo)),
         {:ok, cards} <- cards_for_packages(repo, scoped_work_packages, repo_identity_catalog) do
      groups = group_cards(cards)

      {:ok,
       %{
         phase: phase(phase),
         groups: groups,
         statuses: group_statuses(groups),
         total_count: length(cards)
       }}
    end
  end

  defp filter_phase_work_packages(work_packages, filters) do
    Enum.filter(work_packages, &phase_work_package_matches_filters?(&1, filters))
  end

  defp phase_scope_filters(filters) do
    Enum.filter(filters, fn
      {:repo, repo} when is_binary(repo) -> true
      {:base_branch, base_branch} when is_binary(base_branch) -> true
      _filter -> false
    end)
  end

  @doc false
  @spec phase_work_package_matches_filters?(WorkPackage.t(), keyword()) :: boolean()
  def phase_work_package_matches_filters?(%WorkPackage{} = work_package, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) ->
        repo_scope_match?(work_package.repo, repo)

      {:base_branch, base_branch} when is_binary(base_branch) ->
        BaseBranch.equivalent?(work_package.base_branch, base_branch)

      _filter ->
        true
    end)
  end

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: configured_trusted_repo_remotes(),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp cards_for_packages(repo, work_packages, repo_identity_catalog) do
    with {:ok, contexts} <- card_contexts_for_packages(repo, work_packages, repo_identity_catalog) do
      {:ok, Enum.map(contexts, & &1.card)}
    end
  end

  defp card_contexts_for_packages(repo, work_packages, repo_identity_catalog) do
    card_contexts_for_packages(repo, work_packages, repo_identity_catalog, [])
  end

  defp card_contexts_for_packages(repo, work_packages, repo_identity_catalog, opts) do
    with {:ok, work_package_contexts} <- work_package_contexts_for_packages(repo, work_packages, opts) do
      {:ok,
       Enum.map(work_packages, fn work_package ->
         context = work_package_contexts |> Map.fetch!(work_package.id) |> card_context_projection(work_package)
         build_card_context(repo, work_package, repo_identity_catalog, context)
       end)}
    end
  end

  defp work_package_contexts_for_packages(repo, work_packages, opts) do
    case Keyword.fetch(opts, :work_package_contexts) do
      :error ->
        work_package_work_package_contexts(repo, work_packages)

      {:ok, preloaded_contexts} when is_map(preloaded_contexts) ->
        work_package_ids = work_packages |> Enum.map(& &1.id) |> MapSet.new()
        selected_contexts = Map.take(preloaded_contexts, MapSet.to_list(work_package_ids))
        missing_work_packages = Enum.reject(work_packages, &Map.has_key?(selected_contexts, &1.id))

        with {:ok, missing_contexts} <- work_package_work_package_contexts(repo, missing_work_packages) do
          {:ok, Map.merge(selected_contexts, missing_contexts)}
        end

      {:ok, _other} ->
        {:error, :not_found}
    end
  end

  defp card_context_projection(context, %WorkPackage{} = work_package) do
    artifacts = context.artifacts
    findings = context.findings

    context
    |> Map.put(:artifact_count, length(artifacts))
    |> Map.put(:finding_count, length(findings))
    |> Map.put(:artifacts, if(work_package.status in @ready_statuses or artifact_backed_readiness_gate_required?(work_package), do: artifacts, else: []))
    |> Map.put(:findings, if(work_package.status in @ready_statuses, do: findings, else: []))
  end

  defp active_blocking_edges_from_card_contexts(_repo, []), do: {:ok, []}

  defp active_blocking_edges_from_card_contexts(repo, contexts) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo) do
      active_blocking_edges_from_card_contexts(repo, contexts, work_packages)
    end
  end

  defp active_blocking_edges_from_card_contexts(_repo, [], _all_work_packages), do: {:ok, []}

  defp active_blocking_edges_from_card_contexts(repo, contexts, all_work_packages) do
    context_edges =
      contexts
      |> Enum.flat_map(fn %{work_package: work_package, blockers: blockers} ->
        blockers
        |> Enum.filter(& &1.active)
        |> Enum.map(&active_blocking_edge(&1, work_package))
      end)

    with {:ok, targeted_edges} <- targeted_active_blocking_edges(repo, contexts, all_work_packages) do
      edges =
        (context_edges ++ targeted_edges)
        |> Enum.uniq_by(& &1.id)
        |> sort_active_blocking_edges()

      {:ok, edges}
    end
  end

  defp targeted_active_blocking_edges(repo, contexts, all_work_packages) do
    target_ids = Enum.map(contexts, & &1.work_package.id)

    with {:ok, events} <-
           PlanningRepository.list_progress_events_for_blockers_targeting_work_packages(
             repo,
             target_ids
           ) do
      targeted_active_blocking_edges(repo, events, MapSet.new(target_ids), all_work_packages)
    end
  end

  defp targeted_active_blocking_edges(_repo, [], _target_ids, _all_work_packages), do: {:ok, []}

  defp targeted_active_blocking_edges(_repo, events, target_ids, all_work_packages) do
    work_packages_by_id = Map.new(all_work_packages, &{&1.id, &1})

    edges =
      events
      |> Enum.group_by(& &1.work_package_id)
      |> Enum.flat_map(&targeted_edges_for_owner(&1, work_packages_by_id, target_ids))

    {:ok, edges}
  end

  defp targeted_edges_for_owner({owner_id, events}, work_packages_by_id, target_ids) do
    case Map.get(work_packages_by_id, owner_id) do
      %WorkPackage{} = owner ->
        events
        |> BlockerProjection.blockers()
        |> Enum.filter(&targeted_active_blocker?(&1, target_ids))
        |> Enum.map(&active_blocking_edge(&1, owner))

      nil ->
        []
    end
  end

  defp targeted_active_blocker?(%{active: true, blocked_item: %{kind: "work_package", id: target_id}}, target_ids),
    do: MapSet.member?(target_ids, target_id)

  defp targeted_active_blocker?(_blocker, _target_ids), do: false

  defp active_blocking_edge(blocker, %WorkPackage{} = work_package) do
    fallback_from = %{kind: "work_package", id: work_package.id}
    from = blocker.blocked_by || fallback_from
    to = blocker.blocked_item || %{kind: "work_package", id: work_package.id}

    blocker
    |> build_active_blocking_edge(work_package, from, to)
    |> Map.put(:work_request_id, work_package.work_request_id)
    |> Map.put(:work_package_id, work_package.id)
  end

  defp build_active_blocking_edge(blocker, %WorkPackage{} = work_package, from, to) do
    %{
      id: active_blocking_edge_id(blocker.id, from, to),
      blocker_id: blocker.id,
      from: from,
      to: to,
      summary: blocker.summary,
      body: blocker.body,
      updated_at: blocker.updated_at,
      work_package_id: work_package.id
    }
  end

  defp active_blocking_edge_id(blocker_id, from, to) do
    material = [blocker_id, from.kind, from.id, to.kind, to.id]

    "active_blocking_edge_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join(material, ":")), padding: false)
  end

  defp sort_active_blocking_edges(edges) do
    Enum.sort_by(edges, fn edge ->
      from = Map.fetch!(edge, :from)
      to = Map.fetch!(edge, :to)

      {
        edge.updated_at || "",
        edge.id || "",
        from.kind || "",
        from.id || "",
        to.kind || "",
        to.id || ""
      }
    end)
  end

  defp work_request_cards(repo, work_requests, opts), do: WorkRequestCards.cards(repo, work_requests, opts)
  defp visible_work_request_cards(cards), do: WorkRequestCards.visible_cards(cards)
  defp ordered_work_requests(work_requests), do: WorkRequestCards.ordered_work_requests(work_requests)

  @doc false
  @spec ordered_sequence_records([struct()]) :: [struct()]
  def ordered_sequence_records(records) do
    Enum.sort_by(records, fn record ->
      {Map.get(record, :sequence) || 0, Map.get(record, :id) || ""}
    end)
  end

  defp planning_state(repo, work_package_id) do
    case PlanningRepository.get_state(repo, work_package_id) do
      {:ok, %State{} = state} ->
        {:ok, state}

      {:error, :not_found} ->
        with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
          {:ok, %State{work_package: work_package}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_identity_repo_values(repo) do
    Enum.flat_map([WorkPackage, WorkRequest, SoloSession], &repo_values(repo, &1))
  end

  defp repo_values(repo, schema) do
    repo.all(
      from(record in schema,
        where: not is_nil(record.repo) and record.repo != "",
        distinct: true,
        select: record.repo
      )
    )
  end

  defp repo_identity_catalog_from_repo(repo, opts, repo_values) do
    case Keyword.fetch(opts, :repo_identity_catalog) do
      {:ok, repo_identity_catalog} ->
        {:ok, repo_identity_catalog}

      :error ->
        {:ok, build_repo_identity_catalog(repo_identity_repo_values(repo) ++ repo_values)}
    end
  end

  @doc false
  @spec repo_identity_catalog_from_opts(keyword(), [String.t() | nil]) :: map()
  def repo_identity_catalog_from_opts(opts, repo_values) do
    Keyword.get_lazy(opts, :repo_identity_catalog, fn -> build_repo_identity_catalog(repo_values) end)
  end

  defp build_repo_identity_catalog(repo_values) do
    build_repo_identity_catalog(repo_values, configured_trusted_repo_remotes())
  end

  defp build_repo_identity_catalog(repo_values, trusted_remotes, opts \\ []) when is_list(trusted_remotes) do
    repo_identity_opts =
      opts
      |> Keyword.put(:trusted_remotes, Enum.uniq(trusted_remotes))

    RepoIdentity.catalog(repo_values, repo_identity_opts)
  end

  defp configured_trusted_repo_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
  end

  defp local_operator_trusted_repo_remotes do
    (configured_trusted_repo_remotes() ++ local_operator_origin_remotes())
    |> Enum.uniq()
  end

  defp local_operator_origin_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_root)
    |> RepoIdentity.local_git_origin_remote()
    |> List.wrap()
  end

  defp safe_read(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
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

  defp group_cards(cards) do
    by_status = Enum.group_by(cards, & &1.status)
    statuses = Enum.uniq(Lifecycle.statuses() ++ Map.keys(by_status))

    Map.new(statuses, fn status ->
      {status, Map.get(by_status, status, [])}
    end)
  end

  defp group_statuses(groups) when is_map(groups), do: Enum.uniq(Lifecycle.statuses() ++ Map.keys(groups))

  defp summary(%State{} = state, agent_runs, blockers) do
    runtime = OperationalProjection.runtime_summary(agent_runs)

    %{
      artifact_count: length(state.artifacts),
      finding_count: length(state.findings),
      progress_event_count: length(state.progress_events),
      active_blocker_count: Enum.count(blockers, & &1.active),
      agent_run_count: length(agent_runs),
      active_agent_run_count: Enum.count(agent_runs, &(&1.status in AgentRun.active_statuses())),
      queued_agent_run_count: runtime.queued_count,
      stopped_agent_run_count: runtime.stopped_count,
      failed_agent_run_count: runtime.failed_count,
      stale_agent_run_count: runtime.stale_count,
      runtime: runtime,
      latest_progress_at: latest_progress_at(state.progress_events),
      plan: OperationalProjection.plan_summary(state.plan_nodes)
    }
  end

  @doc false
  @spec visible_work_packages([WorkPackage.t()], map() | nil) :: [WorkPackage.t()]
  def visible_work_packages(work_packages, delivery_board), do: WorkRequestCards.visible_work_packages(work_packages, delivery_board)

  @doc false
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
        questions,
        work_packages,
        work_package_contexts,
        repo_identity_catalog,
        opts
      ) do
    WorkRequestCards.work_request_payload(
      work_request,
      questions,
      work_packages,
      work_package_contexts,
      repo_identity_catalog,
      opts
    )
  end

  @doc false
  @spec clarification_question(ClarificationQuestion.t()) :: map()
  def clarification_question(%ClarificationQuestion{} = question) do
    %{
      id: question.id,
      work_request_id: question.work_request_id,
      sequence: question.sequence,
      category: redacted_text(question.category),
      question: redacted_text(question.question),
      why_needed: redacted_text(question.why_needed),
      decision_prompt: redacted_json(question.decision_prompt),
      status: question.status,
      asked_by_agent_run_id: question.asked_by_agent_run_id,
      answer: redacted_text(question.answer),
      answered_by: redacted_text(question.answered_by),
      answered_at: timestamp(question.answered_at),
      inserted_at: timestamp(question.inserted_at),
      updated_at: timestamp(question.updated_at)
    }
  end

  @doc false
  @spec decision_log_entry(DecisionLogEntry.t()) :: map()
  def decision_log_entry(%DecisionLogEntry{} = decision) do
    %{
      id: decision.id,
      work_request_id: decision.work_request_id,
      sequence: decision.sequence,
      source_type: decision.source_type,
      source_id: redacted_text(decision.source_id),
      decision: redacted_text(decision.decision),
      rationale: redacted_text(decision.rationale),
      scope_impact: redacted_text(decision.scope_impact),
      created_by: redacted_text(decision.created_by),
      created_at: timestamp(decision.created_at),
      inserted_at: timestamp(decision.inserted_at),
      updated_at: timestamp(decision.updated_at)
    }
  end

  @doc false
  @spec work_package_payloads([WorkPackage.t()], map(), boolean(), keyword()) :: [map()]
  def work_package_payloads(work_packages, work_package_contexts, include_dispatch_details?, opts) do
    delivery_work_packages_by_id = opts |> Keyword.get(:delivery_board) |> DeliveryWorkPackageProjection.work_packages_by_id()

    Enum.map(work_packages, fn slice ->
      work_package(slice, work_package_contexts,
        include_dispatch_details?: include_dispatch_details?,
        delivery_work_package: Map.get(delivery_work_packages_by_id, slice.id),
        compact?: Keyword.get(opts, :compact?, false)
      )
    end)
  end

  defp work_package(%WorkPackage{} = work_package, work_package_statuses, opts) do
    %{
      id: work_package.id,
      work_request_id: work_package.work_request_id,
      product_tree_node_id: work_package.product_tree_node_id,
      sequence: work_package.sequence,
      title: redacted_text(work_package.title),
      goal: redacted_text(work_package.goal),
      kind: work_package.kind,
      repo: redacted_text(work_package.repo),
      base_branch: work_package.base_branch,
      branch_pattern: redacted_text(work_package.branch_pattern),
      review: redacted_json(work_package.review_requirement),
      status: work_package.status,
      inserted_at: timestamp(work_package.inserted_at),
      updated_at: timestamp(work_package.updated_at)
    }
    |> put_package_detail_fields(work_package, opts)
    |> put_attribution(:dispatched_by, work_package.dispatched_by)
    |> maybe_put_dispatch_details(work_package, work_package_statuses, opts)
  end

  defp put_package_detail_fields(payload, work_package, opts) do
    if Keyword.get(opts, :compact?, false) do
      payload
    else
      Enum.reduce([:allowed_file_globs, :forbidden_file_globs, :acceptance_criteria, :validation_steps, :stop_conditions], payload, fn key, acc ->
        Map.put(acc, key, Enum.map(Map.get(work_package, key) || [], &redacted_text/1))
      end)
    end
  end

  @doc false
  @spec compact_work_package(map()) :: map()
  def compact_work_package(payload) when is_map(payload) do
    payload
    |> drop_keys([
      :acceptance_criteria,
      :forbidden_file_globs,
      :allowed_file_globs,
      :stop_conditions,
      :validation_steps
    ])
    |> compact_work_package_delivery()
  end

  defp compact_work_package_delivery(%{delivery: delivery} = payload) when is_map(delivery) do
    Map.put(payload, :delivery, compact_delivery_evidence(delivery))
  end

  defp compact_work_package_delivery(payload), do: payload

  @doc false
  @spec compact_delivery_evidence(term()) :: term()
  def compact_delivery_evidence(value) when is_map(value) do
    value
    |> drop_keys([:abandoned_rationale, :no_pr_evidence, :superseded_reason])
    |> Map.new(fn {key, nested} -> {key, compact_delivery_evidence(nested)} end)
  end

  def compact_delivery_evidence(values) when is_list(values), do: Enum.map(values, &compact_delivery_evidence/1)
  def compact_delivery_evidence(value), do: value

  defp drop_keys(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(to_string(key))
    end)
  end

  defp maybe_put_dispatch_details(payload, %WorkPackage{} = work_package, work_package_contexts, opts) do
    delivery_work_package = Keyword.get(opts, :delivery_work_package)
    include_dispatch_details? = Keyword.get(opts, :include_dispatch_details?, false)
    delivery_opts = [include_delivery_data?: include_dispatch_details?]

    payload = DeliveryWorkPackageProjection.put_delivery_work_package(payload, delivery_work_package, delivery_opts)

    if include_dispatch_details? do
      work_package_context = Map.get(work_package_contexts, work_package.id)

      payload
      |> Map.put(:work_package_id, work_package.id)
      |> Map.put(:work_package_status, context_work_package_status(work_package_context))
      |> Map.put(:dispatched_at, timestamp(work_package.dispatched_at))
      |> Map.put(:operational_state, OperationalProjection.work_package_operational_state(work_package, work_package_context, delivery_work_package))
    else
      DeliveryWorkPackageProjection.put_delivery_operational_state(payload, delivery_work_package)
    end
  end

  @doc false
  @spec work_package_work_package_contexts(repo(), [WorkPackage.t()]) :: {:ok, map()}
  def work_package_work_package_contexts(repo, work_packages) do
    work_packages = Enum.filter(work_packages, &filled_string?(&1.id))

    if work_packages == [] do
      {:ok, %{}}
    else
      {:ok, work_package_contexts(repo, work_packages)}
    end
  end

  @doc false
  @spec work_package_contexts(repo(), [WorkPackage.t()]) :: map()
  def work_package_contexts(_repo, []), do: %{}

  def work_package_contexts(repo, work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)
    progress_events_by_id = grouped_progress_events(repo, work_package_ids)
    plan_nodes_by_id = grouped_plan_nodes(repo, work_package_ids)
    artifacts_by_id = grouped_artifacts(repo, work_package_ids)
    findings_by_id = grouped_findings(repo, work_package_ids)
    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)
    lineages_by_id = OperationalProjection.package_lineages(repo, work_packages)

    delivery_successors_by_id =
      case OperationalLineage.delivery_successors(repo, work_packages) do
        {:ok, successors} -> successors
        {:error, _reason} -> Map.new(work_package_ids, &{&1, ["lineage_unavailable"]})
      end

    Map.new(work_packages, fn %WorkPackage{} = work_package ->
      progress_events = Map.get(progress_events_by_id, work_package.id, [])
      plan_nodes = Map.get(plan_nodes_by_id, work_package.id, [])
      artifacts = Map.get(artifacts_by_id, work_package.id, [])
      findings = Map.get(findings_by_id, work_package.id, [])
      agent_runs = Map.get(agent_runs_by_id, work_package.id, [])
      activity_context = WorkPackageActivity.project_context(agent_runs, progress_events, work_package)

      blockers = OperationalProjection.blockers(progress_events)
      runtime = OperationalProjection.runtime_summary(agent_runs)
      metadata = MetadataProjection.metadata(progress_events)

      readiness_context =
        OperationalProjection.readiness_context(
          repo,
          work_package,
          plan_nodes,
          progress_events,
          artifacts,
          findings
        )

      lineage = Map.get(lineages_by_id, work_package.id, OperationalProjection.empty_lineage(work_package.id))

      operational_state =
        OperationalProjection.work_package_operational_state(work_package, %{
          agent_runs: agent_runs,
          progress_events: progress_events,
          blockers: blockers,
          runtime: runtime,
          metadata: metadata,
          readiness_context: readiness_context,
          lineage: lineage,
          worker_signal: activity_context.worker_signal
        })

      {work_package.id,
       %{
         work_package: work_package,
         plan_nodes: plan_nodes,
         progress_events: progress_events,
         artifacts: artifacts,
         findings: findings,
         agent_runs: agent_runs,
         lineage: lineage,
         delivery_successor_ids: Map.get(delivery_successors_by_id, work_package.id, []),
         blocker_state: activity_context.blocker_state,
         runtime_state: activity_context.runtime_state,
         current_worker_session: activity_context.current_worker_session,
         worker_signal: activity_context.worker_signal,
         card: %{operational_state: operational_state, metadata: metadata}
       }}
    end)
  end

  defp grouped_progress_events(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id in ^work_package_id_chunk,
          order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.inserted_at]
        )
      )
    end)
  end

  defp grouped_plan_nodes(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id in ^work_package_id_chunk,
          order_by: [asc: plan_node.work_package_id, asc: plan_node.position, asc: plan_node.inserted_at]
        )
      )
    end)
  end

  defp grouped_artifacts(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(artifact in Artifact,
          where: artifact.work_package_id in ^work_package_id_chunk,
          order_by: [asc: artifact.work_package_id, asc: artifact.sequence, asc: artifact.inserted_at]
        )
      )
    end)
  end

  defp grouped_findings(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(finding in Finding,
          where: finding.work_package_id in ^work_package_id_chunk,
          order_by: [asc: finding.work_package_id, asc: finding.sequence, asc: finding.inserted_at]
        )
      )
    end)
  end

  defp grouped_agent_runs(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id in ^work_package_id_chunk,
          order_by: [asc: agent_run.work_package_id, asc: agent_run.started_at, asc: agent_run.inserted_at]
        )
      )
    end)
  end

  defp chunked_records_by_work_package_id(work_package_ids, list_fun) do
    work_package_ids
    |> work_package_context_chunks()
    |> Enum.flat_map(list_fun)
    |> records_by_work_package_id()
  end

  defp work_package_context_chunks(work_package_ids) do
    work_package_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@work_package_context_chunk_size)
  end

  defp records_by_work_package_id(records), do: Enum.group_by(records, & &1.work_package_id)

  @doc false
  @spec work_request_summary([ClarificationQuestion.t()], [DecisionLogEntry.t()], [WorkPackage.t()]) :: map()
  def work_request_summary(questions, decisions, work_packages) do
    %{
      open_question_count: Enum.count(questions, &(&1.status == "open")),
      answered_question_count: Enum.count(questions, &(&1.status == "answered")),
      closed_question_count: Enum.count(questions, &(&1.status == "closed")),
      decision_count: length(decisions),
      work_package_count: length(work_packages),
      planned_work_package_count: Enum.count(work_packages, &(&1.status == "planned")),
      dispatched_work_package_count: Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
      ended_work_package_count: Enum.count(work_packages, &Lifecycle.ended?/1)
    }
  end

  @doc false
  @spec work_request_board_summary([ClarificationQuestion.t()], [WorkPackage.t()]) :: map()
  def work_request_board_summary(questions, work_packages) do
    %{
      open_question_count: Enum.count(questions, &(&1.status == "open")),
      answered_question_count: Enum.count(questions, &(&1.status == "answered")),
      closed_question_count: Enum.count(questions, &(&1.status == "closed")),
      work_package_count: length(work_packages),
      planned_work_package_count: Enum.count(work_packages, &(&1.status == "planned")),
      dispatched_work_package_count: Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
      ended_work_package_count: Enum.count(work_packages, &Lifecycle.ended?/1)
    }
  end

  defp plan_node(plan_node) do
    %{
      id: plan_node.id,
      title: redacted_text(plan_node.title),
      body: redacted_text(plan_node.body),
      status: plan_node.status,
      position: plan_node.position,
      created_at: timestamp(plan_node.created_at),
      updated_at: timestamp(plan_node.updated_at)
    }
  end

  defp finding(%Finding{} = finding) do
    %{
      id: finding.id,
      title: redacted_text(finding.title),
      body: redacted_text(finding.body),
      severity: finding.severity,
      sequence: finding.sequence,
      created_at: timestamp(finding.created_at)
    }
  end

  defp progress_event(%ProgressEvent{} = event) do
    %{
      id: event.id,
      summary: redacted_text(event.summary),
      body: redacted_text(event.body),
      status: event.status,
      sequence: event.sequence,
      actor: actor(event),
      agent_run_id: event.agent_run_id,
      payload: redacted_json(event.payload || %{}),
      created_at: timestamp(event.created_at)
    }
  end

  defp artifact(%Artifact{} = artifact) do
    %{
      id: artifact.id,
      path: redacted_text(artifact.path),
      title: redacted_text(artifact.title),
      kind: artifact.kind,
      uri: redacted_uri(artifact.uri),
      sequence: artifact.sequence,
      created_at: timestamp(artifact.created_at)
    }
  end

  defp phase(%Phase{} = phase) do
    %{
      id: phase.id,
      title: redacted_text(phase.title),
      description: redacted_text(phase.description),
      status: phase.status,
      inserted_at: timestamp(phase.inserted_at),
      updated_at: timestamp(phase.updated_at)
    }
  end

  @spec stale_agent_run?(AgentRun.t()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run), do: OperationalProjection.stale_agent_run?(run)

  @spec stale_agent_run?(AgentRun.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run, %DateTime{} = now, threshold_seconds), do: OperationalProjection.stale_agent_run?(run, now, threshold_seconds)

  defp agent_run(%AgentRun{} = run), do: OperationalProjection.agent_run(run)

  @doc false
  @spec missing_readiness_evidence(map()) :: [String.t()]
  def missing_readiness_evidence(context), do: OperationalProjection.missing_readiness_evidence(context)

  @doc false
  @spec filled_string?(term()) :: boolean()
  def filled_string?(value), do: MetadataProjection.filled_string?(value)

  defp latest_progress_at(progress_events) do
    progress_events
    |> Enum.max_by(&timestamp_sort_value(&1.created_at), fn -> nil end)
    |> case do
      %ProgressEvent{created_at: created_at} -> timestamp(created_at)
      nil -> nil
    end
  end

  defp active_blockers(blockers), do: Enum.filter(blockers, & &1.active)

  defp merge_required?(%WorkPackage{} = work_package), do: OperationalProjection.merge_required?(work_package)
  defp pr_required?(%WorkPackage{} = work_package), do: OperationalProjection.pr_required?(work_package)

  defp context_work_package_status(%{work_package: %WorkPackage{status: status}}), do: status
  defp context_work_package_status(_work_package_context), do: nil

  defp actor(event), do: BlockerProjection.actor(event)
  @doc "Adds a chief attribution (`dispatched_by`) to a payload when one was recorded."
  @spec put_attribution(map(), atom() | String.t(), map() | nil) :: map()
  def put_attribution(payload, _key, nil), do: payload
  def put_attribution(payload, key, attribution), do: Map.put(payload, key, Sanitizer.redacted_json(attribution))

  @doc false
  @spec redacted_json(term()) :: term()
  def redacted_json(value), do: Sanitizer.redacted_json(value)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp redacted_uri(value), do: Sanitizer.redacted_uri(value)
  defp timestamp_sort_value(value), do: Sanitizer.timestamp_sort_value(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
