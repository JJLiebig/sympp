Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReadAccessTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.HTTPTransport

  test "reads never claim or assign a role; the first write claims", %{repo: repo} do
    {work_request, handoff} = claimable_work_request!(repo, "WR-READS-NEVER-CLAIM")
    package = add_package!(repo, work_request, "WP-READS-NEVER-CLAIM")
    client = connect!(repo, "client-reads-never-claim")

    for {tool, arguments} <- [
          {"read_work_request", %{"work_request_id" => work_request.id}},
          {"read_plan", %{"work_request_id" => work_request.id}},
          {"read_delivery_board", %{"work_request_id" => work_request.id}},
          {"reconcile_work_request", %{"work_request_id" => work_request.id}},
          {"read_task_plan", %{"work_package_id" => package.id}},
          {"list_comments", %{"target_kind" => "work_request", "target_id" => work_request.id}}
        ] do
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      assert result.herdr_binding == nil, tool
    end

    refused = tool!(client, "list_guidance_requests", %{"work_request_id" => work_request.id})
    assert %{"reason" => "claim_required", "action" => "claim_local_architect_assignment", "message" => message} = refused.response["error"]["data"]
    assert message =~ "list_guidance_requests"
    assert refused.herdr_binding == nil

    assert {:error, _no_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert tool!(client, "get_current_assignment", %{}).response["result"]["structuredContent"]["assignment"] == nil

    write = tool!(client, "upsert_group", %{"work_request_id" => work_request.id, "title" => "First write"})
    assert is_binary(write.response["result"]["structuredContent"]["group"]["id"])
    assert %{"role" => "architect", "work_request_id" => work_request_id} = write.herdr_binding
    assert work_request_id == work_request.id
    assert {:ok, %ClaimLease{status: "active"}} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    tools = call!(client, "tools", "tools/list", %{}).response["result"]["tools"] |> Map.new(&{&1["name"], &1})
    assert tools["read_plan"]["annotations"] == %{"readOnlyHint" => true}
    assert tools["upsert_group"]["annotations"] == %{"readOnlyHint" => false}
  end

  test "a bound architect reads another WorkRequest exactly as named", %{repo: repo} do
    {bound, _handoff} = claimable_work_request!(repo, "WR-READS-BOUND")
    other = create_work_request!(repo, id: "WR-READS-OTHER", repo: "nextide/other-product", base_branch: "develop", status: "sliced")
    other_packages = for index <- 1..3, do: add_package!(repo, other, "WP-READS-OTHER-#{index}")
    client = connect!(repo, "client-reads-bound")

    assert tool!(client, "upsert_group", %{"work_request_id" => bound.id, "title" => "Claim"}).response["result"]

    read = fn tool, arguments ->
      result = tool!(client, tool, arguments)
      assert result.response["result"], "#{tool}: #{inspect(result.response)}"
      assert result.herdr_binding["work_request_id"] == bound.id
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

    anchor_id = ArchitectHandoff.anchor_id_for_work_request(bound)
    assert tool!(client, "get_current_assignment", %{}).response["result"]["structuredContent"]["assignment"]["work_package_id"] == anchor_id

    # A read neither renews, reclaims nor depends on the claim the session holds.
    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, anchor_id)
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)
    stale = lease |> ClaimLease.update_changeset(%{last_seen_at: stale_seen_at}) |> repo.update!()
    assert read.("read_work_request", %{"work_request_id" => bound.id})["work_request"]["id"] == bound.id
    assert read.("list_work_requests", %{})["work_requests"] |> Enum.map(& &1["id"]) |> Enum.member?(bound.id)
    assert {:ok, after_read} = ClaimLeaseService.current_for_work_package(repo, anchor_id)
    assert {after_read.id, after_read.last_seen_at} == {stale.id, stale_seen_at}

    stale |> ClaimLease.update_changeset(%{last_seen_at: DateTime.utc_now(:microsecond)}) |> repo.update!()
    assert {:ok, _paused} = ClaimLeaseService.pause(repo, stale.id, %{"actor_id" => "operator"}, reason: "operator pause")
    assert read.("read_plan", %{"work_request_id" => other.id})["work_request"]["id"] == other.id
    assert read.("list_work_requests", %{})["work_requests"] |> Enum.map(& &1["id"]) |> Enum.member?(bound.id)
  end

  test "reads and assignment introspection renew only a live claim and never reclaim one", %{repo: repo} do
    {work_request, handoff} = claimable_work_request!(repo, "WR-READS-CLAIM-STATE")
    client = connect!(repo, "client-reads-claim-state")
    assert tool!(client, "upsert_group", %{"work_request_id" => work_request.id, "title" => "Claim"}).response["result"]
    anchor_id = handoff.anchor_package.id

    lease_at = fn seen_at ->
      assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, anchor_id)
      lease |> ClaimLease.update_changeset(%{last_seen_at: seen_at}) |> repo.update!()
    end

    stale = lease_at.(DateTime.add(DateTime.utc_now(:microsecond), -6, :minute))
    assert call!(client, "assignment", "resources/read", %{"uri" => "sympp://assignment/current"}).response["result"]
    assert tool!(client, "get_current_assignment", %{}).response["result"]["structuredContent"]["binding"]["state"] == "stale"
    assert {:ok, unchanged} = ClaimLeaseService.current_for_work_package(repo, anchor_id)
    assert {unchanged.id, unchanged.last_seen_at} == {stale.id, stale.last_seen_at}

    # The next write reclaims; a revoked grant then stops reads from renewing it.
    assert tool!(client, "upsert_group", %{"title" => "Reclaim"}).response["result"]
    due = lease_at.(DateTime.add(DateTime.utc_now(:microsecond), -1, :minute))
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, handoff.grant.id)
    tool!(client, "list_work_requests", %{})
    assert {:ok, %ClaimLease{last_seen_at: last_seen_at}} = ClaimLeaseService.current_for_work_package(repo, anchor_id)
    assert last_seen_at == due.last_seen_at
  end

  defp claimable_work_request!(repo, id) do
    work_request = create_work_request!(repo, id: id, status: "ready_for_slicing")

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: [
                 claimed_by: ArchitectHandoff.claimed_by(),
                 database: repo.database_path(),
                 local_architect_claim?: true
               ]
             )

    {work_request, handoff}
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

  defp tool!(client, name, arguments), do: call!(client, name, "tools/call", %{"name" => name, "arguments" => arguments})

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
