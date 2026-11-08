defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{SoloTools, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, Phase, WorkRequest}

  @local_operator_provenance_max_length 512
  @local_operator_text_max_length 4_000
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
  def local_operator_tool_input_schema("record_work_request_operator_decision") do
    schema(
      %{
        "work_request_id" => described_string_schema("Target WorkRequest id."),
        "decision" =>
          described_string_schema("Non-secret decision summary text. Redacted before storage and response.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "rationale" =>
          markdown_string_schema("Non-secret Markdown rationale for the decision.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "scope_impact" =>
          markdown_string_schema("Non-secret Markdown note on scope or delivery impact.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "created_by" =>
          described_string_schema("Optional provenance override. Defaults to the calling terminal.")
          |> Map.put("maxLength", @local_operator_provenance_max_length),
        "source_id" =>
          described_string_schema("Optional local source id, such as a PR review or operator note id.")
          |> Map.put("maxLength", @local_operator_provenance_max_length)
      },
      ["work_request_id", "decision", "rationale", "scope_impact"]
    )
  end

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

  defp architect_schema("read_task_plan") do
    schema(%{"work_package_id" => string_schema()}, ["work_package_id"])
  end

  defp architect_schema("update_task_plan") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "expected_version" => integer_schema(),
        "nodes" => plan_nodes_schema()
      },
      ["work_package_id", "expected_version", "nodes"]
    )
  end

  defp architect_schema("append_finding") do
    schema(
      scoped_properties(%{
        "body" => markdown_string_schema("Human-facing finding details in Markdown."),
        "id" => string_schema(),
        "idempotency_key" => string_schema(),
        "severity" => string_schema(),
        "title" => string_schema()
      }),
      ["work_package_id", "title", "body", "idempotency_key"]
    )
  end

  defp architect_schema("append_progress") do
    schema(progress_properties(:explicit), ["work_package_id", "summary", "idempotency_key"])
  end

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
    schema(%{"work_request_id" => string_schema(), "detail" => payload_detail_schema()}, ["work_request_id"])
  end

  defp architect_schema("read_plan") do
    schema(
      %{
        "work_request_id" => described_string_schema("Scoped WorkRequest id to project."),
        "detail" => payload_detail_schema(),
        "view" =>
          ToolCatalog.work_request_product_tree_views()
          |> string_enum_schema()
          |> Map.put("description", "Projection size. Defaults to groups_with_work_package_refs.")
      },
      ["work_request_id"]
    )
  end

  defp architect_schema("read_delivery_board") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "detail" => payload_detail_schema()
      },
      []
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
        "head_sha" => described_string_schema("Optional expected PR head; when supplied, must match the fetched provider head.")
      },
      ["work_package_id"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp architect_schema("attach_branch") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Explicit descendant WorkPackage whose canonical branch metadata will be updated."),
        "branch" => string_schema(),
        "head_sha" => string_schema()
      },
      ["work_package_id", "head_sha"]
    )
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

  defp architect_schema("resolve_blocker") do
    schema(
      progress_properties(:explicit)
      |> Map.merge(%{
        "blocker_id" => string_schema(),
        "resolution" => string_schema(),
        "status" => string_enum_schema(["resolved"])
      }),
      ["work_package_id", "blocker_id", "resolution", "summary", "idempotency_key"]
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

  defp architect_schema("ask_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "category" => string_schema(),
        "question" => markdown_string_schema("Human-facing clarification question in Markdown."),
        "why_needed" => markdown_string_schema("Human-facing Markdown explanation of why the answer is needed."),
        "decision_prompt" => decision_prompt_schema(),
        "asked_by_agent_run_id" => string_schema()
      },
      ["work_request_id", "category", "question", "why_needed"]
    )
  end

  defp architect_schema("answer_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema(),
        "answer" => markdown_string_schema("Human-facing clarification answer in Markdown."),
        "answered_by" => string_schema()
      },
      ["work_request_id", "question_id", "answer"]
    )
  end

  defp architect_schema("answer_question_and_record_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema(),
        "answer" => markdown_string_schema("Human-facing clarification answer in Markdown."),
        "answered_by" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "source_id" => string_schema(),
        "decision" => string_schema(),
        "rationale" => markdown_string_schema("Human-facing decision rationale in Markdown."),
        "scope_impact" => markdown_string_schema("Human-facing scope impact note in Markdown."),
        "created_by" => string_schema()
      },
      ["work_request_id", "question_id", "answer", "source_type", "decision", "rationale", "scope_impact"]
    )
  end

  defp architect_schema("close_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema()
      },
      ["work_request_id", "question_id"]
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
        "source_id" => string_schema()
      },
      ["work_request_id", "source_type", "decision", "rationale", "scope_impact"]
    )
  end

  defp architect_schema("slice_work_request") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_packages" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => work_package_contract_schema()
        }
      },
      ["work_packages"]
    )
  end

  defp architect_schema("update_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => nonblank_string_schema(),
        "expected_contract_revision" => positive_integer_schema(),
        "patch" => work_package_contract_patch_schema()
      },
      ["work_package_id", "expected_contract_revision", "patch"]
    )
  end

  defp architect_schema("upsert_group"), do: upsert_group_schema()

  defp architect_schema("delete_group") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "group_id" => nonblank_string_schema()
      },
      ["group_id"]
    )
  end

  defp architect_schema("upsert_dependency"), do: upsert_dependency_schema()

  defp architect_schema("delete_dependency") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "dependency_id" => nonblank_string_schema()
      },
      ["dependency_id"]
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
        "detail" => payload_detail_schema()
      },
      ["work_package_id"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp architect_schema("prepare_work_package_worktree") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => string_schema(),
        "target_repo_root" => described_string_schema("Local factory checkout override. Omit for remote factories, which resolve the WorkPackage remote under their repos root."),
        "branch" =>
          described_string_schema("Optional branch override. Omit it to derive a package-unique branch from the WorkPackage id or branch_pattern template. Exact branch patterns are used unchanged.")
      },
      ["work_package_id"]
    )
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

  defp always_validate(schema, constraint), do: Map.merge(schema, %{"if" => %{}, "then" => constraint})

  defp scoped_properties(properties), do: Map.put(properties, "work_package_id", string_schema())

  defp progress_properties(:explicit) do
    scoped_properties(%{
      "summary" => string_schema(),
      "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
      "status" => string_schema(),
      "idempotency_key" => string_schema(),
      "payload" => object_schema()
    })
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
  defp nonnegative_integer_schema, do: %{"type" => "integer", "minimum" => 0}
  defp positive_integer_schema, do: %{"type" => "integer", "minimum" => 1}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp markdown_nullable_string_schema(description), do: Map.put(nullable_string_schema(), "description", description)
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp work_package_contract_schema do
    schema(
      work_package_contract_properties(),
      ["title", "goal", "acceptance_criteria"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp work_package_contract_patch_schema do
    schema(work_package_contract_properties(), [])
    |> Map.put("additionalProperties", true)
  end

  defp work_package_contract_properties do
    %{
      "group_id" => nullable_string_schema(),
      "title" => task_title_schema(),
      "goal" => nonblank_string_schema(),
      "kind" => Map.put(string_enum_schema(WorkPackage.executable_kinds()), "default", "standard_pr"),
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

  defp dependency_endpoint_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "kind" => string_enum_schema(["work_package", "group"]),
        "id" => nonblank_string_schema()
      },
      "required" => ["kind", "id"]
    }
  end

  defp upsert_group_schema do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "group_id" => described_string_schema("Optional existing Group id. Omit to create a Group."),
        "title" => nonblank_string_schema(),
        "description" => markdown_nullable_string_schema("Optional human-facing Group description."),
        "kind" => described_string_schema("Optional loose organization hint such as capability, milestone, or risk."),
        "parent_group_id" => nullable_string_schema() |> Map.put("description", "Optional parent Group id; pass null to move the Group to the WorkRequest root."),
        "position" => nonnegative_integer_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      []
    )
    |> always_validate(%{
      "allOf" => [
        %{"anyOf" => [%{"required" => ["group_id"]}, %{"required" => ["title"]}]},
        %{
          "anyOf" => Enum.map(["title", "description", "kind", "parent_group_id", "position"], &%{"required" => [&1]})
        }
      ]
    })
  end

  defp upsert_dependency_schema do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "dependency_id" => described_string_schema("Optional existing dependency id. Omit to create a dependency."),
        "dependent" => dependency_endpoint_schema(),
        "prerequisite" => dependency_endpoint_schema(),
        "candidate_head_sha" => %{
          "type" => ["string", "null"],
          "pattern" => "^[0-9a-fA-F]{40}$",
          "description" => "Optional exact head of a concrete prerequisite WorkPackage qualified by the caller using native checks/review. Enables wiring before delivery; null removes the pin."
        },
        "reason" => markdown_string_schema("Why this dependency exists."),
        "decision_ref" => object_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      ["dependent", "prerequisite"]
    )
    |> always_validate(%{"anyOf" => [%{"required" => ["reason"]}, %{"required" => ["decision_ref"]}]})
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

  defp plan_nodes_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "id" => nonblank_string_schema(),
          "title" => nonblank_string_schema(),
          "body" => nullable_string_schema(),
          "status" => string_enum_schema(PlanNode.statuses())
        }
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
