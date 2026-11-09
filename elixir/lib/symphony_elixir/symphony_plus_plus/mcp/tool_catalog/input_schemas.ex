defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{SoloTools, ToolCatalog, WorkPackageLaunch}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, Phase, WorkRequest}

  @type tool_name :: String.t()
  @type input_schema :: map()

  @spec solo_tool_input_schema(tool_name()) :: input_schema()
  def solo_tool_input_schema(name), do: SoloTools.input_schema(name)

  @spec bootstrap_tool_input_schema(tool_name()) :: input_schema()
  def bootstrap_tool_input_schema("create_work_request") do
    schema(
      %{
        "repo" => described_string_schema("Git remote URL or owner/name. Remote clients can omit it to infer their checkout origin."),
        "base_branch" => string_schema(),
        "title" => task_title_schema(),
        "description" => markdown_string_schema("WorkRequest human-facing description in Markdown."),
        "request_kind" => string_enum_schema(WorkRequest.work_types()),
        "workflow_mode" => string_enum_schema(WorkRequest.dispatch_shapes()),
        "repo_scopes" => %{
          "type" => "array",
          "items" => %{"type" => "object", "additionalProperties" => false, "properties" => %{"repo" => string_schema(), "base_branch" => string_schema()}, "required" => ["repo"]}
        },
        "constraints" => object_schema(),
        "own" => boolean_schema() |> Map.put("description", "Make the calling terminal the owner (default true). Pass false when handing the WorkRequest to an architect."),
        "creator_kind" => string_enum_schema(WorkRequest.creator_kinds()),
        "creator_name" => string_schema(),
        "created_via" => string_schema()
      },
      ["base_branch", "title", "request_kind", "description"]
    )
  end

  @spec local_operator_tool_input_schema(tool_name()) :: input_schema()
  def local_operator_tool_input_schema("summarize_failed_mcp_calls"), do: schema(%{}, [])

  @doc """
  The published input schema of an architect tool. A tool that names its
  WorkRequest only through `work_request_id` requires it; one that also takes
  a required `work_package_id` may omit it.
  """
  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  def architect_tool_input_schema(name), do: name |> architect_schema() |> require_work_request_target()

  defp require_work_request_target(%{"properties" => %{"work_request_id" => _}, "required" => required} = schema) do
    if "work_package_id" in required or "work_request_id" in required,
      do: schema,
      else: %{schema | "required" => ["work_request_id" | required]}
  end

  defp require_work_request_target(schema), do: schema

  defp architect_schema("list_work_requests") do
    schema(
      %{
        "phase" => string_enum_schema(Phase.phases()),
        "limit" => integer_schema() |> Map.merge(%{"minimum" => 1, "maximum" => 200, "description" => "Page size. Defaults to 50; values above 200 are rejected."}),
        "cursor" => described_string_schema("Opaque cursor returned by the previous list_work_requests page.")
      },
      []
    )
  end

  defp architect_schema("read_work_request") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "view" =>
          ToolCatalog.work_request_views()
          |> string_enum_schema()
          |> Map.merge(%{
            "default" => "overview",
            "description" =>
              "overview: request, packages and next actions; plan: packages by group, dependencies and the execution graph; board: delivery state and evidence; package: one package's contract, dependencies and task plan."
          }),
        "work_package_id" => described_string_schema("Required for view: package."),
        "detail" => payload_detail_schema()
      },
      ["work_request_id"]
    )
  end

  defp architect_schema("sync_pr") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Explicit descendant WorkPackage to synchronize through GitHub."),
        "url" => described_string_schema("PR URL to synchronize; merged PRs close delivery from GitHub merge evidence."),
        "number" => pr_number_schema(),
        "repository" => string_schema(),
        "head_sha" => described_string_schema("Optional expected PR head; when supplied, must match the fetched provider head."),
        "dependency_inputs" => dependency_inputs_schema()
      },
      ["work_package_id"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp architect_schema("reconcile_work_request") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "detail" => payload_detail_schema(),
        "apply" =>
          boolean_schema()
          |> Map.put("description", "When false or omitted, only report proposed closeout repairs. When true, apply through record_work_package_delivery."),
        "recorded_by" => described_string_schema("Optional closeout actor for applied repairs. Defaults to the calling terminal.")
      },
      []
    )
  end

  defp architect_schema("record_work_package_delivery") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("WorkPackage id within the WorkRequest."),
        "outcome" =>
          WorkPackageDelivery.outcomes()
          |> string_enum_schema()
          |> Map.put(
            "description",
            "How the WorkPackage ended. finished ends a dispatched or ready package whose PR waits on someone else; it completes the WorkRequest but never satisfies dependents. skipped ends a planned package."
          ),
        "idempotency_key" => described_string_schema("Stable caller-provided key for replay. Reusing the same key and evidence returns the existing delivery; conflicting evidence is rejected."),
        "recorded_by" => described_string_schema("Optional closeout actor. Defaults to the calling terminal."),
        "evidence" => work_package_delivery_evidence_schema()
      },
      ["work_package_id", "outcome", "idempotency_key"]
    )
  end

  defp architect_schema("set_report") do
    nullable_text = %{"type" => ["string", "null"], "description" => "New text; null clears it."}

    schema(
      %{
        "work_request_id" => string_schema(),
        "brief" => nullable_text,
        "eta" => nullable_text,
        "parking" => %{
          "type" => ["object", "null"],
          "additionalProperties" => false,
          "properties" => %{"reason" => string_schema()},
          "required" => ["reason"],
          "description" => "Why the WorkRequest is parked; null records that it resumed."
        }
      },
      ["work_request_id"]
    )
  end

  defp architect_schema("set_blocker") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "blocker_id" => described_string_schema("Your stable id for this blocker, reused to update or clear it."),
        "active" => boolean_schema() |> Map.put("description", "true declares or updates the blocker; false clears it."),
        "summary" => described_string_schema("What blocks the package. Required when active is true.")
      },
      ["work_package_id", "blocker_id", "active"]
    )
  end

  defp architect_schema("ask") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "work_package_id" => described_string_schema("Optional package the ask is about; the ask is withdrawn when that package ends."),
        "question" => markdown_string_schema("The question for the operator, in Markdown."),
        "decision_prompt" => decision_prompt_schema()
      },
      ["work_request_id", "question"]
    )
  end

  defp architect_schema("resolve_ask") do
    schema(
      %{
        "ask_id" => string_schema(),
        "to" => string_enum_schema(["answered", "withdrawn"]),
        "answer" => markdown_string_schema("The answer, in Markdown. Required for to: answered."),
        "decision" => %{
          "type" => "object",
          "additionalProperties" => false,
          "description" => "Optional decision recorded in the same step, citing this ask.",
          "properties" => %{
            "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
            "decision" => string_schema(),
            "rationale" => markdown_string_schema("Human-facing decision rationale in Markdown."),
            "scope_impact" => markdown_string_schema("Human-facing scope impact note in Markdown.")
          },
          "required" => ["source_type", "decision", "rationale", "scope_impact"]
        }
      },
      ["ask_id", "to"]
    )
  end

  defp architect_schema("record_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "decision" => string_schema(),
        "rationale" => markdown_string_schema("Human-facing decision rationale in Markdown."),
        "scope_impact" => markdown_string_schema("Human-facing scope impact note in Markdown."),
        "created_by" => string_schema(),
        "source_id" => string_schema(),
        "flag" =>
          boolean_schema()
          |> Map.put(
            "description",
            "Flag an in-scope product call for the operator to review (default false). Their feedback is typed into your terminal as \"Decision feedback: ...\" without being submitted."
          )
      },
      ["work_request_id", "source_type", "decision", "rationale", "scope_impact"]
    )
  end

  defp architect_schema("edit_plan") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "ops" => %{
          "type" => "array",
          "minItems" => 1,
          "description" =>
            "Applied in order in one transaction; any failure rolls back the whole edit. " <>
              "A package reference is a WorkPackage id or the key of an earlier add_package.",
          "items" => %{
            "oneOf" => [
              add_package_op_schema(),
              update_package_op_schema(),
              set_dependency_op_schema(),
              remove_dependency_op_schema()
            ]
          }
        }
      },
      ["work_request_id", "ops"]
    )
  end

  defp architect_schema("skip_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => string_schema()
      },
      ["work_package_id"]
    )
  end

  defp architect_schema("dispatch_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => string_schema(),
        "review_mode" =>
          WorkPackage.review_modes()
          |> string_enum_schema()
          |> Map.put("description", "Review Suite mode for the worker: fast, normal (Review Suite base) or deep; none skips the review step."),
        "agent" => WorkPackageLaunch.agents() |> string_enum_schema() |> Map.put("description", "Agent the launch line starts. Defaults to codex."),
        "machine" => described_string_schema("Herdr machine name for the factory host in your hc. Defaults to the factory's own name."),
        "target_repo_root" => described_string_schema("Local factory checkout override. Omit for factories with a repos root.")
      },
      ["work_package_id", "review_mode"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp work_package_delivery_evidence_schema do
    %{
      "type" => "object",
      "description" => "Exactly one typed evidence object matching outcome.",
      "oneOf" => Enum.map(WorkPackageDelivery.outcomes(), &work_package_delivery_outcome_evidence_schema/1)
    }
  end

  defp work_package_delivery_outcome_evidence_schema(outcome) do
    schema(%{outcome => work_package_delivery_typed_evidence_schema(outcome)}, [outcome])
  end

  defp work_package_delivery_typed_evidence_schema(outcome) do
    field_specs = WorkPackageDelivery.evidence_field_specs(outcome)

    properties =
      Map.new(field_specs, fn field_spec ->
        {field_spec.name, work_package_delivery_evidence_field_schema(field_spec)}
      end)

    required = for %{name: name, required: true} <- field_specs, do: name

    schema(properties, required)
  end

  defp work_package_delivery_evidence_field_schema(%{type: :string, description: description}),
    do: described_string_schema(description)

  defp work_package_delivery_evidence_field_schema(%{type: :positive_integer, description: description}),
    do: positive_integer_schema() |> Map.put("description", description)

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
  end

  defp string_schema, do: %{"type" => "string"}
  defp described_string_schema(description), do: Map.put(string_schema(), "description", description)

  defp current_work_request_id_schema,
    do: described_string_schema("WorkRequest id. Optional when work_package_id is given: the package's WorkRequest is used.")

  defp markdown_string_schema(description), do: described_string_schema(description)
  defp string_enum_schema(values) when is_list(values), do: %{"type" => "string", "enum" => values}
  defp nonblank_string_schema, do: %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  defp boolean_schema, do: %{"type" => "boolean"}
  defp integer_schema, do: %{"type" => "integer"}
  defp positive_integer_schema, do: %{"type" => "integer", "minimum" => 1}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp add_package_op_schema do
    work_package_contract_properties()
    |> Map.merge(%{
      "op" => %{"const" => "add_package"},
      "key" => described_string_schema("Optional name later ops in this edit use to refer to the new package."),
      "depends_on" => described_string_array_schema("Package references the new package depends on.")
    })
    |> schema(["op", "title", "goal", "acceptance_criteria", "validation_steps", "stop_conditions"])
    |> Map.put("additionalProperties", true)
  end

  defp update_package_op_schema do
    schema(
      %{
        "op" => %{"const" => "update_package"},
        "work_package_id" => nonblank_string_schema(),
        "expected_revision" => positive_integer_schema(),
        "patch" => work_package_contract_patch_schema()
      },
      ["op", "work_package_id", "expected_revision", "patch"]
    )
  end

  defp set_dependency_op_schema do
    schema(
      %{
        "op" => %{"const" => "set_dependency"},
        "from" => described_string_schema("Package reference that depends on `to`."),
        "to" => described_string_schema("Package reference that must be delivered first."),
        "candidate_head_sha" => %{
          "type" => ["string", "null"],
          "pattern" => "^[0-9a-fA-F]{40}$",
          "description" => "Optional head of `to`, qualified by native checks and review, that `from` may build on before `to` merges. null removes the pin."
        },
        "reason" => described_string_schema("Optional reason for the dependency.")
      },
      ["op", "from", "to"]
    )
  end

  defp remove_dependency_op_schema do
    schema(%{"op" => %{"const" => "remove_dependency"}, "from" => nonblank_string_schema(), "to" => nonblank_string_schema()}, ["op", "from", "to"])
  end

  defp work_package_contract_patch_schema do
    schema(work_package_contract_properties(), [])
    |> Map.put("additionalProperties", true)
  end

  defp work_package_contract_properties do
    %{
      "group" => nullable_string_schema() |> Map.put("description", "Group path such as \"Backend / Billing\"; null or blank for none."),
      "title" => task_title_schema(),
      "goal" => nonblank_string_schema(),
      "kind" => Map.put(string_enum_schema(WorkPackage.kinds()), "default", "standard_pr"),
      "repo" => described_string_schema("Optional delivery repo. Defaults to the WorkRequest primary repo."),
      "base_branch" => described_string_schema("Optional delivery base branch. Defaults to the WorkRequest base branch."),
      "branch_pattern" => described_string_schema("Optional exact branch or {{placeholder}} template."),
      "allowed_file_globs" => described_string_array_schema("Optional descriptive file scope."),
      "forbidden_file_globs" => described_string_array_schema("Optional descriptive exclusions."),
      "acceptance_criteria" => string_array_schema(),
      "validation_steps" => string_array_schema(),
      "review" => review_requirement_schema(),
      "stop_conditions" => string_array_schema()
    }
  end

  defp review_requirement_schema do
    %{
      "type" => "object",
      "description" => "Optional provider-agnostic review requirement. Omit when no review is required.",
      "additionalProperties" => false,
      "properties" => %{
        "type" => nonblank_string_schema() |> Map.put("description", "Opaque review provider or type."),
        "args" => object_schema() |> Map.put("description", "Optional opaque non-secret provider arguments.")
      },
      "required" => ["type"]
    }
  end

  defp decision_prompt_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tl_dr" => nonblank_string_schema(),
        "details" => nonblank_string_schema() |> Map.put("description", "Human-facing decision prompt details in Markdown."),
        "options" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 4,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "id" => nonblank_string_schema(),
              "label" => nonblank_string_schema(),
              "description" => nonblank_string_schema(),
              "pros" => string_array_schema(),
              "cons" => string_array_schema(),
              "answer" => nonblank_string_schema()
            },
            "required" => ["id", "label", "answer"]
          }
        },
        "custom_redirect_label" => nonblank_string_schema()
      },
      "required" => ["tl_dr", "details", "options"]
    }
  end

  defp string_array_schema, do: %{"type" => "array", "items" => nonblank_string_schema()}
  defp described_string_array_schema(description), do: Map.put(string_array_schema(), "description", description)

  defp dependency_inputs_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "description" =>
        "Prerequisite inputs this PR head consumed, one per dependency: the dependency id, its prerequisite WorkPackage and the candidate head pinned on it (null when unpinned). Needs a PR (url, number or head_sha).",
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "dependency_id" => nonblank_string_schema(),
          "prerequisite_work_package_id" => nonblank_string_schema(),
          "candidate_head_sha" => nullable_string_schema()
        },
        "required" => ["dependency_id", "prerequisite_work_package_id", "candidate_head_sha"]
      }
    }
  end

  defp task_title_schema do
    described_string_schema("Title is the short name: 2–5 words, max 40 characters after trimming, e.g. Board read access. Put detail in the description.")
  end

  defp payload_detail_schema do
    ["summary", "full"]
    |> string_enum_schema()
    |> Map.put("default", "summary")
    |> Map.put("description", "Summary by default; full includes the complete payload.")
  end
end
