Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport07Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport}

  test "embedded architect batches recover stale ownership", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-HTTP-STABLE-ARCHITECT-CATALOG"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: [
                 claimed_by: ArchitectHandoff.claimed_by(),
                 database: repo.database_path(),
                 local_architect_claim?: true
               ]
             )

    config = %{local_mcp_config(repo) | surface_profile: :architect}
    client_key = "client-http-stable-architect-catalog"

    {:ok, init_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "init-stable-architect", "method" => "initialize", "params" => initialize_params()},
        client_key: client_key
      )

    state_key = init_result.state_key

    slice_arguments = %{
      "work_packages" => [
        %{
          "title" => "Stable catalog regression",
          "goal" => "Prove claim authorizes the startup catalog.",
          "kind" => "mcp",
          "allowed_file_globs" => ["elixir/lib/**"],
          "acceptance_criteria" => ["Slice succeeds without another tools/list."],
          "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp/claim_session_transport_07_test.exs"],
          "stop_conditions" => ["Stop after the regression proves the flow."]
        }
      ]
    }

    slice =
      http!(config, client_key, state_key, "slice-without-relist", "tools/call", %{
        "name" => "slice_work_request",
        "arguments" => Map.put(slice_arguments, "work_request_id", work_request.id)
      })

    assert [_work_package_id] = get_in(slice.response, ["result", "structuredContent", "work_package_ids"])

    assert {:ok, rebound} =
             HTTPTransport.handle(
               config,
               [
                 %{"jsonrpc" => "2.0", "id" => "release-before-auto-claim", "method" => "tools/call", "params" => %{"name" => "release_current_assignment", "arguments" => %{}}},
                 %{
                   "jsonrpc" => "2.0",
                   "id" => "batch-auto-claim",
                   "method" => "tools/call",
                   "params" => %{"name" => "upsert_group", "arguments" => %{"work_request_id" => work_request.id, "title" => "Batch claim"}}
                 }
               ],
               client_key: client_key,
               state_key: state_key
             )

    assert is_binary(get_in(Enum.at(rebound.response, 1), ["result", "structuredContent", "group", "id"]))
    HTTPStateStore.reset!()
    recovered = http!(config, client_key, state_key, "batch-binding-recovered", "tools/call", %{"name" => "upsert_group", "arguments" => %{"title" => "Recovered binding"}})
    assert is_binary(get_in(recovered.response, ["result", "structuredContent", "group", "id"]))
    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    assert {:ok, competing_init} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => "competing-init", "method" => "initialize", "params" => initialize_params()},
               client_key: "competing-architect"
             )

    write_params = %{"name" => "upsert_group", "arguments" => %{"work_request_id" => work_request.id, "title" => "Contended claim"}}

    conflict = http!(config, "competing-architect", competing_init.state_key, "live-owner", "tools/call", write_params)
    assert get_in(conflict.response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert {:ok, unchanged_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert unchanged_lease == lease

    lease
    |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)})
    |> repo.update!()

    reclaimed = http!(config, "competing-architect", competing_init.state_key, "stale-owner", "tools/call", write_params)
    assert is_binary(get_in(reclaimed.response, ["result", "structuredContent", "group", "id"]))
    assert {:ok, replacement} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    refute replacement.id == lease.id
    refute replacement.actor_id == lease.actor_id

    HTTPStateStore.reset!()
    omitted_scope_params = %{"name" => "upsert_group", "arguments" => %{"title" => "Known scope"}}
    recovered_conflict = http!(config, client_key, state_key, "known-scope-live-owner", "tools/call", omitted_scope_params)
    assert get_in(recovered_conflict.response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"

    replacement
    |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)})
    |> repo.update!()

    recovered_owner = http!(config, client_key, state_key, "known-scope-expired-owner", "tools/call", omitted_scope_params)
    assert is_binary(get_in(recovered_owner.response, ["result", "structuredContent", "group", "id"]))
    assert {:ok, current_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert current_lease.actor_display_name == lease.actor_display_name

    assert 1 == repo.aggregate(from(package in WorkPackage, where: package.work_request_id == ^work_request.id and package.id != ^handoff.anchor_package.id), :count)
  end

  defp http!(config, client_key, state_key, id, method, params) do
    assert {:ok, result} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
               client_key: client_key,
               state_key: state_key
             )

    result
  end
end
