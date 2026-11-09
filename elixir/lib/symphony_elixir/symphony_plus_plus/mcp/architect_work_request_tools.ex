defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectWorkRequestTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_positive_integer_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [json_safe_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    ErrorDetails,
    ToolCatalog,
    ToolResult,
    WorkPackageLaunch,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @tools [
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "read_delivery_board",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "dispatch_work_package"
  ]
  @work_request_product_tree_views ToolCatalog.work_request_product_tree_views()
  @default_list_limit 50
  @max_list_limit 200

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t() | nil, map(), keyword()) ::
          {:ok, term()} | {:error, integer(), String.t(), map()}
  def call(name, %Config{} = config, terminal, arguments, opts \\ []) when name in @tools do
    call_tool(name, config, terminal, arguments, opts)
  end

  defp call_tool("list_work_requests", config, _terminal, arguments, _opts) do
    with {:ok, phase} <- optional_work_request_phase(arguments),
         {:ok, pagination} <- list_pagination(arguments),
         filters = WorkRequestScope.work_request_list_filters(%{}, phase),
         {:ok, work_requests, next_cursor} <-
           local_work_request_page(
             config.repo,
             WorkRequestScope.work_request_repository_filters(filters),
             pagination
           ),
         {:ok, cards} <- WorkRequestPayloads.work_request_cards(config.repo, work_requests) do
      {:ok,
       ToolResult.agent_tool_result(
         work_request_list_payload(
           cards,
           %{"visibility" => "local_ledger"},
           phase,
           pagination.limit,
           next_cursor
         )
       )}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp call_tool("read_work_request", config, _terminal, arguments, _opts) do
    with {:ok, detail} <- payload_detail(arguments),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         {:ok, payload} <- WorkRequestPayloads.work_request_read(config.repo, work_request, detail) do
      payload = Map.put(payload, "scope", WorkRequestPayloads.redacted_work_request_scope(work_request))
      {:ok, work_request_read_result(payload, detail)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp call_tool("read_plan", config, _terminal, arguments, _opts) do
    with {:ok, detail} <- payload_detail(arguments),
         {:ok, work_request_id, view} <- read_plan_arguments(arguments),
         {:ok, work_request, scope} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         {:ok, result} <- read_plan_result(config.repo, work_request, scope, view, detail) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_plan", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_plan")
      {:error, reason} -> architect_error(reason, "read_plan")
    end
  end

  defp call_tool("read_delivery_board", config, _terminal, arguments, _opts) do
    with {:ok, detail} <- payload_detail(arguments),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, work_packages),
         {:ok, work_request_payload} <- WorkRequestPayloads.put_phase(WorkRequestPayloads.work_request_mutation(work_request), config.repo, work_request) do
      payload = %{
        "work_request" => work_request_payload,
        "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board, detail),
        "detail" => detail,
        "scope" => WorkRequestPayloads.redacted_work_request_scope(work_request)
      }

      {:ok, delivery_board_result(payload, detail)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_delivery_board")
      {:error, reason} -> architect_error(reason, "read_delivery_board")
    end
  end

  defp call_tool("answer_question", config, terminal, arguments, _opts) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", terminal_name(terminal)),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <-
           WorkRequestService.answer_question(config.repo, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by
           }),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_question", reason)
      {:error, :not_found} -> not_found_error("answer_question")
      {:error, reason} -> architect_error(reason, "answer_question")
    end
  end

  defp call_tool("answer_question_and_record_decision", config, terminal, arguments, _opts) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", terminal_name(terminal)),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", answered_by),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id", question_id),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, %{decision: decision_record, question: question_record}} <-
           answer_question_and_record_decision_transaction(config.repo, work_request_id, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "source_type" => source_type,
             "source_id" => source_id,
             "decision" => decision,
             "rationale" => rationale,
             "scope_impact" => scope_impact,
             "created_by" => created_by
           }),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "scope" => scope,
         "status" => %{
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_question_and_record_decision", reason)
      {:error, :not_found} -> not_found_error("answer_question_and_record_decision")
      {:error, reason} -> architect_error(reason, "answer_question_and_record_decision")
    end
  end

  defp call_tool("close_question", config, _terminal, arguments, _opts) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <- WorkRequestService.close_question(config.repo, question_id, expected_question_status),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("close_question", reason)
      {:error, :not_found} -> not_found_error("close_question")
      {:error, reason} -> architect_error(reason, "close_question")
    end
  end

  # Dispatch is the whole hand-off: the ledger dispatch (or its replay) commits
  # first, then the worktree, the assignment file and the launch line. When the
  # hand-off fails the package stays dispatched, and the response carries the
  # error and its next action instead of a launch line; dispatching again
  # retries the hand-off.
  defp call_tool("dispatch_work_package", config, terminal, arguments, _opts) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, review_mode} <- required_enum_argument(arguments, "review_mode", WorkPackage.review_modes()),
         {:ok, agent} <- optional_enum_argument(arguments, "agent", WorkPackageLaunch.agents(), "codex"),
         {:ok, machine} <- optional_string_argument(arguments, "machine"),
         {:ok, target_repo_root} <- optional_string_argument(arguments, "target_repo_root"),
         {:ok, _work_request, _work_package} <- WorkRequestScope.work_package_scope(config.repo, work_request_id, work_package_id),
         {:ok, dispatch} <-
           WorkPackageDispatch.dispatch(config.repo, work_request_id, work_package_id,
             review_mode: review_mode,
             launch_machine: machine || HerdrCore.machine_name(),
             dispatched_by: Terminal.attribution(terminal)
           ) do
      payload =
        case WorkPackageLaunch.hand_off(config, terminal, dispatch.work_package, agent, target_repo_root) do
          {:ok, launch} -> launched_payload(dispatch, launch, agent)
          error -> hand_off_failed_payload(dispatch, error)
        end

      # Text consumers need the whole launch line, which the summary profile would cut.
      {:ok, ToolResult.with_text_profile(:full, fn -> ToolResult.agent_tool_result(payload, fn -> WorkerContext.encode_tool_payload(payload) end) end)}
    else
      {:tool_error, reason} -> invalid_params_error("dispatch_work_package", reason)
      {:error, :not_found} -> not_found_error("dispatch_work_package")
      {:error, reason} -> dispatch_work_package_error(reason)
    end
  end

  defp launched_payload(%{work_package: work_package} = dispatch, launch, agent) do
    dispatch
    |> dispatched_payload()
    |> Map.merge(%{
      "worktree" => %{
        "machine" => work_package.launch_machine,
        "path" => launch.worktree.worktree_path,
        "branch" => launch.worktree.branch,
        "base_branch" => launch.worktree.base_branch
      },
      "assignment_file" => launch.assignment_file,
      "launch_line" => launch.launch_line,
      "next_action" => launch_next_action(agent)
    })
  end

  defp hand_off_failed_payload(%{work_package: work_package} = dispatch, error) do
    {:error, _code, _message, data} =
      case error do
        {:tool_error, reason, details} -> {:error, -32_602, "Invalid params", Map.put(details, "reason", reason)}
        {:tool_error, reason} -> invalid_params_error("dispatch_work_package", reason)
        {:error, reason} -> architect_error(reason, "dispatch_work_package")
      end

    dispatch
    |> dispatched_payload()
    |> Map.merge(%{
      "error" => Map.delete(data, "tool"),
      "next_action" => "Fix the error, then call dispatch_work_package again with review_mode #{work_package.review_mode}; it reuses this dispatch."
    })
  end

  defp dispatched_payload(%{work_package: work_package, replay?: replay?}) do
    %{
      "work_package" => %{
        "id" => work_package.id,
        "status" => work_package.status,
        "review_mode" => work_package.review_mode,
        "review_id" => work_package.review_id
      },
      "replay" => replay?
    }
  end

  defp launch_next_action("claude"),
    do: "Run launch_line, then read the worker's screen: approve Claude's trust prompt for this worktree only."

  defp launch_next_action(_agent), do: "Run launch_line."

  defp read_plan_arguments(arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, view} <- optional_product_tree_view(arguments) do
      {:ok, work_request_id, view}
    end
  end

  defp read_plan_result(repo, %WorkRequest{} = work_request, scope, view, detail) do
    transaction = fn -> read_plan_transaction(repo, work_request, scope, view, detail) end

    case repo.transaction(transaction) do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_plan_transaction(repo, work_request, scope, view, detail) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request.id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request.id),
         {:ok, delivery_board} <- operational_delivery_board(repo, work_request, work_packages),
         {:ok, payload} <-
           WorkRequestPayloads.work_request_product_tree(repo, work_request, work_packages, delivery_board, view) do
      payload = Map.put(payload, "scope", scope)

      if detail == "full" do
        ToolResult.architect_agent_tool_result(payload, :work_request_product_tree)
      else
        read_summary_result(WorkRequestPayloads.plan_summary(payload))
      end
    else
      error -> repo.rollback(error)
    end
  end

  defp operational_delivery_board(repo, work_request, work_packages),
    do: WorkRequestScope.scoped_delivery_board(repo, work_request, work_packages, slice_projection: :operational_state)

  defp dispatch_work_package_error({:invalid_work_package_status, status} = reason) do
    {:error, -32_009, WorkPackageDispatch.error_message(reason),
     %{"tool" => "dispatch_work_package", "reason" => "invalid_work_package_status", "state" => status, "next_action" => dispatch_next_action(status)}}
  end

  defp dispatch_work_package_error({:review_mode_conflict, stored} = reason) do
    {:error, -32_009, WorkPackageDispatch.error_message(reason),
     %{
       "tool" => "dispatch_work_package",
       "reason" => "review_mode_conflict",
       "state" => "dispatched",
       "review_mode" => stored,
       "next_action" => "Call dispatch_work_package with review_mode #{stored}."
     }}
  end

  defp dispatch_work_package_error({:execution_graph_cycle, cycles}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => "dispatch_work_package",
       "reason" => "execution_graph_cycle",
       "cycles" => cycles
     }}
  end

  defp dispatch_work_package_error({:unmet_work_package_dependencies, work_package_id, prerequisite_ids}) do
    reason = {:unmet_work_package_dependencies, work_package_id, prerequisite_ids}

    {:error, -32_602, WorkPackageDispatch.error_message(reason),
     %{
       "tool" => "dispatch_work_package",
       "reason" => "unmet_work_package_dependencies",
       "work_package_id" => work_package_id,
       "prerequisite_work_package_ids" => prerequisite_ids,
       "remediation" => "Complete or skip the prerequisite WorkPackages, then retry dispatch_work_package for WorkPackage #{work_package_id}."
     }}
  end

  defp dispatch_work_package_error({:unsupported_branch_pattern, branch_pattern, reason}) do
    invalid_params_error("dispatch_work_package", {:branch_pattern, branch_pattern, reason})
  end

  defp dispatch_work_package_error(:database_busy) do
    {:error, -32_000, "Ledger busy",
     %{
       "tool" => "dispatch_work_package",
       "reason" => "database_busy",
       "remediation" => "Another ledger writer prevented dispatch. Read the WorkPackage status before dispatching again."
     }}
  end

  defp dispatch_work_package_error(reason), do: architect_error(reason, "dispatch_work_package")

  defp dispatch_next_action("ready"), do: "The package is ready; merge or sync its PR."
  defp dispatch_next_action("ended"), do: "The package has ended; nothing to dispatch."
  defp dispatch_next_action(_status), do: "Read the WorkPackage before dispatching again."

  defp required_enum_argument(arguments, key, allowed) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) -> enum_value(String.trim(value), key, allowed)
      _missing -> {:tool_error, {:invalid_enum, key, allowed}}
    end
  end

  defp optional_enum_argument(arguments, key, allowed, default) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, default}
      {:ok, value} when is_binary(value) -> enum_value(String.trim(value), key, allowed)
      {:ok, _value} -> {:tool_error, {:invalid_enum, key, allowed}}
    end
  end

  defp enum_value(value, key, allowed) do
    if value in allowed, do: {:ok, value}, else: {:tool_error, {:invalid_enum, key, allowed}}
  end

  defp optional_work_request_phase(arguments) do
    case Map.fetch(arguments, "phase") do
      :error ->
        {:ok, nil}

      {:ok, phase} when is_binary(phase) ->
        phase = String.trim(phase)
        if phase in Phase.phases(), do: {:ok, phase}, else: {:tool_error, "invalid_phase"}

      {:ok, _phase} ->
        {:tool_error, "invalid_phase"}
    end
  end

  defp list_pagination(arguments) do
    with {:ok, limit} <- optional_positive_integer_argument(arguments, "limit"),
         limit = limit || @default_list_limit,
         :ok <- require_list_limit(limit),
         {:ok, cursor} <- optional_string_argument(arguments, "cursor"),
         {:ok, cursor} <- decode_list_cursor(cursor) do
      {:ok, %{limit: limit, cursor: cursor}}
    end
  end

  defp require_list_limit(limit) when limit <= @max_list_limit, do: :ok
  defp require_list_limit(_limit), do: {:tool_error, "limit_exceeds_maximum"}

  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(json),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(inserted_at),
         true <- is_binary(id) and String.trim(id) != "" do
      {:ok, {inserted_at, id}}
    else
      _invalid -> {:tool_error, "invalid_cursor"}
    end
  end

  defp local_work_request_page(repo, repository_filters, %{limit: limit, cursor: cursor}) do
    with {:ok, candidates} <- WorkRequestService.list_page(repo, repository_filters, limit + 1, cursor) do
      {work_requests, additional} = Enum.split(candidates, limit)
      next_cursor = if additional == [], do: nil, else: encode_list_cursor(List.last(work_requests))
      {:ok, work_requests, next_cursor}
    end
  end

  defp encode_list_cursor(%WorkRequest{} = work_request) do
    work_request
    |> list_cursor_position()
    |> then(fn {inserted_at, id} ->
      %{"inserted_at" => DateTime.to_iso8601(inserted_at), "id" => id}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end)
  end

  defp list_cursor_position(%WorkRequest{inserted_at: %DateTime{} = inserted_at, id: id}) when is_binary(id),
    do: {inserted_at, id}

  defp work_request_list_payload(cards, scope, phase, limit, next_cursor) do
    %{
      "work_requests" => cards,
      "total_count" => length(cards),
      "scope" => scope,
      "filters" => WorkRequestPayloads.work_request_filter(phase),
      "limit" => limit
    }
    |> maybe_put_next_cursor(next_cursor)
  end

  defp maybe_put_next_cursor(payload, nil), do: payload
  defp maybe_put_next_cursor(payload, next_cursor), do: Map.put(payload, "next_cursor", next_cursor)

  defp optional_product_tree_view(arguments) do
    case Map.fetch(arguments, "view") do
      :error ->
        {:ok, "groups_with_work_package_refs"}

      {:ok, view} when is_binary(view) ->
        view = String.trim(view)

        if view in @work_request_product_tree_views do
          {:ok, view}
        else
          {:tool_error, "invalid_view"}
        end

      {:ok, _view} ->
        {:tool_error, "invalid_view"}
    end
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp terminal_name(%Terminal{display_address: address}), do: address
  defp terminal_name(nil), do: "architect"

  defp expected_question_status_argument(arguments) do
    case Map.fetch(arguments, "expected_question_status") do
      {:ok, status} -> parse_question_status_guard(status)
      :error -> {:ok, "open"}
    end
  end

  defp parse_question_status_guard(status) when is_binary(status) do
    status
    |> String.trim()
    |> require_open_question_status()
  end

  defp parse_question_status_guard(_status), do: {:tool_error, {:invalid_question_status, "non_string", ["open"]}}

  defp require_open_question_status("open"), do: {:ok, "open"}
  defp require_open_question_status(status), do: {:tool_error, {:invalid_question_status, status, ["open"]}}

  defp answer_question_and_record_decision_transaction(repo, work_request_id, question_id, expected_question_status, attrs) do
    repo.transaction(fn ->
      with {:ok, question_record} <-
             WorkRequestService.answer_question(repo, question_id, expected_question_status, %{
               "answer" => Map.fetch!(attrs, "answer"),
               "answered_by" => Map.fetch!(attrs, "answered_by")
             }),
           {:ok, decision_record} <-
             WorkRequestService.record_decision(
               repo,
               work_request_id,
               optional_put(
                 %{
                   "source_type" => Map.fetch!(attrs, "source_type"),
                   "decision" => Map.fetch!(attrs, "decision"),
                   "rationale" => Map.fetch!(attrs, "rationale"),
                   "scope_impact" => Map.fetch!(attrs, "scope_impact"),
                   "created_by" => Map.fetch!(attrs, "created_by")
                 },
                 "source_id",
                 Map.get(attrs, "source_id")
               )
             ) do
        %{question: question_record, decision: decision_record}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)

  defp architect_error({:unauthorized, {:work_request_terminal, terminal_state}}, resource) do
    {:error, -32_001, "Unauthorized",
     %{
       "resource" => resource,
       "reason" => "work_request_terminal",
       "terminal_state" => reason_text(terminal_state)
     }}
  end

  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp architect_error(reason, tool) when reason in [:invalid_repo_root, :missing_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error(reason, tool) when reason in [:invalid_target_repo_root, :missing_target_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error({:git_failed, status, details}, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "git_failed",
       "git" => details |> Map.put(:status, status) |> json_safe_payload() |> Redactor.redact_output()
     }}
  end

  defp architect_error({:stale_existing_branch, details}, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "stale_existing_branch",
       "branch" => details.branch,
       "existing_revision" => details.existing_revision,
       "base_revision" => details.base_revision,
       "base_ref" => details.base_ref,
       "remediation" => details.remediation
     }}
  end

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, {:branch_pattern, value, reason}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => Atom.to_string(reason),
       "validation_errors" => [
         %{
           "field" => "branch_pattern",
           "value" => value,
           "reason" => Atom.to_string(reason),
           "message" => BranchPattern.error_message(reason)
         }
       ]
     }}
  end

  defp invalid_params_error(tool, {:invalid_question_status, got, expected}) do
    expected = Enum.map(expected, &to_string/1)

    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_question_status",
       "status_domain" => "clarification_question",
       "expected_statuses" => expected,
       "got" => got,
       "message" => "expected clarification question status=#{Enum.join(expected, " or ")}, got #{got}"
     }}
  end

  defp invalid_params_error(tool, {:invalid_enum, _field, _allowed} = reason), do: ErrorDetails.invalid_params_error(tool, reason)

  defp invalid_params_error(tool, reason) when reason in [:missing_target_repo_root, "missing_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_target_repo_root",
       "message" => "target_repo_root must point to the target product repository root used for git worktree operations."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_target_repo_root, "invalid_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_target_repo_root",
       "message" => "target_repo_root must point to an existing target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp payload_detail(arguments) do
    case Map.get(arguments, "detail", "summary") do
      detail when detail in ["summary", "full"] -> {:ok, detail}
      _other -> {:tool_error, "invalid_detail"}
    end
  end

  defp work_request_read_result(payload, "full"), do: ToolResult.architect_agent_tool_result(payload, :work_request_read)

  defp work_request_read_result(payload, "summary") do
    read_summary_result(payload)
  end

  defp read_summary_result(payload) do
    text_payload =
      payload
      |> Map.take(~w(work_request summary omitted help))
      |> Map.update!("work_request", &Map.take(&1, ~w(id title phase next_action)))

    ToolResult.with_text_profile(:full, fn ->
      ToolResult.agent_tool_result(payload, fn -> WorkerContext.encode_tool_payload(text_payload) end)
    end)
  end

  defp delivery_board_result(payload, detail) do
    ToolResult.with_text_profile(:full, fn ->
      if detail == "full" do
        ToolResult.architect_agent_tool_result(payload, :work_request_delivery_board)
      else
        ToolResult.read_tool_result(Map.put(payload, "help", "Use read_delivery_board with detail: full for complete evidence."))
      end
    end)
  end
end
