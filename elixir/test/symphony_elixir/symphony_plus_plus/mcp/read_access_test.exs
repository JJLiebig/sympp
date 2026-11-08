Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReadAccessTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.HTTPTransport

  test "reads never take ownership or label the terminal; the first owner-gated write does", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-READS-NEVER-OWN", status: "ready_for_slicing")
    package = add_package!(repo, work_request, "WP-READS-NEVER-OWN")
    client = connect!(repo, "client-reads-never-own")

    for {tool, arguments} <- [
          {"read_work_request", %{"work_request_id" => work_request.id}},
          {"read_plan", %{"work_request_id" => work_request.id}},
          {"read_delivery_board", %{"work_request_id" => work_request.id}},
          {"reconcile_work_request", %{"work_request_id" => work_request.id}},
          {"read_task_plan", %{"work_package_id" => package.id}}
        ] do
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      assert result.herdr_binding == nil, tool
    end

    assert Ownership.owner(repo, work_request.id) == nil

    write = tool!(client, "upsert_group", %{"work_request_id" => work_request.id, "title" => "First write"})
    assert is_binary(write.response["result"]["structuredContent"]["group"]["id"])
    assert %{"role" => "architect", "work_request_id" => work_request_id} = write.herdr_binding
    assert work_request_id == work_request.id
    assert %WorkedOn{display_address: "testbox/t1", state: "live"} = Ownership.owner(repo, work_request.id)

    tools = call!(client, "tools", "tools/list", %{}).response["result"]["tools"] |> Map.new(&{&1["name"], &1})
    assert tools["read_plan"]["annotations"] == %{"readOnlyHint" => true}
    assert tools["upsert_group"]["annotations"] == %{"readOnlyHint" => false}
  end

  test "an owner reads another WorkRequest exactly as named", %{repo: repo} do
    owned = create_work_request!(repo, id: "WR-READS-OWNED", status: "ready_for_slicing")
    other = create_work_request!(repo, id: "WR-READS-OTHER", repo: "nextide/other-product", base_branch: "develop", status: "sliced")
    other_packages = for index <- 1..3, do: add_package!(repo, other, "WP-READS-OTHER-#{index}")
    client = connect!(repo, "client-reads-owner")

    assert tool!(client, "upsert_group", %{"work_request_id" => owned.id, "title" => "Own"}).response["result"]

    read = fn tool, arguments ->
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      result.response["result"]["structuredContent"]
    end

    assert read.("read_work_request", %{"work_request_id" => other.id})["work_request"]["id"] == other.id

    board = read.("read_delivery_board", %{"work_request_id" => other.id, "detail" => "full"})
    assert board["work_request"]["id"] == other.id
    assert length(board["delivery_board"]["work_packages"]) == 3

    plan = read.("read_plan", %{"work_request_id" => other.id, "detail" => "full", "view" => "groups_with_work_packages"})
    assert plan["work_request"]["id"] == other.id
    assert plan["scope"] == %{"repo" => "nextide/other-product", "base_branch" => "develop"}
    assert plan["product_tree"]["work_packages"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.map(other_packages, & &1.id)

    assert read.("read_task_plan", %{"work_package_id" => hd(other_packages).id})["uri"] =~ hd(other_packages).id
    assert read.("reconcile_work_request", %{"work_request_id" => other.id})["work_request"]["id"] == other.id
    assert Ownership.owner(repo, other.id) == nil
  end

  test "a dry run rejects a non-boolean apply", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-READS-DRY-RUN", status: "ready_for_slicing")
    operator = connect!(repo, "client-reads-dry-run")
    refused = tool!(operator, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => "true"})
    assert refused.response["error"]["code"] == -32_602
  end

  defp add_package!(repo, work_request, id) do
    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_request_work_package_attrs(id: id, base_branch: work_request.base_branch))

    package
  end

  defp connect!(repo, client_key) do
    config = local_mcp_config(repo)

    assert {:ok, init} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
               client_key: client_key
             )

    %{config: config, client_key: client_key, state_key: init.state_key}
  end

  defp tool!(client, name, arguments),
    do: call!(client, name, "tools/call", %{"name" => name, "arguments" => arguments, "_meta" => %{"herdr" => MCPHarness.herdr_meta("t1")}})

  defp call!(client, id, method, params) do
    assert {:ok, result} =
             HTTPTransport.handle(
               client.config,
               %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
               client_key: client.client_key,
               state_key: client.state_key
             )

    result
  end
end
