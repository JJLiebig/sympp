Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.EditPlanTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge

  test "one edit adds grouped packages that depend on each other and returns the plan once", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-ADD")

    response =
      edit_plan(repo, work_request.id, [
        add_op(key: "api", title: "Billing API", group: "Backend/ Billing"),
        add_op(key: "ui", title: "Billing page", group: "Frontend", depends_on: ["api"])
      ])

    assert %{"applied" => [%{"op" => "add_package", "key" => "api", "work_package_id" => api_id}, %{"op" => "add_package", "key" => "ui", "work_package_id" => ui_id}]} =
             structured!(response)

    packages = Map.new(structured!(response)["plan"]["work_packages"], &{&1["id"], &1})

    assert %{"group" => "Backend / Billing", "status" => "planned", "revision" => 1, "depends_on" => [], "next_action" => "dispatch_work_package"} = packages[api_id]
    assert %{"group" => "Frontend", "depends_on" => [^api_id], "next_action" => "deliver_prerequisites"} = packages[ui_id]
    assert assert_toon_tool_text!(response) =~ "Backend / Billing"

    plan = read_plan(repo, work_request.id)
    assert [%{"from" => ^ui_id, "to" => ^api_id}] = plan["dependencies"]
    assert Enum.map(plan["work_packages"], &{&1["id"], &1["group"]}) == [{api_id, "Backend / Billing"}, {ui_id, "Frontend"}]

    secret = edit_plan(repo, work_request.id, [add_op(title: "Token ghp_editplansecretvalue12345", group: "Ops / ghp_editplansecretvalue12345")])
    refute inspect(secret) =~ "ghp_editplansecretvalue12345"
  end

  test "a failing op rolls back the whole edit and names its index, state and next action", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-ATOMIC")
    existing = add_package!(repo, work_request)

    response =
      edit_plan(repo, work_request.id, [
        add_op(key: "new", title: "New package"),
        %{"op" => "set_dependency", "from" => existing.id, "to" => "new"},
        %{"op" => "update_package", "work_package_id" => existing.id, "expected_revision" => 7, "patch" => %{"title" => "Too late"}}
      ])

    assert %{"code" => -32_602, "data" => data} = response["error"]
    assert %{"op_index" => 2, "op" => "update_package", "code" => "revision_conflict", "state" => "planned", "current_revision" => 1} = data
    assert data["next_action"] =~ "expected_revision 1"

    assert [%WorkPackage{id: id, title: title}] = repo.all(from(package in WorkPackage, where: package.work_request_id == ^work_request.id))
    assert {id, title} == {existing.id, existing.title}
    assert repo.all(DependencyEdge) == []
  end

  test "update_package checks the whole contract, bumps the revision and can clear the group", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-UPDATE")
    package = add_package!(repo, work_request, group: "Backend")

    for patch <- [%{"goal" => "  "}, %{"acceptance_criteria" => ["  "]}, %{"validation_steps" => nil}] do
      response = edit_plan(repo, work_request.id, [update_op(package, patch)])
      assert %{"op_index" => 0, "code" => "incomplete_contract", "missing" => [_ | _]} = response["error"]["data"]
    end

    assert %{"error" => %{"data" => %{"code" => "invalid_work_package", "validation_errors" => [%{"field" => "group"}]}}} =
             edit_plan(repo, work_request.id, [update_op(package, %{"group" => "Backend // Billing"})])

    response = edit_plan(repo, work_request.id, [update_op(package, %{"title" => "Renamed", "group" => nil})])
    assert [%{"op" => "update_package", "work_package_id" => _, "revision" => 2}] = structured!(response)["applied"]

    persisted = repo.get!(WorkPackage, package.id)
    assert {persisted.title, persisted.group, persisted.contract_revision} == {"Renamed", nil, 2}

    # A group move alone is a new plan revision.
    moved = repo.get!(WorkPackage, package.id)
    before = read_plan(repo, work_request.id)["latest_revision"]["revision_number"]
    edit_plan!(repo, work_request.id, [update_op(moved, %{"group" => "Frontend"})])
    assert read_plan(repo, work_request.id)["latest_revision"]["revision_number"] == before + 1
  end

  test "a ready package's contract is frozen", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-FROZEN")
    package = add_package!(repo, work_request)
    repo.update_all(from(p in WorkPackage, where: p.id == ^package.id), set: [status: "ready"])

    response = edit_plan(repo, work_request.id, [update_op(package, %{"title" => "Changed"})])

    assert %{"op_index" => 0, "code" => "contract_frozen", "state" => "ready"} = response["error"]["data"]
    assert response["error"]["data"]["next_action"] =~ "superseded"
  end

  test "set_dependency creates the dependency and updates its reason; remove_dependency removes it", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-DEPENDENCY")
    prerequisite = add_package!(repo, work_request, title: "Prerequisite")
    dependent = add_package!(repo, work_request, title: "Dependent")
    pair = %{"from" => dependent.id, "to" => prerequisite.id}

    edit_plan!(repo, work_request.id, [Map.put(pair, "op", "set_dependency")])
    edit_plan!(repo, work_request.id, [Map.merge(pair, %{"op" => "set_dependency", "reason" => "Needs the API."})])
    assert [%DependencyEdge{reason: "Needs the API."}] = repo.all(DependencyEdge)

    edit_plan!(repo, work_request.id, [Map.put(pair, "op", "remove_dependency")])
    assert repo.all(DependencyEdge) == []

    assert %{"op_index" => 0, "code" => "dependency_not_found"} = edit_plan(repo, work_request.id, [Map.put(pair, "op", "remove_dependency")])["error"]["data"]

    assert %{"code" => "unknown_work_package", "work_package_ref" => "nope"} =
             edit_plan(repo, work_request.id, [%{"op" => "set_dependency", "from" => dependent.id, "to" => "nope"}])["error"]["data"]
  end

  test "edit_plan refuses an archived WorkRequest and another terminal's WorkRequest", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-EDIT-PLAN-REFUSED")
    package = add_package!(repo, work_request)
    edit_plan!(repo, work_request.id, [update_op(package, %{"title" => "Owned by t1"})])

    assert %{"code" => "owned_by_other_terminal"} = mcp_tool(repo, "t2", "edit_plan", plan_args(work_request.id, [add_op(title: "Intruder")]))["error"]["data"]

    repo.update_all(from(request in WorkRequest, where: request.id == ^work_request.id), set: [archived_at: DateTime.utc_now(:microsecond), archive_reason: "manual"])

    response = edit_plan(repo, work_request.id, [add_op(title: "Must not persist")])
    assert %{"code" => -32_009, "data" => %{"code" => "work_request_archived", "state" => "archived", "next_action" => "restore"}} = response["error"]
    assert [_only] = repo.all(from(p in WorkPackage, where: p.work_request_id == ^work_request.id))
  end

  defp edit_plan(repo, work_request_id, ops), do: mcp_tool(repo, "t1", "edit_plan", plan_args(work_request_id, ops))

  defp edit_plan!(repo, work_request_id, ops) do
    response = edit_plan(repo, work_request_id, ops)
    structured!(response)
  end

  defp plan_args(work_request_id, ops), do: %{"work_request_id" => work_request_id, "ops" => ops}

  defp read_plan(repo, work_request_id) do
    response = mcp_tool(repo, "t1", "read_work_request", %{"work_request_id" => work_request_id, "view" => "plan"})
    structured!(response)["plan"]
  end

  defp structured!(response) do
    assert %{"structuredContent" => payload} = response["result"], inspect(response)
    payload
  end

  defp add_op(overrides) do
    %{
      "op" => "add_package",
      "title" => "Plan package",
      "goal" => "Deliver one slice.",
      "acceptance_criteria" => ["It works."],
      "validation_steps" => ["mix test"],
      "stop_conditions" => ["Stop on scope change."]
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp update_op(package, patch),
    do: %{"op" => "update_package", "work_package_id" => package.id, "expected_revision" => package.contract_revision, "patch" => patch}

  defp add_package!(repo, work_request, overrides \\ []) do
    assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_request_work_package_attrs([base_branch: work_request.base_branch] ++ overrides))
    package
  end
end
