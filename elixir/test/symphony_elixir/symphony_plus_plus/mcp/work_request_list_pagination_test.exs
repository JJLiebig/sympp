Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestListPaginationTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  defmodule QueryProbe do
    def handle(_event, _measurements, metadata, test_pid), do: send(test_pid, {:list_query, to_string(metadata.query || "")})
  end

  test "list_work_requests pages stable phase matches with bounded queries", %{repo: repo} do
    ready =
      for index <- 1..10 do
        create_work_request!(repo, id: "WR-MCP-PAGE-SCOPED-#{String.pad_leading(Integer.to_string(index), 3, "0")}")
      end

    planned = create_work_request!(repo, id: "WR-MCP-PAGE-SCOPED-PLANNED")

    assert {:ok, _package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               planned.id,
               work_request_work_package_attrs(id: "SYMPP-MCP-PAGE-PLANNED", base_branch: planned.base_branch)
             )

    visible = ready

    handler_id = {__MODULE__, self(), make_ref()}
    event = repo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler_id, event, &QueryProbe.handle/4, self())

    first = mcp_tool(repo, nil, "list_work_requests", %{"phase" => "intake", "limit" => 2})
    :telemetry.detach(handler_id)
    first_payload = get_in(first, ["result", "structuredContent"])
    queries = drain_queries([])

    second =
      mcp_tool(repo, nil, "list_work_requests", %{
        "phase" => "intake",
        "limit" => 2,
        "cursor" => first_payload["next_cursor"]
      })

    second_payload = get_in(second, ["result", "structuredContent"])

    rest =
      mcp_tool(repo, nil, "list_work_requests", %{
        "phase" => "intake",
        "limit" => 6,
        "cursor" => second_payload["next_cursor"]
      })

    third_payload = get_in(rest, ["result", "structuredContent"])

    listed =
      [first_payload, second_payload, third_payload]
      |> Enum.flat_map(& &1["work_requests"])
      |> Enum.map(& &1["id"])

    assert listed == Enum.map(visible, & &1.id)
    assert length(listed) == length(Enum.uniq(listed))
    refute Map.has_key?(third_payload, "next_cursor")

    assert length(queries) < 25
  end

  test "list_work_requests filters by repo identity, whatever form either side names it in", %{repo: repo} do
    by_url = create_work_request!(repo, id: "WR-MCP-REPO-URL", repo: "https://github.com/nextide/billing.git")
    other = create_work_request!(repo, id: "WR-MCP-REPO-OTHER", repo: "nextide/other")
    by_name = create_work_request!(repo, id: "WR-MCP-REPO-NAME", repo: "nextide/billing")

    listed = fn arguments ->
      repo
      |> mcp_tool(nil, "list_work_requests", arguments)
      |> get_in(["result", "structuredContent"])
    end

    for filter <- ["nextide/billing", "git@github.com:nextide/billing.git"] do
      payload = listed.(%{"repo" => filter})
      assert Enum.map(payload["work_requests"], & &1["id"]) == [by_url.id, by_name.id]
      assert payload["filters"] == %{"repo" => filter}
    end

    first = listed.(%{"repo" => "nextide/billing", "limit" => 1})
    assert Enum.map(first["work_requests"], & &1["id"]) == [by_url.id]
    rest = listed.(%{"repo" => "nextide/billing", "limit" => 1, "cursor" => first["next_cursor"]})
    assert Enum.map(rest["work_requests"], & &1["id"]) == [by_name.id]

    assert Enum.map(listed.(%{"repo" => "nextide/other"})["work_requests"], & &1["id"]) == [other.id]
  end

  defp drain_queries(queries) do
    receive do
      {:list_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
