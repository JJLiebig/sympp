defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @text_limit 280
  @detail_list_limit 5

  @spec encode_tool_payload(map(), atom()) :: String.t()
  def encode_tool_payload(payload, kind) when is_map(payload) do
    payload
    |> agent_payload(kind)
    |> Redactor.redact_output()
    |> encode_agent_payload()
  end

  defp agent_payload(payload, :work_request_read), do: work_request_read_payload(payload)

  defp agent_payload(payload, :work_request_plan), do: work_request_plan_payload(payload)

  defp agent_payload(payload, :work_request_delivery_board),
    do: delivery_board_agent_payload(payload)

  defp agent_payload(payload, _kind), do: payload

  defp work_request_read_payload(payload) do
    %{
      "agent_context" => "work_request_read",
      "decision_log_semantics" => "rationale_not_lifecycle_truth",
      "work_request" => payload |> map_value("work_request") |> compact_work_request(),
      "scope" => payload |> map_value("scope") |> primitive_map(),
      "summary" => payload |> map_value("summary") |> primitive_map(),
      "asks" => payload |> map_value("asks") |> list_rows(&ask_row/1),
      "decisions_as_rationale" => payload |> map_value("decision_log_entries") |> list_rows(&decision_row/1),
      "work_packages" => payload |> map_value("work_packages") |> list_rows(&work_package_row/1)
    }
  end

  defp work_request_plan_payload(payload) do
    plan = map_value(payload, "plan") || %{}

    %{
      "agent_context" => "work_request_plan",
      "work_request" => payload |> map_value("work_request") |> compact_work_request(),
      "scope" => payload |> map_value("scope") |> primitive_map(),
      "summary" => plan |> map_value("summary") |> primitive_map(),
      "dependencies" => plan |> map_value("dependencies") |> list_rows(&dependency_row/1),
      "execution_graph" => plan |> map_value("execution_graph") |> execution_graph_row(),
      "work_packages" => plan |> map_value("work_packages") |> list_rows(&work_package_row/1)
    }
  end

  defp delivery_board_agent_payload(payload) do
    board = map_value(payload, "delivery_board") || %{}

    %{
      "agent_context" => "work_request_delivery_board",
      "work_request" => payload |> map_value("work_request") |> compact_mutation_work_request(),
      "scope" => payload |> map_value("scope") |> primitive_map(),
      "counts" => board |> map_value("counts") |> primitive_map(),
      "work_packages" => board |> map_value("work_packages") |> list_rows(&delivery_work_package_row/1)
    }
  end

  defp compact_work_request(nil), do: %{}

  defp compact_work_request(%{} = work_request) do
    %{
      "id" => text_value(map_value(work_request, "id")),
      "title" => text_value(map_value(work_request, "title")),
      "repo" => text_value(map_value(work_request, "repo")),
      "base_branch" => text_value(map_value(work_request, "base_branch")),
      "work_type" => text_value(map_value(work_request, "work_type")),
      "human_description" => text_value(map_value(work_request, "human_description")),
      "constraints" => work_request |> map_value("constraints") |> primitive_map(),
      "desired_dispatch_shape" => text_value(map_value(work_request, "desired_dispatch_shape")),
      "phase" => text_value(map_value(work_request, "phase")),
      "next_action" => text_value(map_value(work_request, "next_action"))
    }
    |> reject_nil_values()
  end

  defp compact_work_request(_value), do: %{}

  defp compact_mutation_work_request(nil), do: %{}

  defp compact_mutation_work_request(%{} = work_request) do
    %{
      "id" => text_value(map_value(work_request, "id")),
      "phase" => text_value(map_value(work_request, "phase")),
      "updated_at" => text_value(map_value(work_request, "updated_at"))
    }
    |> reject_nil_values()
  end

  defp compact_mutation_work_request(_value), do: %{}

  defp ask_row(%{} = ask) do
    %{
      "id" => text_value(map_value(ask, "id")),
      "state" => text_value(map_value(ask, "state")),
      "work_package_id" => text_value(map_value(ask, "work_package_id")),
      "asked_by" => text_value(map_value(ask, "asked_by")),
      "question" => text_value(map_value(ask, "question")),
      "answer" => text_value(map_value(ask, "answer"))
    }
  end

  defp decision_row(%{} = decision) do
    %{
      "id" => text_value(map_value(decision, "id")),
      "sequence" => integer_value(map_value(decision, "sequence")),
      "source_type" => text_value(map_value(decision, "source_type")),
      "decision" => text_value(map_value(decision, "decision")),
      "rationale" => text_value(map_value(decision, "rationale")),
      "scope_impact" => text_value(map_value(decision, "scope_impact"))
    }
  end

  defp work_package_row(%{} = work_package) do
    %{
      "id" => text_value(map_value(work_package, "id")),
      "group" => text_value(map_value(work_package, "group")),
      "sequence" => integer_value(map_value(work_package, "sequence")),
      "title" => text_value(map_value(work_package, "title")),
      "goal" => text_value(map_value(work_package, "goal")),
      "status" => text_value(map_value(work_package, "status")),
      "kind" => text_value(map_value(work_package, "kind")),
      "base_branch" => text_value(map_value(work_package, "base_branch")),
      "branch_pattern" => text_value(map_value(work_package, "branch_pattern")),
      "allowed_file_globs" => work_package |> map_value("allowed_file_globs") |> detail_list(),
      "forbidden_file_globs" => work_package |> map_value("forbidden_file_globs") |> detail_list(),
      "acceptance_count" => list_count(map_value(work_package, "acceptance_criteria")),
      "acceptance_criteria" => work_package |> map_value("acceptance_criteria") |> detail_list(),
      "validation_count" => list_count(map_value(work_package, "validation_steps")),
      "validation_steps" => work_package |> map_value("validation_steps") |> detail_list(),
      "review" => map_value(work_package, "review")
    }
  end

  defp delivery_work_package_row(%{} = projected_work_package) do
    work_package = map_value(projected_work_package, "work_package") || %{}
    operational_state = map_value(projected_work_package, "operational_state") || %{}
    delivery = map_value(projected_work_package, "delivery") || %{}
    blocker_state = map_value(work_package, "blocker_state") || %{}
    runtime_state = map_value(work_package, "runtime_state") || %{}
    pr = map_value(work_package, "pr") || %{}

    %{
      "id" => text_value(map_value(projected_work_package, "id")),
      "sequence" => integer_value(map_value(projected_work_package, "sequence")),
      "title" => text_value(map_value(projected_work_package, "title")),
      "raw_status" => text_value(map_value(projected_work_package, "raw_status")),
      "delivery_outcome" => text_value(map_value(projected_work_package, "delivery_outcome")),
      "delivery_pr" => text_value(map_value(delivery, "pr_url")),
      "work_package_id" => text_value(map_value(work_package, "id")),
      "work_package_status" =>
        text_value(
          first_present([
            map_value(work_package, "status"),
            map_value(work_package, "raw_status")
          ])
        ),
      "state" => text_value(map_value(operational_state, "key")),
      "state_severity" => text_value(map_value(operational_state, "severity")),
      "attention" => attention_items(operational_state),
      "blocker_active" => bool_value(map_value(blocker_state, "active?")),
      "blocker_ids" => blocker_state |> map_value("active_ids") |> join_list(),
      "runtime_active" => bool_value(map_value(runtime_state, "active?")),
      "pr_url" => text_value(map_value(pr, "url")),
      "pr_state" => text_value(map_value(pr, "state")),
      "review_verdict" => review_verdict(work_package)
    }
  end

  defp dependency_row(%{} = dependency) do
    %{
      "id" => text_value(map_value(dependency, "id")),
      "from" => text_value(map_value(dependency, "from")),
      "to" => text_value(map_value(dependency, "to")),
      "candidate_head_sha" => text_value(map_value(dependency, "candidate_head_sha")),
      "reason" => text_value(map_value(dependency, "reason"))
    }
    |> reject_nil_values()
  end

  defp execution_graph_row(%{} = graph) do
    %{
      "available" => bool_value(map_value(graph, "available")),
      "topological_order" => graph |> map_value("topological_order") |> join_list(),
      "cycles" => graph |> map_value("cycles") |> cycle_rows(),
      "unmet_dependencies" => graph |> map_value("unmet_dependencies") |> list_rows(&unmet_dependency_row/1),
      "dependency_ready_work_package_ids" => graph |> map_value("dependency_ready_work_package_ids") |> join_list(),
      "effective_edges" => graph |> map_value("effective_edges") |> list_rows(&effective_edge_row/1),
      "resolutions" => graph |> map_value("resolutions") |> list_rows(&resolution_row/1)
    }
  end

  defp execution_graph_row(_graph), do: %{}

  defp cycle_rows(cycles) when is_list(cycles), do: Enum.map(cycles, &join_list/1)
  defp cycle_rows(_cycles), do: []

  defp unmet_dependency_row(%{} = dependency) do
    %{
      "work_package_id" => text_value(map_value(dependency, "work_package_id")),
      "prerequisite_work_package_ids" => dependency |> map_value("prerequisite_work_package_ids") |> join_list()
    }
  end

  defp effective_edge_row(%{} = edge) do
    %{
      "prerequisite_work_package_id" => text_value(map_value(edge, "prerequisite_work_package_id")),
      "dependent_work_package_id" => text_value(map_value(edge, "dependent_work_package_id")),
      "dependency_ids" => edge |> map_value("dependency_ids") |> join_list()
    }
  end

  defp resolution_row(%{} = resolution) do
    %{
      "work_package_id" => text_value(map_value(resolution, "work_package_id")),
      "status" => text_value(map_value(resolution, "status")),
      "delivery_outcome" => text_value(map_value(resolution, "delivery_outcome")),
      "resolved" => bool_value(map_value(resolution, "resolved"))
    }
    |> reject_nil_values()
  end

  defp list_rows(values, mapper) when is_list(values), do: Enum.map(values, mapper)
  defp list_rows(_values, _mapper), do: []

  defp primitive_map(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), primitive_value(value)} end)
  end

  defp primitive_map(_value), do: %{}

  defp primitive_value(value) when is_binary(value), do: text_value(value)

  defp primitive_value(value) when is_boolean(value) or is_number(value) or is_nil(value),
    do: value

  defp primitive_value(values) when is_list(values), do: join_list(values)
  defp primitive_value(%{} = map), do: "#{map_size(map)} keys"
  defp primitive_value(value) when is_atom(value), do: Atom.to_string(value)
  defp primitive_value(value), do: inspect(value)

  defp text_value(nil), do: nil

  defp text_value(value) when is_binary(value) do
    redacted = Redactor.redact_text(value)

    if String.length(redacted) > @text_limit do
      String.slice(redacted, 0, @text_limit) <> "..."
    else
      redacted
    end
  end

  defp text_value(value) when is_atom(value), do: Atom.to_string(value)
  defp text_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text_value(value), do: inspect(value)

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value("true"), do: true
  defp bool_value("false"), do: false
  defp bool_value(_value), do: nil

  defp list_count(values) when is_list(values), do: length(values)
  defp list_count(_values), do: 0

  defp join_list(values) when is_list(values) do
    values
    |> Enum.map(&text_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp join_list(_values), do: nil

  defp detail_list(values) when is_list(values) do
    values
    |> Enum.map(&text_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@detail_list_limit)
  end

  defp detail_list(_values), do: []

  defp attention_items(%{} = operational_state) do
    operational_state
    |> map_value("attention_items")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = item -> [map_value(item, "key") || map_value(item, "label")]
      _item -> []
    end)
    |> join_list()
  end

  defp review_verdict(%{} = work_package) do
    review = map_value(work_package, "review") || %{}

    [
      review |> map_value("suite_result") |> map_value("verdict"),
      review |> map_value("package") |> map_value("reviews") |> first_review_verdict(),
      review |> map_value("progress") |> map_value("verdict")
    ]
    |> first_present()
    |> text_value()
  end

  defp review_verdict(_work_package), do: nil

  defp first_review_verdict([%{} = review | _rest]), do: map_value(review, "verdict")
  defp first_review_verdict(_reviews), do: nil

  defp first_present(values) when is_list(values), do: Enum.find(values, &present?/1)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(%{} = map), do: map_size(map) > 0
  defp present?(_value), do: true

  defp map_value(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> find_string_key_value(map, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp find_string_key_value(map, key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: value

      _entry ->
        nil
    end)
  end

  defp reject_nil_values(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_agent_payload(payload) do
    Toon.encode(payload)
  rescue
    ArgumentError ->
      Toon.encode(%{"format" => "compact_json_fallback", "json" => Jason.encode!(payload)})
  end
end
