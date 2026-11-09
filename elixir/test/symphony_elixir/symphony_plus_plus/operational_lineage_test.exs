defmodule SymphonyElixir.SymphonyPlusPlus.OperationalLineageTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "redacts token-like reason text before persisting lineage events", %{repo: repo} do
    source = create_package!(repo, id: "SYMPP-LINEAGE-REDACT-SOURCE")
    target = create_package!(repo, id: "SYMPP-LINEAGE-REDACT-TARGET")

    assert {:ok, relationship} =
             OperationalLineage.record_recut_as(repo, source.id, target.id, %{
               reason: "Recut after operator pasted sk-12345678 in context.",
               decision: %{work_request_id: "wr-redact", decision_id: "decision-redact"}
             })

    assert relationship.reason == "Recut after operator pasted [REDACTED] in context."
    assert [%ProgressEvent{payload: %{"reason" => persisted_reason}}] = repo.all(ProgressEvent)
    assert persisted_reason == "Recut after operator pasted [REDACTED] in context."
  end

  defp create_package!(repo, overrides) do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 Keyword.merge(
                   [
                     kind: "mcp",
                     title: "Lineage package",
                     repo: "sympp",
                     base_branch: "main",
                     status: "dispatched",
                     policy_template: "mcp"
                   ],
                   overrides
                 )
               )
             )

    work_package
  end
end
