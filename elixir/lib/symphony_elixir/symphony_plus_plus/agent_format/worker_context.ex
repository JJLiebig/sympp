defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @redacted "[REDACTED]"
  @payload_key_limit 20
  @sensitive_agent_suffixes [
    "_access_key",
    "_api_key",
    "_apikey",
    "_authorization",
    "_credential",
    "_handoff",
    "_password",
    "_secret",
    "_token",
    "_verifier"
  ]
  @sensitive_agent_keys MapSet.new([
                          "access_key",
                          "api_key",
                          "apikey",
                          "authorization",
                          "aws_access_key_id",
                          "bearer",
                          "claim_lease_id",
                          "claim_secret",
                          "client_secret",
                          "credential",
                          "grant_verifier",
                          "handoff",
                          "password",
                          "private_key",
                          "private_payload",
                          "proof_hash",
                          "raw_secret",
                          "refresh_token",
                          "secret",
                          "secret_hash",
                          "secret_key",
                          "security_token",
                          "session_token",
                          "token",
                          "verifier",
                          "work_key",
                          "work_key_secret"
                        ])

  @type json_like :: Toon.json_like()

  @spec encode_tool_payload(map()) :: String.t()
  def encode_tool_payload(payload) when is_map(payload) do
    payload
    |> tool_agent_payload()
    |> agent_safe()
    |> encode_agent_payload()
  end

  @doc "A package's progress or handoff for its assignment file."
  @spec virtual_file_payload(State.t(), String.t()) :: {:ok, map()} | {:error, :unknown_virtual_file}
  def virtual_file_payload(%State{} = state, "progress.md") do
    payload =
      state
      |> base_payload("progress.md")
      |> Map.put("progress_events", Enum.map(state.progress_events, &progress_event_payload/1))
      |> Map.put("omitted", %{"progress_events" => state.progress_events_omitted_count || 0})
      |> put_continuation(state.progress_events, state.progress_events_omitted_count)

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "handoff.md") do
    payload =
      state
      |> base_payload("handoff.md")
      |> Map.put("acceptance", Enum.map(state.work_package.acceptance_criteria || [], &Redactor.redact_text/1))
      |> Map.put("latest_progress", state.progress_events |> Enum.take(-3) |> Enum.map(&progress_summary_payload/1))
      |> Map.put("artifacts", Enum.map(state.artifacts, &artifact_payload/1))
      |> Map.put("omitted", %{
        "progress_events" => state.progress_events_omitted_count || 0,
        "artifacts" => state.artifacts_omitted_count || 0
      })
      |> put_continuation(state.artifacts, state.artifacts_omitted_count)

    {:ok, payload}
  end

  def virtual_file_payload(%State{}, _file_name), do: {:error, :unknown_virtual_file}

  defp base_payload(%State{work_package: %WorkPackage{} = work_package}, file_name) do
    %{
      "file" => file_name,
      "work_package_id" => work_package.id,
      "title" => Redactor.redact_text(work_package.title),
      "status" => work_package.status
    }
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "sequence" => event.sequence,
      "idempotency_key" => idempotency_identity(event.idempotency_key),
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "body" => Redactor.redact_text(event.body),
      "actor_id" => Redactor.redact_text(event.actor_id),
      "actor_type" => Redactor.redact_text(event.actor_type),
      "created_at" => timestamp(event.created_at),
      "payload" => progress_payload(event.payload || %{})
    }
  end

  defp progress_summary_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "sequence" => event.sequence,
      "idempotency_key" => idempotency_identity(event.idempotency_key),
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "created_at" => timestamp(event.created_at)
    }
  end

  defp artifact_payload(%Artifact{} = artifact) do
    %{
      "id" => artifact.id,
      "sequence" => artifact.sequence,
      "path" => Redactor.redact_text(artifact.path),
      "title" => Redactor.redact_text(artifact.title),
      "kind" => Redactor.redact_text(artifact.kind),
      "uri" => Redactor.redact_text(artifact.uri),
      "metadata" => payload_overview(artifact.metadata || %{})
    }
  end

  # Generated keys contain encoded payloads; fingerprint them without changing replay identity.
  defp idempotency_identity(key) when is_binary(key) do
    if String.contains?(key, ["mcp:", "operator:"]) do
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    else
      Redactor.redact_text(key)
    end
  end

  defp idempotency_identity(nil), do: nil

  defp put_continuation(payload, [first | _rest], omitted) when is_integer(omitted) and omitted > 0,
    do: Map.put(payload, "next_before_sequence", first.sequence)

  defp put_continuation(payload, _rows, _omitted), do: Map.put(payload, "next_before_sequence", nil)

  # Only these existing observation fields are recoverable; arbitrary payloads stay summarized.
  defp progress_payload(%{} = payload) do
    fields =
      case payload["type"] do
        "branch" -> ~w(type source_tool branch head_sha)
        "pr" -> ~w(type source_tool url repository number branch base_branch base_sha head_sha observed_at merged_at merge_commit_sha provider_reference)
        _other -> ~w(head_sha)
      end

    observation = scalar_fields(payload, fields)

    observation =
      case payload["dependency_inputs"] do
        inputs when is_list(inputs) ->
          Map.put(observation, "dependency_inputs", inputs |> Enum.filter(&is_map/1) |> Enum.map(&scalar_fields(&1, ~w(dependency_id prerequisite_work_package_id candidate_head_sha))))

        _other ->
          observation
      end

    observation = if payload["type"] == "pr", do: pr_observation_states(payload, observation), else: observation
    payload_overview(payload) |> Map.put("observation", agent_safe(observation))
  end

  defp progress_payload(payload), do: payload_overview(payload)

  defp pr_observation_states(payload, observation) do
    Enum.reduce(~w(check_summary review_state merge_state), observation, fn field, result ->
      case payload[field] do
        %{} = value -> Map.put(result, field, scalar_fields(value, ~w(status state conclusion decision merged draft mergeable mergeable_state)))
        _other -> result
      end
    end)
  end

  defp scalar_fields(payload, fields) do
    payload
    |> Map.take(fields)
    |> Map.filter(fn {_key, value} -> is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) end)
  end

  defp tool_agent_payload(%{"progress_event" => %{} = event} = payload) do
    Map.put(payload, "progress_event", Map.update(event, "payload", payload_overview(%{}), &payload_overview/1))
  end

  defp tool_agent_payload(payload), do: payload

  defp payload_overview(%{} = payload) do
    key_count = map_size(payload)
    sensitive_key_count = payload |> Map.keys() |> Enum.count(&sensitive_agent_key?(to_string(&1)))

    %{
      "type" => "object",
      "key_count" => key_count,
      "sensitive_key_count" => sensitive_key_count,
      "omitted_keys" => max(key_count - @payload_key_limit, 0)
    }
  end

  defp payload_overview(values) when is_list(values) do
    %{"type" => "list", "item_count" => length(values)}
  end

  defp payload_overview(nil), do: %{"type" => "null"}
  defp payload_overview(value) when is_boolean(value), do: %{"type" => "boolean"}
  defp payload_overview(value) when is_number(value), do: %{"type" => "number"}
  defp payload_overview(value) when is_binary(value), do: %{"type" => "string"}
  defp payload_overview(_value), do: %{"type" => "other"}

  @doc """
  Redacts a value for any agent that can read it: secret-shaped keys and text
  under the ledger's rules, plus keys such as `credential`, `access_key` and
  `*_verifier` that agent payloads also hide.
  """
  @spec agent_safe(term()) :: term()
  def agent_safe(value) do
    value
    |> Redactor.redact_output()
    |> redact_agent_sensitive_values()
  end

  defp redact_agent_sensitive_values(%{} = map) do
    Map.new(map, fn {key, value} ->
      key = to_string(key)
      value = if sensitive_agent_key?(key), do: @redacted, else: redact_agent_sensitive_values(value)
      {key, value}
    end)
  end

  defp redact_agent_sensitive_values(values) when is_list(values), do: Enum.map(values, &redact_agent_sensitive_values/1)
  defp redact_agent_sensitive_values(value), do: value

  defp sensitive_agent_key?(key) do
    normalized =
      key
      |> camel_to_snake()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    MapSet.member?(@sensitive_agent_keys, normalized) or
      Enum.any?(@sensitive_agent_suffixes, &String.ends_with?(normalized, &1))
  end

  defp encode_agent_payload(payload) do
    Toon.encode(payload)
  rescue
    ArgumentError ->
      Toon.encode(%{"format" => "compact_json_fallback", "json" => Jason.encode!(payload)})
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  defp camel_to_snake(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
  end
end
