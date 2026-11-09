Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReadAccessTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.HTTPTransport

  test "reads never take ownership or label the terminal; the first owner-gated write does", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-READS-NEVER-OWN")
    package = add_package!(repo, work_request, "WP-READS-NEVER-OWN")
    client = connect!(repo, "client-reads-never-own")

    for {tool, arguments} <- [
          {"read_work_request", %{"work_request_id" => work_request.id}},
          {"read_work_request", %{"work_request_id" => work_request.id, "view" => "plan"}},
          {"read_work_request", %{"work_request_id" => work_request.id, "view" => "board"}},
          {"read_work_request", %{"work_request_id" => work_request.id, "view" => "package", "work_package_id" => package.id}}
        ] do
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      assert result.herdr_binding == nil, tool
    end

    assert Ownership.owner(repo, work_request.id) == nil

    write = tool!(client, "edit_plan", %{"work_request_id" => work_request.id, "ops" => [group_op(package)]})
    assert [%{"op" => "update_package"}] = write.response["result"]["structuredContent"]["applied"]
    assert %{"role" => "architect", "work_request_id" => work_request_id} = write.herdr_binding
    assert work_request_id == work_request.id
    assert %WorkedOn{display_address: "testbox/t1", state: "live"} = Ownership.owner(repo, work_request.id)

    tools = call!(client, "tools", "tools/list", %{}).response["result"]["tools"] |> Map.new(&{&1["name"], &1})
    assert tools["read_work_request"]["annotations"] == %{"readOnlyHint" => true}
    assert tools["edit_plan"]["annotations"] == %{"readOnlyHint" => false}
  end

  test "an owner reads another WorkRequest exactly as named", %{repo: repo} do
    owned = create_work_request!(repo, id: "WR-READS-OWNED")
    owned_package = add_package!(repo, owned, "WP-READS-OWNED")
    other = create_work_request!(repo, id: "WR-READS-OTHER", repo: "nextide/other-product", base_branch: "develop")
    other_packages = for index <- 1..3, do: add_package!(repo, other, "WP-READS-OTHER-#{index}")
    client = connect!(repo, "client-reads-owner")

    assert tool!(client, "edit_plan", %{"work_request_id" => owned.id, "ops" => [group_op(owned_package)]}).response["result"]

    read = fn tool, arguments ->
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      result.response["result"]["structuredContent"]
    end

    assert read.("read_work_request", %{"work_request_id" => other.id})["work_request"]["id"] == other.id

    board = read.("read_work_request", %{"work_request_id" => other.id, "view" => "board", "detail" => "full"})
    assert board["work_request"]["id"] == other.id
    assert length(board["delivery_board"]["work_packages"]) == 3

    plan = read.("read_work_request", %{"work_request_id" => other.id, "view" => "plan", "detail" => "full"})
    assert plan["work_request"]["id"] == other.id
    assert plan["scope"] == %{"repo" => "nextide/other-product", "base_branch" => "develop"}
    assert plan["plan"]["work_packages"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.map(other_packages, & &1.id)

    package = read.("read_work_request", %{"work_request_id" => other.id, "view" => "package", "work_package_id" => hd(other_packages).id})
    assert package["work_package"]["id"] == hd(other_packages).id
    assert %{"version" => _, "steps" => []} = package["task_plan"]
    assert Ownership.owner(repo, other.id) == nil
  end

  defp add_package!(repo, work_request, id) do
    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_request_work_package_attrs(id: id, base_branch: work_request.base_branch))

    package
  end

  defp group_op(package),
    do: %{"op" => "update_package", "work_package_id" => package.id, "expected_revision" => package.contract_revision, "patch" => %{"group" => "Reads"}}

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
