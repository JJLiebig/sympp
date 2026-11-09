defmodule SymphonyElixir.SymphonyPlusPlus.PlanningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
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

  test "caps rendered append-only history with an omission notice", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    for index <- 1..105 do
      assert {:ok, _event} = append_event(repo, work_package.id, index, "Body #{index}")
    end

    assert {:ok, progress} = Renderer.render(repo, work_package.id, "progress.md")

    assert progress =~ "_5 older progress events omitted from this virtual file._"
    refute progress =~ "source: `Event 1`\n\n- Status"
    assert progress =~ "source: `Event 6`"
    assert progress =~ "source: `Event 105`"

    assert {:ok, state} = Service.get_state(repo, work_package.id)
    assert length(state.progress_events) == 105
    assert state.progress_events_omitted_count == 0

    assert {:ok, rendered_from_full_state} = Renderer.render_state(state, "progress.md")
    assert rendered_from_full_state =~ "_5 older progress events omitted from this virtual file._"
    refute rendered_from_full_state =~ "source: `Event 1`\n\n- Status"
    assert rendered_from_full_state =~ "source: `Event 105`"
  end

  test "canonical state is not silently render-capped", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    for index <- 1..105 do
      assert {:ok, _node} =
               Service.append_plan_node(repo, %{
                 work_package_id: work_package.id,
                 title: "Plan #{index}"
               })
    end

    assert {:ok, state} = Service.get_state(repo, work_package.id)
    assert length(state.plan_nodes) == 105
    assert state.plan_nodes_omitted_count == 0
  end

  test "caps aggregate rendered virtual file size", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    large_body = String.duplicate("x", 4_050)

    for index <- 1..105 do
      assert {:ok, _event} = append_event(repo, work_package.id, index, large_body)
    end

    assert {:ok, progress} = Renderer.render(repo, work_package.id, "progress.md")

    assert String.length(progress) < 125_000
    assert progress =~ "[virtual file truncated]"
    assert progress =~ "[virtual file truncated]\n\n## "
    assert progress =~ "source: `Event 105`"
    refute progress =~ "source: `Event 6`"
    assert progress |> fenced_source_count() |> rem(2) == 0
  end

  test "normalizes duplicate planning ids", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    attrs = %{id: "artifact-duplicate", work_package_id: work_package.id, path: "first.md", title: "Duplicate"}

    assert {:ok, _artifact} = Service.append_artifact(repo, attrs)
    assert {:error, :id_already_exists} = Service.append_artifact(repo, Map.put(attrs, :path, "second.md"))
  end

  defp append_event(repo, work_package_id, index, body) do
    Service.append_progress_event(repo, %{
      work_package_id: work_package_id,
      summary: "Event #{index}",
      body: body,
      status: "recorded",
      idempotency_key: "event-#{index}"
    })
  end

  defp create_work_package(repo, overrides \\ []) do
    attrs =
      Keyword.merge([id: "SYMPP-P1-004", kind: "mcp"], overrides)
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end

  defp fenced_source_count(markdown), do: length(Regex.scan(~r/^```(?:text)?$/m, markdown))
end
