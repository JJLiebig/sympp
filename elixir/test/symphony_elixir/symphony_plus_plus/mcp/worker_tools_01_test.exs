Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

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

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Recorded TOON progress with #{api_token}",
               status: "recorded",
               idempotency_key: "toon-progress",
               payload: %{
                 "accessKey" => access_key,
                 "apiKey" => api_key,
                 "grant_verifier" => "verifier-value",
                 "safe" => "visible"
               }
             })

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

  defp leaked_secret, do: "wk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
