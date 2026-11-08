Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope

  test "package evidence is idempotent per key and redacts secrets", %{repo: repo} do
    own_package = package_in_request!(repo, "SYMPP-WORKER-OWN", kind: "adapter")

    finding_response =
      call(repo, own_package, "append_finding", %{"title" => "Scoped", "body" => "Own package only", "idempotency_key" => "finding-scoped"})

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Scoped"

    explicit_finding_response =
      call(repo, own_package, "append_finding", %{"id" => " custom-finding-id ", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"})

    assert get_in(explicit_finding_response, ["result", "structuredContent", "finding", "id"]) == "custom-finding-id"

    explicit_finding_replay_response =
      call(repo, own_package, "append_finding", %{"id" => "custom-finding-id-retry", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"})

    assert get_in(explicit_finding_replay_response, ["error", "data", "reason"]) == "idempotency_conflict"

    matching_explicit_finding_replay_response =
      call(repo, own_package, "append_finding", %{"id" => "custom-finding-id", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"})

    assert get_in(matching_explicit_finding_replay_response, ["result", "structuredContent", "finding", "id"]) == "custom-finding-id"

    explicit_finding_id_conflict_response =
      call(repo, own_package, "append_finding", %{"id" => "custom-finding-id", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-other"})

    assert get_in(explicit_finding_id_conflict_response, ["error", "data", "reason"]) == "idempotency_conflict"

    finding_replay_response =
      call(repo, own_package, "append_finding", %{"title" => "Scoped", "body" => "Own package only", "idempotency_key" => "finding-scoped"})

    assert get_in(finding_replay_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(finding_response, ["result", "structuredContent", "finding", "id"])

    whitespace_finding_response =
      call(repo, own_package, "append_finding", %{"title" => "Whitespace", "body" => "Trim idempotency", "idempotency_key" => " finding-space "})

    whitespace_replay_response =
      call(repo, own_package, "append_finding", %{"title" => "Whitespace", "body" => "Trim idempotency", "idempotency_key" => "finding-space"})

    assert get_in(whitespace_replay_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(whitespace_finding_response, ["result", "structuredContent", "finding", "id"])

    conflicting_finding_response =
      call(repo, own_package, "append_finding", %{"title" => "Scoped", "body" => "Different body", "idempotency_key" => "finding-scoped"})

    assert get_in(conflicting_finding_response, ["error", "data", "reason"]) == "idempotency_conflict"

    redacted_progress_args = %{
      "summary" => "Redacted progress",
      "idempotency_key" => "worker-progress-redacted",
      "payload" => %{"token" => "sk-secret"}
    }

    redacted_progress_response =
      call(repo, own_package, "append_progress", redacted_progress_args)

    assert response_progress_payload(repo, redacted_progress_response)["token"] == "[REDACTED]"

    leaked_secret = leaked_secret()
    second_leaked_secret = leaked_secret()
    fine_grained_pat = "github_pat_" <> Base.encode16(:crypto.strong_rand_bytes(18), case: :lower)
    query_password = "pw-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    legacy_aws_access_key_id = "AKIA" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :upper)
    legacy_aws_signature = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    text_redacted_progress_response =
      call(repo, own_package, "append_progress", %{
        "summary" => "Worker pasted #{leaked_secret} then kept going",
        "idempotency_key" => "worker-progress-text-redacted",
        "payload" => %{
          "Authorization: Bearer #{leaked_secret}" => "present",
          "Authorization: Bearer #{second_leaked_secret}" => "also present",
          "fine_grained_pat" => "Saw #{fine_grained_pat}",
          "note" => "Before Bearer #{leaked_secret} after",
          "password_url" => "Login https://example.test/login?password=#{query_password}&page=1",
          "s3_url" => "Fetch https://bucket.s3.amazonaws.test/object?AWSAccessKeyId=#{legacy_aws_access_key_id}&Signature=#{legacy_aws_signature}&Expires=1",
          "safe_url" => "Review https://example.test/issues/1?w=1",
          "signed_url" => "Fetch https://example.test/download?sig=#{leaked_secret}&page=1"
        }
      })

    assert get_in(text_redacted_progress_response, ["result", "structuredContent", "progress_event", "summary"]) ==
             "Worker pasted [REDACTED] then kept going"

    refute Map.has_key?(get_in(text_redacted_progress_response, ["result", "structuredContent", "progress_event"]), "payload")
    encoded_text_redacted_response = Jason.encode!(get_in(text_redacted_progress_response, ["result", "structuredContent"]))
    refute encoded_text_redacted_response =~ leaked_secret
    refute encoded_text_redacted_response =~ second_leaked_secret
    refute encoded_text_redacted_response =~ fine_grained_pat
    refute encoded_text_redacted_response =~ query_password
    refute encoded_text_redacted_response =~ legacy_aws_access_key_id
    refute encoded_text_redacted_response =~ legacy_aws_signature

    redacted_replay_response =
      call(repo, own_package, "append_progress", redacted_progress_args)

    assert get_in(redacted_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(redacted_progress_response, ["result", "structuredContent", "progress_event", "id"])
  end

  test "attach_branch infers the package branch when none is given", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-compact-metadata")

    package =
      package_in_request!(repo, "SYMPP-COMPACT-METADATA",
        kind: "mcp",
        branch_pattern: "agent/{{work_package_id}}/{{slug}}",
        worktree_path: fixture.repo_root
      )

    assert {:ok, branch} = WorktreeScope.prepare_branch(package, nil)
    TestSupport.git_output!(fixture.repo_root, ["checkout", "-b", branch])
    compact_branch_response = attach_tool(repo, "t1", "attach_branch", %{"work_package_id" => package.id, "head_sha" => "compact-head"})
    compact_branch_payload = response_progress_payload(repo, compact_branch_response)
    assert compact_branch_payload["branch"] == branch
    assert compact_branch_payload["head_sha"] == "compact-head"

    verbose_branch_response = attach_tool(repo, "t1", "attach_branch", %{"work_package_id" => package.id, "branch" => branch, "head_sha" => "verbose-head"})
    verbose_branch_payload = response_progress_payload(repo, verbose_branch_response)
    assert verbose_branch_payload["branch"] == branch
    assert verbose_branch_payload["head_sha"] == "verbose-head"

    repo.update_all(
      from(work_package in WorkPackage, where: work_package.id == ^package.id),
      set: [branch_pattern: "legacy/*"]
    )

    invalid_inferred_branch_response =
      call(repo, package, "attach_branch", %{"head_sha" => "invalid-head"})

    assert get_in(invalid_inferred_branch_response, ["error", "code"]) == -32_602
    assert get_in(invalid_inferred_branch_response, ["error", "data", "reason"]) =~ "unsupported_branch_pattern_wildcard"
  end

  test "stored package documents and progress payloads retain redaction at read time", %{repo: repo} do
    leaked_secret = leaked_secret()
    api_token = "sk-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    api_key = "plain-api-key-value"
    access_key = "plain-access-key-value"

    package =
      package_in_request!(repo, "SYMPP-TOON-WORKER",
        kind: "mcp",
        title: "Emit TOON worker context",
        product_description: "Context includes Bearer #{leaked_secret}",
        engineering_scope: "Keep structuredContent JSON stable",
        acceptance_criteria: ["Do not invent completion state"]
      )

    context_text = read_resource_text(repo, package, "context.md")
    assert context_text =~ "Emit TOON worker context"
    assert context_text =~ "[REDACTED]"
    refute context_text =~ leaked_secret

    progress_response =
      call(repo, package, "append_progress", %{
        "summary" => "Recorded TOON progress with #{api_token}",
        "idempotency_key" => "toon-progress",
        "payload" => %{
          "accessKey" => access_key,
          "apiKey" => api_key,
          "grant_verifier" => "verifier-value",
          "private_payload" => %{"path" => "C:/private/payload", "payload" => "private-value"},
          "safe" => "visible"
        }
      })

    progress_text = get_in(progress_response, ["result", "content", Access.at(0), "text"])
    assert progress_text =~ "progress_event:"
    assert progress_text =~ "[REDACTED]"
    assert response_progress_payload(repo, progress_response)["safe"] == "visible"
    refute progress_text =~ access_key
    refute progress_text =~ api_key
    refute progress_text =~ api_token
    refute progress_text =~ "visible"
    refute progress_text =~ "verifier-value"

    resource_text = read_resource_text(repo, package, "progress.md")
    assert resource_text =~ "Recorded TOON progress"
    assert resource_text =~ "[REDACTED]"
    refute resource_text =~ access_key
    refute resource_text =~ api_key
    refute resource_text =~ api_token
    refute resource_text =~ "verifier-value"
  end

  defp read_resource_text(repo, package, document) do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => document, "method" => "resources/read", "params" => %{"uri" => "sympp://work-packages/#{package.id}/#{document}"}},
        repo: repo
      )

    assert [%{"mimeType" => "text/vnd.toon", "text" => text}] = get_in(response, ["result", "contents"]), inspect(response)
    text
  end

  defp package_in_request!(repo, id, overrides) do
    work_request = create_work_request!(repo, id: "WR-" <> id)

    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(Keyword.merge([id: id, work_request_id: work_request.id, status: "dispatched"], overrides)))

    package
  end

  defp call(repo, package, name, arguments), do: mcp_tool(repo, "t1", name, Map.put(arguments, "work_package_id", package.id))

  defp leaked_secret, do: "wk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
