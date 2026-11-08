defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SoloTools do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Normalization
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @show_entry_limit 50
  @base_tools ["solo_attach", "solo_show", "solo_list"]
  @entry_tools [
    "solo_record_task_plan",
    "solo_append_progress",
    "solo_append_finding",
    "solo_record_decision",
    "solo_report_blocker",
    "solo_resolve_blocker",
    "solo_record_validation"
  ]
  @lifecycle_tool_actions [
    {"solo_pause", "pause"},
    {"solo_resume", "resume"},
    {"solo_complete", "complete"},
    {"solo_archive", "archive"}
  ]
  @lifecycle_tools Map.new(@lifecycle_tool_actions)
  @lifecycle_tool_names Enum.map(@lifecycle_tool_actions, &elem(&1, 0))
  @tool_names @base_tools ++ @entry_tools ++ @lifecycle_tool_names

  @type result :: {:ok, map()} | {:error, integer(), String.t(), map()}
  @type error_fun :: (term(), String.t() -> result())

  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @spec tool_spec(String.t()) :: map()
  def tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => description(name),
      "inputSchema" => input_schema(name)
    }
  end

  @spec input_schema(String.t()) :: map()
  def input_schema("solo_attach") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "title" => nullable_string_schema()
      },
      ["repo", "base_branch", "workspace_path", "caller_id"]
    )
  end

  def input_schema("solo_show"), do: schema(%{"session_id" => string_schema()}, ["session_id"])

  def input_schema("solo_list") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "status" => described_string_schema("Optional Solo Session lifecycle status filter: #{Enum.join(Normalization.session_statuses(), ", ")}.")
      },
      []
    )
  end

  def input_schema(name) when name in @lifecycle_tool_names do
    schema(%{"session_id" => string_schema()}, ["session_id"])
  end

  def input_schema(name) when name in ["solo_record_task_plan", "solo_append_progress"] do
    schema(
      base_entry_properties()
      |> Map.put("summary", string_schema())
      |> Map.put("status", friendly_status_schema()),
      ["session_id", "summary"]
    )
  end

  def input_schema("solo_append_finding") do
    schema(
      base_entry_properties()
      |> Map.put("summary", string_schema())
      |> Map.put("severity", nullable_string_schema())
      |> Map.put("status", friendly_status_schema()),
      ["session_id", "summary"]
    )
  end

  def input_schema("solo_record_decision") do
    schema(
      base_entry_properties()
      |> Map.put("decision", string_schema())
      |> Map.put("rationale", markdown_nullable_string_schema("Optional decision rationale."))
      |> Map.put("scope_impact", markdown_nullable_string_schema("Optional scope or delivery impact.")),
      ["session_id", "decision"]
    )
  end

  def input_schema("solo_report_blocker") do
    schema(
      base_entry_properties()
      |> Map.put("summary", string_schema())
      |> Map.put("blocker_id", nullable_string_schema()),
      ["session_id", "summary"]
    )
  end

  def input_schema("solo_resolve_blocker") do
    schema(
      base_entry_properties()
      |> Map.put("blocker_id", string_schema())
      |> Map.put("resolution", described_string_schema("Human-facing blocker resolution."))
      |> Map.put("summary", nullable_string_schema()),
      ["session_id", "blocker_id", "resolution"]
    )
  end

  def input_schema("solo_record_validation") do
    schema(
      base_entry_properties()
      |> Map.put("summary", string_schema())
      |> Map.put(
        "result",
        described_string_schema(
          "Validation result. Accepted canonical values: #{Enum.join(Normalization.validation_results(), ", ")}; common aliases like pass, fail, skip, and not-run are normalized."
        )
      )
      |> Map.put("command", nullable_string_schema())
      |> Map.put("evidence", markdown_nullable_string_schema("Optional lightweight validation evidence.")),
      ["session_id", "summary", "result"]
    )
  end

  @spec call(String.t(), map(), Config.t(), error_fun()) :: result()
  def call(name, arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, payload} <- call_prepared(name, arguments, config) do
      {:ok, tool_result(payload)}
    else
      {:tool_error, reason} -> invalid_params(name, reason)
      {:error, reason} -> solo_error(reason, name, error_fun)
    end
  end

  defp call_prepared("solo_attach", arguments, %Config{} = config) do
    with {:ok, attrs} <- attach_attrs(arguments),
         {:ok, session} <- SoloSessionService.create_or_attach_current(config.repo, attrs) do
      {:ok, %{"action" => "solo_attach", "solo_session" => solo_session_payload(session)}}
    end
  end

  defp call_prepared("solo_show", arguments, %Config{} = config) do
    with {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, session} <- SoloSessionService.get(config.repo, session_id),
         {:ok, entries} <- SoloSessionService.list_entries(config.repo, session_id) do
      recent_entries = recent_entries(entries)

      {:ok,
       %{
         "action" => "solo_show",
         "solo_session" => solo_session_payload(session),
         "entries" => Enum.map(recent_entries, &solo_entry_payload/1),
         "entry_count" => length(entries),
         "entries_returned" => length(recent_entries),
         "entries_truncated" => length(entries) > length(recent_entries)
       }}
    end
  end

  defp call_prepared("solo_list", arguments, %Config{} = config) do
    with {:ok, filters} <- list_filters(arguments),
         {:ok, sessions} <- SoloSessionService.list(config.repo, filters) do
      {:ok, %{"action" => "solo_list", "solo_sessions" => Enum.map(sessions, &solo_session_payload/1)}}
    end
  end

  defp call_prepared(name, arguments, %Config{} = config) when name in @lifecycle_tool_names do
    with {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, session} <- SoloSessionService.apply_lifecycle_action(config.repo, session_id, Map.fetch!(@lifecycle_tools, name)) do
      {:ok, %{"action" => name, "solo_session" => solo_session_payload(session)}}
    end
  end

  defp call_prepared(name, arguments, %Config{} = config) when name in @entry_tools do
    with {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, payload} <- optional_object_argument(arguments, "payload"),
         attrs <- arguments |> Map.put("payload", payload || %{}),
         {:ok, entry} <- call_entry_service(name, config.repo, session_id, attrs) do
      {:ok, %{"action" => name, "entry" => solo_entry_payload(entry)}}
    end
  end

  defp call_entry_service("solo_record_task_plan", repo, session_id, attrs), do: SoloSessionService.record_task_plan(repo, session_id, attrs)
  defp call_entry_service("solo_append_progress", repo, session_id, attrs), do: SoloSessionService.append_progress(repo, session_id, attrs)
  defp call_entry_service("solo_append_finding", repo, session_id, attrs), do: SoloSessionService.append_finding(repo, session_id, attrs)
  defp call_entry_service("solo_record_decision", repo, session_id, attrs), do: SoloSessionService.record_decision(repo, session_id, attrs)
  defp call_entry_service("solo_report_blocker", repo, session_id, attrs), do: SoloSessionService.report_blocker(repo, session_id, attrs)
  defp call_entry_service("solo_resolve_blocker", repo, session_id, attrs), do: SoloSessionService.resolve_blocker(repo, session_id, attrs)
  defp call_entry_service("solo_record_validation", repo, session_id, attrs), do: SoloSessionService.record_validation(repo, session_id, attrs)

  defp description("solo_attach"), do: "Create or attach a local Solo Session for a repo, base branch, absolute workspace path, and caller id."
  defp description("solo_show"), do: "Read a local Solo Session and its latest 50 ordered entries."
  defp description("solo_list"), do: "List local Solo Sessions using optional repo, base branch, workspace path, caller id, and status filters."
  defp description("solo_record_task_plan"), do: "Record the current Solo Session task plan as an append-only task_plan entry."
  defp description("solo_append_progress"), do: "Append a lightweight progress note to a Solo Session."
  defp description("solo_append_finding"), do: "Append a durable finding to a Solo Session."
  defp description("solo_record_decision"), do: "Record a local Solo Session decision with optional rationale and scope impact."
  defp description("solo_report_blocker"), do: "Report an open Solo Session blocker without WorkPackage readiness semantics."
  defp description("solo_resolve_blocker"), do: "Append a Solo Session blocker resolution linked by blocker_id."
  defp description("solo_record_validation"), do: "Record lightweight Solo Session validation with a typed result."
  defp description("solo_pause"), do: "Pause a mutable Solo Session by inferring its current lifecycle status."
  defp description("solo_resume"), do: "Resume a paused Solo Session by inferring its current lifecycle status."
  defp description("solo_complete"), do: "Complete a Solo Session by inferring its current lifecycle status."
  defp description("solo_archive"), do: "Archive a Solo Session by inferring its current lifecycle status."

  defp prepare_repository(repo), do: SoloSessionRepository.migrate(repo)

  defp attach_attrs(arguments) do
    with {:ok, repo_name} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, workspace_path} <- required_argument(arguments, "workspace_path"),
         {:ok, caller_id} <- required_argument(arguments, "caller_id") do
      {:ok,
       %{
         "repo" => repo_name,
         "base_branch" => base_branch,
         "workspace_path" => workspace_path,
         "caller_id" => caller_id,
         "title" => Map.get(arguments, "title")
       }}
    end
  end

  defp recent_entries(entries), do: Enum.take(entries, -@show_entry_limit)

  defp list_filters(arguments) do
    Enum.reduce_while(["repo", "base_branch", "workspace_path", "caller_id", "status"], {:ok, %{}}, fn key, {:ok, filters} ->
      case Map.fetch(arguments, key) do
        :error -> {:cont, {:ok, filters}}
        {:ok, nil} -> {:cont, {:ok, filters}}
        {:ok, value} when is_binary(value) -> {:cont, {:ok, Map.put(filters, key, value)}}
        {:ok, _value} -> {:halt, {:tool_error, "invalid_#{key}"}}
      end
    end)
  end

  defp invalid_params(tool, reason), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}

  defp solo_error(:not_found, tool, _error_fun), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}

  defp solo_error({reason, _value} = error, tool, _error_fun)
       when reason in [:invalid_solo_entry_status, :invalid_solo_lifecycle_action, :invalid_solo_validation_result],
       do: {:error, -32_602, "Invalid params", Normalization.error_data(error, tool)}

  defp solo_error({reason, _field} = error, tool, _error_fun) when reason in [:missing_required_solo_field, :invalid_solo_payload],
    do: {:error, -32_602, "Invalid params", Normalization.error_data(error, tool)}

  defp solo_error({:unsupported_solo_field, _field} = error, tool, _error_fun),
    do: {:error, -32_602, "Invalid params", Normalization.error_data(error, tool)}

  defp solo_error(:solo_blocker_not_open, tool, _error_fun),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "solo_blocker_not_open"}}

  defp solo_error(reason, tool, error_fun), do: error_fun.(reason, tool)

  defp solo_session_payload(%SoloSession{} = session) do
    %{
      "id" => Redactor.redact_text(session.id),
      "repo" => Redactor.redact_text(session.repo),
      "base_branch" => Redactor.redact_text(session.base_branch),
      "workspace_path" => Redactor.redact_text(session.workspace_path),
      "caller_id" => Redactor.redact_text(session.caller_id),
      "title" => Redactor.redact_text(session.title),
      "status" => Redactor.redact_text(session.status),
      "last_activity_at" => timestamp(session.last_activity_at),
      "archived_at" => timestamp(session.archived_at),
      "created_at" => timestamp(session.inserted_at),
      "updated_at" => timestamp(session.updated_at)
    }
  end

  defp solo_entry_payload(%SoloSessionEntry{} = entry) do
    %{
      "id" => Redactor.redact_text(entry.id),
      "solo_session_id" => Redactor.redact_text(entry.solo_session_id),
      "entry_kind" => Redactor.redact_text(entry.entry_kind),
      "title" => Redactor.redact_text(entry.title),
      "body" => Redactor.redact_text(entry.body),
      "status" => Redactor.redact_text(entry.status),
      "sequence" => entry.sequence,
      "idempotency_key" => Redactor.redact_text(entry.idempotency_key),
      "payload" => Redactor.redact_output(entry.payload || %{}),
      "created_at" => timestamp(entry.created_at),
      "updated_at" => timestamp(entry.updated_at)
    }
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil

  defp tool_result(payload) do
    %{
      "content" => [%{"type" => "text", "text" => WorkerContext.encode_tool_payload(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
  end

  defp base_entry_properties do
    %{
      "session_id" => string_schema(),
      "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
      "idempotency_key" => nullable_string_schema(),
      "payload" => object_schema()
    }
  end

  defp friendly_status_schema do
    described_nullable_string_schema("Optional Solo entry display status. Canonical values: #{Enum.join(Normalization.entry_statuses(), ", ")}; common aliases like active and done are normalized.")
  end

  defp string_schema, do: %{"type" => "string"}
  defp described_string_schema(description), do: Map.put(string_schema(), "description", description)
  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp described_nullable_string_schema(description), do: Map.put(nullable_string_schema(), "description", description)
  defp markdown_nullable_string_schema(description), do: described_nullable_string_schema(description)
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end
end
