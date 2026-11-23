defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{ToolCatalog, WorkPackageLaunch}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, Phase, WorkRequest}

  @type tool_name :: String.t()
  @type input_schema :: map()

  @doc """
  The published input schema of a tool. A tool that names its WorkRequest only
  through `work_request_id` requires it; one that also takes a required
  `work_package_id` may omit it, and so may `ask`, which then asks on the
  caller's card.
  """
  @spec input_schema(tool_name()) :: input_schema()
  def input_schema("sympp.health"), do: schema(%{}, [])
  def input_schema("ask"), do: tool_schema("ask")
  def input_schema(name), do: name |> tool_schema() |> require_work_request_target()

  defp require_work_request_target(%{"properties" => %{"work_request_id" => _}, "required" => required} = schema) do
    if "work_package_id" in required or "work_request_id" in required,
      do: schema,
      else: %{schema | "required" => ["work_request_id" | required]}
  end

  defp require_work_request_target(schema), do: schema

  defp tool_schema("create_work_request") do
    schema(
      %{
        "repo" => described_string_schema("Git remote URL or owner/name. Remote clients can omit it to infer their checkout origin."),
        "base_branch" => string_schema(),
        "title" => task_title_schema(),
        "description" => markdown_string_schema("WorkRequest human-facing description in Markdown."),
        "work_type" => string_enum_schema(WorkRequest.work_types()),
        "desired_dispatch_shape" =>
          WorkRequest.dispatch_shapes()
          |> string_enum_schema()
          |> Map.put("default", "architect_led_feature_branch"),
        "constraints" => object_schema(),
        "own" => boolean_schema() |> Map.put("description", "Make the calling terminal the owner (default true). Pass false when handing the WorkRequest to an architect.")
      },
      ["base_branch", "title", "work_type", "description"]
    )
  end

  defp tool_schema("move_work_request") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "repo" => described_string_schema("Destination Git remote URL or owner/name."),
        "base_branch" => described_string_schema("Destination base for the request and open packages on its old base that have no prepared worktree or attached PR. Defaults to the current base."),
        "rationale" => described_string_schema("Why the WorkRequest is moving. Recorded in its decisions.")
      },
      ["work_request_id", "repo", "rationale"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp tool_schema("summarize_failed_mcp_calls") do
    schema(
      %{
        "since" => described_string_schema("First day to include, YYYY-MM-DD (UTC). Defaults to every recorded day."),
        "tool" => described_string_schema("Only this tool's failures; \"unknown\" counts calls to tools that don't exist.")
      },
      []
    )
  end

  defp tool_schema("list_work_requests") do
    schema(
      %{
        "phase" => string_enum_schema(Phase.phases()),
        "repo" => described_string_schema("Only WorkRequests for this repo: git remote URL or owner/name."),
        "limit" => integer_schema() |> Map.merge(%{"minimum" => 1, "maximum" => 200, "description" => "Page size. Defaults to 20; values above 200 are rejected."}),
        "cursor" => described_string_schema("Opaque cursor returned by the previous list_work_requests page.")
      },
      []
    )
  end

  defp tool_schema("read_work_request") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "view" => ToolCatalog.work_request_views() |> string_enum_schema() |> Map.put("default", "overview"),
        "work_package_id" => described_string_schema("For package."),
        "ask_id" => described_string_schema("For ask."),
        "decision_id" => described_string_schema("For decision."),
        "cursor" => described_string_schema("Pass next_cursor with the same view and IDs.")
      },
      ["work_request_id"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp tool_schema("sync_pr") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Explicit descendant WorkPackage to synchronize through GitHub."),
        "url" => described_string_schema("PR URL to synchronize; merged PRs close delivery from GitHub merge evidence."),
        "number" => pr_number_schema(),
        "repository" => string_schema(),
        "head_sha" => described_string_schema("Optional expected PR head; when supplied, must match the fetched provider head."),
        "ci_override" => described_string_schema("Why this head may qualify while CI is pending or reports nothing. Never skips failing checks; a new head clears it.")
      },
      ["work_package_id"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp tool_schema("close_work_package") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "outcome" => string_enum_schema(WorkPackageDelivery.close_outcomes()),
        "evidence" => markdown_string_schema("How the work was delivered without a PR. Required for completed_no_pr."),
        "successor_work_package_id" => described_string_schema("The package that replaces this one. Required for superseded."),
        "rationale" => markdown_string_schema("Why it was superseded or abandoned. Required for both."),
        "idempotency_key" => described_string_schema("Optional key for a deliberate replay; defaults to the package and outcome.")
      },
      ["work_package_id", "outcome"]
    )
  end

  defp tool_schema("set_report") do
    nullable_text = %{"type" => ["string", "null"], "description" => "New text; null clears it."}

    schema(
      %{
        "work_request_id" => string_schema(),
        "brief" => %{
          "type" => ["string", "null"],
          "description" => "One or two very plain sentences for the owner: what is being built, how far along it is, what comes next. No paths, IDs, PR numbers or commits."
        },
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

  defp tool_schema("set_blocker") do
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

  defp tool_schema("ask") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "work_package_id" => described_string_schema("Requires work_request_id. Withdrawn at package end."),
        "question" => string_schema(),
        "decision_prompt" => decision_prompt_schema()
      },
      ["question"]
    )
  end

  defp tool_schema("resolve_ask") do
    schema(
      %{
        "ask_id" => string_schema(),
        "to" => string_enum_schema(["answered", "withdrawn"]),
        "answer" => markdown_string_schema("The operator's answer from your conversation, in Markdown. Required to answer an open ask."),
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

  defp tool_schema("record_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "decision" => string_schema(),
        "rationale" => string_schema(),
        "scope_impact" => string_schema(),
        "created_by" => string_schema(),
        "source_id" => string_schema(),
        "flag" => boolean_schema()
      },
      ["work_request_id", "source_type", "decision", "rationale", "scope_impact"]
    )
  end

  defp tool_schema("edit_plan") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "ops" => %{
          "type" => "array",
          "minItems" => 1,
          "description" => "Ops apply in order. A failure rolls back the batch and reports the op index. Package references use IDs or keys from earlier add_package ops.",
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

  defp tool_schema("dispatch_work_package") do
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

  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp add_package_op_schema do
    schema(
      %{
        "op" => %{"const" => "add_package"},
        "title" => string_schema(),
        "goal" => nonblank_string_schema(),
        "acceptance_criteria" => string_array_schema(),
        "validation_steps" => string_array_schema(),
        "stop_conditions" => string_array_schema(),
        "key" => string_schema(),
        "depends_on" => string_array_schema()
      },
      ["op", "title", "goal", "acceptance_criteria", "validation_steps", "stop_conditions"]
    )
    |> Map.put("additionalProperties", true)
  end

  defp update_package_op_schema do
    schema(
      %{
        "op" => %{"const" => "update_package"},
        "work_package_id" => nonblank_string_schema(),
        "expected_revision" => positive_integer_schema(),
        "patch" => object_schema()
      },
      ["op", "work_package_id", "expected_revision", "patch"]
    )
  end

  defp set_dependency_op_schema do
    schema(
      %{
        "op" => %{"const" => "set_dependency"},
        "from" => described_string_schema("Depends on to."),
        "to" => string_schema(),
        "reason" => string_schema()
      },
      ["op", "from", "to"]
    )
  end

  defp remove_dependency_op_schema do
    schema(%{"op" => %{"const" => "remove_dependency"}, "from" => nonblank_string_schema(), "to" => nonblank_string_schema()}, ["op", "from", "to"])
  end

  defp decision_prompt_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tl_dr" => nonblank_string_schema(),
        "details" => nonblank_string_schema(),
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
              "answer" => nonblank_string_schema(),
              "recommended" => %{
                "type" => "boolean",
                "description" => "At most one per prompt."
              }
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

  defp task_title_schema do
    described_string_schema("Title is the short name: 2–5 words, max 40 characters after trimming, e.g. Board read access. Put detail in the description.")
  end
end
