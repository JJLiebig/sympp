defmodule SymphonyElixir.SymphonyPlusPlus.PlanningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(PlanNode)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "allocates append sequence uniquely during concurrent artifacts", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Service.append_artifact(repo, %{
            work_package_id: work_package.id,
            path: "artifact-#{index}.md",
            title: "Artifact #{index}"
          })
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Artifact{}}, &1))

    sequences =
      results
      |> Enum.map(fn {:ok, artifact} -> artifact.sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..8)
  end

  defp create_work_package(repo, overrides \\ []) do
    attrs =
      Keyword.merge([id: "SYMPP-P1-004", kind: "mcp"], overrides)
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end
end
