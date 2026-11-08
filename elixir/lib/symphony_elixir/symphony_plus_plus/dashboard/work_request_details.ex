defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestDetails do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.BulkRepository, as: WorkRequestBulkRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.OperatorReport
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @delivery_signal_keys [
    :dependency_signal,
    :repo_signal,
    :pr_signal,
    :review_signal,
    :worker_signal,
    :activity_signal,
    :board_state
  ]

  @type repo :: module()
  @type dashboard_error :: Dashboard.dashboard_error()

  @spec details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def details(repo, work_request_ids, opts) do
    with {:ok, context} <- work_request_details_context(repo, work_request_ids, opts) do
      build_work_request_details(repo, context, opts)
    end
  end

  @spec board_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def board_details(repo, work_request_ids, opts) do
    with {:ok, context} <- work_request_board_details_context(repo, work_request_ids, opts) do
      build_work_request_board_details(repo, context, opts)
    end
  end

  defp work_request_details_context(repo, work_request_ids, opts) do
    with {:ok, work_requests_by_id} <- WorkRequestBulkRepository.get_many(repo, work_request_ids),
         {:ok, work_requests} <- Dashboard.work_requests_in_input_order(work_request_ids, work_requests_by_id),
         {:ok, operator_reports} <- OperatorReport.load_many(repo, work_requests),
         {:ok, questions_by_request} <- WorkRequestBulkRepository.list_questions_many(repo, work_request_ids),
         {:ok, decisions_by_request} <- WorkRequestBulkRepository.list_decisions_many(repo, work_request_ids),
         {:ok, work_packages_by_request} <- WorkRequestBulkRepository.list_work_packages_many(repo, work_request_ids),
         all_work_packages = Dashboard.all_work_packages(work_requests, work_packages_by_request),
         {:ok, work_package_contexts} <- Dashboard.work_package_work_package_contexts(repo, all_work_packages) do
      {:ok,
       %{
         work_requests: work_requests,
         operator_reports: operator_reports,
         questions_by_request: questions_by_request,
         decisions_by_request: decisions_by_request,
         work_packages_by_request: work_packages_by_request,
         work_package_contexts: work_package_contexts,
         repo_identity_catalog: Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
       }}
    end
  end

  defp build_work_request_details(repo, %{work_requests: work_requests} = context, opts) do
    work_requests
    |> Enum.reduce_while([], fn %WorkRequest{} = work_request, details ->
      case build_work_request_detail(repo, work_request, context, opts) do
        {:ok, detail} -> {:cont, [detail | details]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      details -> {:ok, Enum.reverse(details)}
    end
  end

  defp work_request_board_details_context(repo, work_request_ids, opts) do
    with {:ok, work_requests} <- board_work_requests(repo, work_request_ids, opts),
         {:ok, operator_reports} <- OperatorReport.load_many(repo, work_requests),
         {:ok, questions_by_request} <- WorkRequestBulkRepository.list_questions_many(repo, work_request_ids),
         {:ok, work_packages_by_request} <- board_work_packages_by_request(repo, work_request_ids, work_requests, opts),
         all_work_packages = Dashboard.all_work_packages(work_requests, work_packages_by_request),
         {:ok, work_package_contexts} <- board_work_package_contexts(repo, all_work_packages, opts) do
      {:ok,
       %{
         work_requests: work_requests,
         operator_reports: operator_reports,
         questions_by_request: questions_by_request,
         work_packages_by_request: work_packages_by_request,
         work_package_contexts: work_package_contexts,
         repo_identity_catalog: Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
       }}
    end
  end

  defp board_work_requests(repo, work_request_ids, opts) do
    case Keyword.fetch(opts, :work_requests) do
      {:ok, work_requests} when is_list(work_requests) ->
        work_requests
        |> Map.new(&{&1.id, &1})
        |> then(&Dashboard.work_requests_in_input_order(work_request_ids, &1))

      :error ->
        with {:ok, work_requests_by_id} <- WorkRequestBulkRepository.get_many(repo, work_request_ids) do
          Dashboard.work_requests_in_input_order(work_request_ids, work_requests_by_id)
        end

      {:ok, _other} ->
        {:error, :not_found}
    end
  end

  defp board_work_packages_by_request(repo, work_request_ids, work_requests, opts) do
    case Keyword.fetch(opts, :work_packages_by_request) do
      {:ok, work_packages_by_request} when is_map(work_packages_by_request) ->
        work_packages_by_request = Map.take(work_packages_by_request, work_request_ids)

        if Enum.all?(work_requests, &work_packages_match_work_request?(&1, work_packages_by_request)) do
          {:ok, work_packages_by_request}
        else
          {:error, :not_found}
        end

      :error ->
        WorkRequestBulkRepository.list_work_packages_many(repo, work_request_ids)

      {:ok, _other} ->
        {:error, :not_found}
    end
  end

  defp work_packages_match_work_request?(%WorkRequest{} = work_request, work_packages_by_request) do
    work_packages_by_request
    |> Map.get(work_request.id, [])
    |> Enum.all?(&(&1.work_request_id == work_request.id))
  end

  defp board_work_package_contexts(repo, work_packages, opts) do
    case Keyword.fetch(opts, :work_package_contexts) do
      {:ok, preloaded_contexts} when is_map(preloaded_contexts) ->
        work_package_ids = work_packages |> Enum.map(& &1.id) |> MapSet.new()
        selected_contexts = Map.take(preloaded_contexts, MapSet.to_list(work_package_ids))
        missing_work_packages = Enum.reject(work_packages, &Map.has_key?(selected_contexts, &1.id))

        with {:ok, missing_contexts} <- Dashboard.work_package_work_package_contexts(repo, missing_work_packages) do
          {:ok, Map.merge(selected_contexts, missing_contexts)}
        end

      :error ->
        Dashboard.work_package_work_package_contexts(repo, work_packages)

      {:ok, _other} ->
        {:error, :not_found}
    end
  end

  defp build_work_request_board_details(repo, %{work_requests: work_requests} = context, opts) do
    with {:ok, delivery_boards} <- work_request_board_delivery_boards(repo, context, opts) do
      context = Map.put(context, :delivery_boards, delivery_boards)

      work_requests
      |> Enum.map(fn work_request ->
        build_work_request_board_detail(repo, work_request, context, opts, Map.fetch(delivery_boards, work_request.id))
      end)
      |> Dashboard.collect_or_error()
    end
  end

  defp work_request_board_delivery_boards(_repo, %{work_requests: []}, _opts), do: {:ok, %{}}

  defp work_request_board_delivery_boards(
         repo,
         %{
           work_requests: work_requests,
           work_packages_by_request: work_packages_by_request,
           work_package_contexts: work_package_contexts
         },
         opts
       ) do
    work_requests
    |> Enum.group_by(&{&1.repo, &1.base_branch})
    |> Enum.reduce_while({:ok, %{}}, fn {_scope, scoped_work_requests}, {:ok, acc} ->
      scoped_work_packages = Dashboard.all_work_packages(scoped_work_requests, work_packages_by_request)
      scoped_work_package_contexts = request_work_package_contexts(scoped_work_packages, work_package_contexts)

      with {:ok, delivery_board_contexts} <-
             delivery_board_work_package_contexts(repo, scoped_work_requests, scoped_work_package_contexts, opts),
           {:ok, delivery_boards} <-
             DeliveryBoard.project_many(
               repo,
               scoped_work_requests,
               work_packages_by_request,
               delivery_board_many_opts(delivery_board_contexts, scoped_work_packages, opts)
             ) do
        {:cont, {:ok, Map.merge(acc, delivery_boards)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_work_request_board_detail(
         repo,
         %WorkRequest{} = work_request,
         %{
           operator_reports: operator_reports,
           questions_by_request: questions_by_request,
           work_packages_by_request: work_packages_by_request,
           work_package_contexts: work_package_contexts,
           repo_identity_catalog: repo_identity_catalog
         },
         opts,
         {:ok, delivery_board}
       ) do
    questions = Map.get(questions_by_request, work_request.id, [])
    work_packages = Map.get(work_packages_by_request, work_request.id, [])
    request_work_package_contexts = request_work_package_contexts(work_packages, work_package_contexts)

    questions = Dashboard.ordered_sequence_records(questions)

    work_packages =
      work_packages
      |> Dashboard.visible_work_packages(delivery_board)
      |> Dashboard.ordered_sequence_records()

    work_request_payload =
      work_request
      |> Dashboard.work_request_payload(
        questions,
        work_packages,
        request_work_package_contexts,
        repo_identity_catalog,
        delivery_board: delivery_board,
        operator_report: Map.get(operator_reports, work_request.id)
      )
      |> Map.drop([:human_description, :constraints, :creator])
      |> Map.update(:operational_state, %{}, &Map.delete(&1, :activity_signal))

    work_package_payloads =
      work_packages
      |> Dashboard.work_package_payloads(
        request_work_package_contexts,
        true,
        delivery_board: delivery_board,
        compact?: true
      )
      |> Enum.map(&Dashboard.compact_work_package/1)
      |> put_delivery_signals(delivery_board)

    {:ok,
     %{
       work_request: work_request_payload,
       clarification_questions: Enum.map(questions, &Dashboard.clarification_question/1),
       work_packages: work_package_payloads,
       product_tree: product_tree_projection(repo, work_request.id, work_package_payloads, opts),
       summary: Dashboard.work_request_board_summary(questions, work_packages)
     }}
  end

  defp build_work_request_board_detail(_repo, %WorkRequest{}, _context, _opts, :error) do
    {:error, :not_found}
  end

  defp put_delivery_signals(work_packages, delivery_board) do
    signals_by_id =
      delivery_board
      |> Map.get(:work_packages, [])
      |> Map.new(fn item ->
        signals =
          item
          |> Map.get(:work_package)
          |> Kernel.||(%{})
          |> Map.take(@delivery_signal_keys)
          |> Map.put(:merge_eligibility, Map.fetch!(item, :merge_eligibility))
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {key, Dashboard.redacted_json(value)} end)

        {Map.fetch!(item, :id), signals}
      end)

    Enum.map(work_packages, fn work_package ->
      work_package
      |> Map.merge(Map.get(signals_by_id, Map.fetch!(work_package, :id), %{}))
      |> Map.update(:operational_state, %{}, &Map.delete(&1, :activity_signal))
    end)
  end

  defp build_work_request_detail(
         repo,
         %WorkRequest{} = work_request,
         %{
           operator_reports: operator_reports,
           questions_by_request: questions_by_request,
           decisions_by_request: decisions_by_request,
           work_packages_by_request: work_packages_by_request,
           work_package_contexts: work_package_contexts,
           repo_identity_catalog: repo_identity_catalog
         },
         opts
       ) do
    questions = Map.get(questions_by_request, work_request.id, [])
    decisions = Map.get(decisions_by_request, work_request.id, [])
    work_packages = Map.get(work_packages_by_request, work_request.id, [])
    request_work_package_contexts = request_work_package_contexts(work_packages, work_package_contexts)

    with {:ok, delivery_board_contexts} <-
           delivery_board_work_package_contexts(repo, work_request, request_work_package_contexts, opts),
         delivery_board_opts = delivery_board_opts(work_request, work_packages, delivery_board_contexts, opts),
         {:ok, delivery_board} <- DeliveryBoard.project(repo, work_request.id, delivery_board_opts) do
      questions = Dashboard.ordered_sequence_records(questions)
      decisions = Dashboard.ordered_sequence_records(decisions)

      work_packages =
        work_packages
        |> Dashboard.visible_work_packages(delivery_board)
        |> Dashboard.ordered_sequence_records()

      work_request_payload =
        Dashboard.work_request_payload(
          work_request,
          questions,
          work_packages,
          request_work_package_contexts,
          repo_identity_catalog,
          delivery_board: delivery_board,
          operator_report: Map.get(operator_reports, work_request.id)
        )
        |> Map.update(:operational_state, %{}, &Map.delete(&1, :activity_signal))

      work_package_payloads =
        Dashboard.work_package_payloads(
          work_packages,
          request_work_package_contexts,
          true,
          delivery_board: delivery_board
        )
        |> put_delivery_signals(delivery_board)

      {:ok,
       %{
         work_request: work_request_payload,
         clarification_questions: Enum.map(questions, &Dashboard.clarification_question/1),
         decision_logs: Enum.map(decisions, &Dashboard.decision_log_entry/1),
         work_packages: work_package_payloads,
         product_tree: product_tree_projection(repo, work_request.id, work_package_payloads, opts),
         delivery_board: Dashboard.redacted_json(delivery_board),
         summary: Dashboard.work_request_summary(questions, decisions, work_packages)
       }}
    end
  end

  defp request_work_package_contexts(work_packages, work_package_contexts) do
    work_package_ids =
      work_packages
      |> Enum.map(& &1.id)
      |> Enum.filter(&Dashboard.filled_string?/1)
      |> MapSet.new()

    Map.filter(work_package_contexts, fn {work_package_id, _context} -> MapSet.member?(work_package_ids, work_package_id) end)
  end

  defp delivery_board_opts(%WorkRequest{} = work_request, work_packages, work_package_contexts, opts) do
    [
      work_request: work_request,
      work_packages: work_packages,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ] ++ preloaded_delivery_board_opts(work_packages, opts)
  end

  defp delivery_board_many_opts(work_package_contexts, work_packages, opts) do
    [
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ] ++ preloaded_delivery_board_opts(work_packages, opts)
  end

  defp preloaded_delivery_board_opts(work_packages, opts) do
    product_tree_opts = Keyword.take(opts, [:product_trees_by_request])

    delivery_opts =
      case Keyword.fetch(opts, :deliveries_by_slice_id) do
        {:ok, deliveries_by_slice_id} when is_map(deliveries_by_slice_id) ->
          work_package_keys = work_packages |> Enum.map(&{&1.work_request_id, &1.id}) |> MapSet.new()
          deliveries_by_slice_id = Map.take(deliveries_by_slice_id, MapSet.to_list(work_package_keys))
          [deliveries_by_slice_id: deliveries_by_slice_id]

        {:ok, _other} ->
          [deliveries_by_slice_id: %{}]

        :error ->
          []
      end

    product_tree_opts ++ delivery_opts
  end

  defp product_tree_projection(repo, work_request_id, work_package_payloads, opts) do
    product_tree_opts =
      case Keyword.fetch(opts, :product_trees_by_request) do
        {:ok, product_trees_by_request} when is_map(product_trees_by_request) ->
          case Map.fetch(product_trees_by_request, work_request_id) do
            {:ok, context} -> [product_tree_context: context]
            :error -> []
          end

        {:ok, _other} ->
          []

        :error ->
          []
      end

    ProductTree.project(repo, work_request_id, work_package_payloads, product_tree_opts)
  end

  defp delivery_board_work_package_contexts(repo, work_requests, work_package_contexts, opts) when is_list(work_requests) do
    loaded_ids = work_package_contexts |> Map.keys() |> MapSet.new()
    successor_ids = delivery_board_successor_work_package_ids(repo, Enum.map(work_requests, & &1.id), opts)
    missing_successor_ids = Enum.reject(successor_ids, &MapSet.member?(loaded_ids, &1))

    successor_contexts =
      repo
      |> work_packages_by_ids(missing_successor_ids)
      |> Enum.filter(&delivery_board_successor_visible?(&1, work_requests))
      |> then(&Dashboard.work_package_contexts(repo, &1))

    {:ok, Map.merge(work_package_contexts, successor_contexts)}
  end

  defp delivery_board_work_package_contexts(repo, %WorkRequest{} = work_request, work_package_contexts, opts) do
    loaded_ids = work_package_contexts |> Map.keys() |> MapSet.new()
    successor_ids = delivery_board_successor_work_package_ids(repo, work_request.id, opts)
    missing_successor_ids = Enum.reject(successor_ids, &MapSet.member?(loaded_ids, &1))

    successor_contexts =
      repo
      |> work_packages_by_ids(missing_successor_ids)
      |> Enum.filter(&delivery_board_successor_visible?(&1, work_request))
      |> then(&Dashboard.work_package_contexts(repo, &1))

    {:ok, Map.merge(work_package_contexts, successor_contexts)}
  end

  defp delivery_board_successor_visible?(%WorkPackage{} = work_package, %WorkRequest{} = work_request) do
    Dashboard.phase_work_package_matches_filters?(work_package, repo: work_request.repo, base_branch: work_request.base_branch)
  end

  defp delivery_board_successor_visible?(%WorkPackage{} = work_package, work_requests) when is_list(work_requests) do
    Enum.any?(work_requests, &delivery_board_successor_visible?(work_package, &1))
  end

  defp work_packages_by_ids(_repo, []), do: []

  defp work_packages_by_ids(repo, work_package_ids) do
    repo.all(
      from(work_package in WorkPackage,
        where: work_package.id in ^work_package_ids
      )
    )
  end

  defp delivery_board_successor_work_package_ids(repo, work_request_ids, opts) when is_list(work_request_ids) do
    case Keyword.fetch(opts, :deliveries_by_slice_id) do
      {:ok, deliveries_by_slice_id} when is_map(deliveries_by_slice_id) ->
        work_request_ids = MapSet.new(work_request_ids)

        deliveries_by_slice_id
        |> Map.values()
        |> Enum.filter(&MapSet.member?(work_request_ids, &1.work_request_id))
        |> Enum.map(& &1.successor_work_package_id)
        |> Enum.filter(&Dashboard.filled_string?/1)
        |> Enum.uniq()

      {:ok, _other} ->
        []

      :error ->
        repo.all(
          from(delivery in WorkPackageDelivery,
            where: delivery.work_request_id in ^work_request_ids,
            where: not is_nil(delivery.successor_work_package_id),
            distinct: true,
            select: delivery.successor_work_package_id
          )
        )
        |> Enum.filter(&Dashboard.filled_string?/1)
    end
  end

  defp delivery_board_successor_work_package_ids(repo, work_request_id, opts) when is_binary(work_request_id) do
    delivery_board_successor_work_package_ids(repo, [work_request_id], opts)
  end
end
