Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestListPaginationTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  defmodule QueryProbe do
    def handle(_event, _measurements, metadata, test_pid), do: send(test_pid, {:list_query, to_string(metadata.query || "")})
  end

  test "list_work_requests pages stable status matches with bounded queries", %{repo: repo} do
    ready =
      for index <- 1..10 do
        create_work_request!(repo,
          id: "WR-MCP-PAGE-SCOPED-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          status: "ready_for_slicing"
        )
      end

    _draft =
      create_work_request!(repo,
        id: "WR-MCP-PAGE-SCOPED-DRAFT",
        status: "draft"
      )

    visible = ready

    handler_id = {__MODULE__, self(), make_ref()}
    event = repo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler_id, event, &QueryProbe.handle/4, self())

    first = mcp_tool(repo, nil, "list_work_requests", %{"status" => "ready_for_slicing", "limit" => 2})
    :telemetry.detach(handler_id)
    first_payload = get_in(first, ["result", "structuredContent"])
    queries = drain_queries([])

    second =
      mcp_tool(repo, nil, "list_work_requests", %{
        "status" => "ready_for_slicing",
        "limit" => 2,
        "cursor" => first_payload["next_cursor"]
      })

    second_payload = get_in(second, ["result", "structuredContent"])

    rest =
      mcp_tool(repo, nil, "list_work_requests", %{
        "status" => "ready_for_slicing",
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

  defp drain_queries(queries) do
    receive do
      {:list_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
