Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "update_work_package rejects incomplete contracts and persists a valid patch", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-EXPLICIT",
        base_branch: "symphony-plus-plus/beta"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-WR-SLICE-EXPLICIT")
             )

    for patch <- [
          %{"goal" => nil},
          %{"goal" => "  "},
          %{"acceptance_criteria" => ["  "]},
          %{"validation_steps" => nil},
          %{"stop_conditions" => [nil]}
        ] do
      invalid_response =
        mcp_tool(repo, "t1", "update_work_package", %{
          "work_request_id" => work_request.id,
          "work_package_id" => work_package.id,
          "expected_contract_revision" => work_package.contract_revision,
          "patch" => patch
        })

      assert get_in(invalid_response, ["error", "code"]) == -32_602
      assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_work_packages"
    end

    response =
      mcp_tool(repo, "t1", "update_work_package", %{
        "work_package_id" => work_package.id,
        "expected_contract_revision" => work_package.contract_revision,
        "patch" => %{"title" => "Updated explicit package"}
      })

    assert get_in(response, ["result", "structuredContent", "work_package_id"]) == work_package.id,
           inspect(response)

    assert get_in(response, ["result", "structuredContent", "contract_revision"]) == 2
    text = assert_toon_tool_text!(response)
    assert text =~ "work_package_id: #{work_package.id}"
    assert text =~ "contract_revision: 2"

    assert {:ok, persisted_package} = WorkRequestRepository.get_work_package(repo, work_request.id, work_package.id)
    assert persisted_package.title == "Updated explicit package"
  end

  test "WorkRequest MCP work-package mutations refuse an archived parent", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-WR-AUTHORING-STATUS")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WP-MCP-WR-AUTHORING-STATUS")
             )

    repo.update_all(from(request in WorkRequest, where: request.id == ^work_request.id), set: [archived_at: DateTime.utc_now(:microsecond), archive_reason: "manual"])

    update_response =
      mcp_tool(repo, "t1", "update_work_package", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "expected_contract_revision" => work_package.contract_revision,
        "patch" => %{"title" => "Must not persist"}
      })

    assert get_in(update_response, ["error", "code"]) == -32_009
    assert get_in(update_response, ["error", "data", "reason"]) == "work_request_archived"
    assert get_in(update_response, ["error", "data", "recovery", "next_action"]) == "restore"

    skip_response =
      mcp_tool(repo, "t1", "skip_work_package", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id
      })

    assert get_in(skip_response, ["error", "code"]) == -32_009
    assert get_in(skip_response, ["error", "data", "reason"]) == "work_request_archived"
    assert get_in(skip_response, ["error", "data", "recovery", "next_action"]) == "restore"

    persisted = repo.get!(WorkPackage, work_package.id)
    assert persisted.title == work_package.title
    assert persisted.status == "planned"
  end
end
