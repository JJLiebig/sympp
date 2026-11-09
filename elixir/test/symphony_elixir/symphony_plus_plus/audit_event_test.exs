defmodule SymphonyElixir.SymphonyPlusPlus.AuditEventTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule SecretPayload do
    defstruct [:access_token, :large_blob, :safe]
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = PlanningRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "progress rendering redacts secret-shaped source text", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    secret = work_key_shaped_secret()
    fine_grained_pat = "github_pat_" <> Base.encode16(:crypto.strong_rand_bytes(18), case: :lower)
    query_password = "pw-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    assert {:ok, _event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:secret-shaped-source",
               summary: "Worker pasted #{secret} and #{fine_grained_pat} then kept going",
               body: "See https://example.test/download?sig=#{secret}&page=1 then https://example.test/issues/1?w=1 and https://example.test/login?password=#{query_password}&page=1",
               status: "working"
             })

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")

    assert progress_markdown =~ "[REDACTED]"
    assert progress_markdown =~ "Worker pasted [REDACTED] and [REDACTED] then kept going"

    assert progress_markdown =~
             "See https://example.test/download?sig=[REDACTED]&page=1 then https://example.test/issues/1?w=1 and https://example.test/login?password=[REDACTED]&page=1"

    refute progress_markdown =~ secret
    refute progress_markdown =~ fine_grained_pat
    refute progress_markdown =~ query_password
  end

  test "progress rendering escapes audit metadata" do
    state = %State{
      progress_events: [
        %ProgressEvent{
          id: "progress-render",
          work_package_id: "SYMPP-P1-005",
          summary: "Raw append",
          status: "recorded",
          sequence: 1,
          actor_id: "worker-render",
          actor_type: "`worker`\n# actor",
          agent_run_id: "`run`\n# injected",
          payload: %{},
          created_at: ~U[2026-05-01 10:00:00Z]
        }
      ],
      progress_events_omitted_count: 0
    }

    assert {:ok, progress_markdown} = Renderer.render_state(state, "progress.md")

    assert progress_markdown =~ "Actor: source:"
    assert progress_markdown =~ "`` `worker` # actor ``"
    refute progress_markdown =~ "Agent run:"
    refute progress_markdown =~ "`` `run` # injected ``"
    refute progress_markdown =~ "\n# injected"
    refute progress_markdown =~ "\n# actor"
  end

  test "idempotency keys are scoped to each terminal", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, first_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, %{
               idempotency_key: "progress:terminal-scoped",
               summary: "Terminal scoped",
               payload: %{terminal: "one"}
             })

    assert {:ok, second_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t2"), work_package.id, %{
               idempotency_key: "progress:terminal-scoped",
               summary: "Other terminal",
               status: "blocked",
               payload: %{terminal: "two"}
             })

    assert first_event.id != second_event.id
    assert repo.aggregate(ProgressEvent, :count) == 2
    assert first_event.idempotency_scope == "terminal:core/t1"
    assert second_event.idempotency_scope == "terminal:core/t2"
  end

  test "direct progress append does not persist caller supplied provenance", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-provenance",
               summary: "Direct provenance",
               actor_id: "forged-worker",
               actor_type: "architect",
               idempotency_scope: "terminal:forged",
               agent_run_id: "forged-run"
             })

    assert event.actor_id == nil
    assert event.actor_type == nil
    assert event.idempotency_scope == "direct"
    assert event.agent_run_id == nil

    assert {:ok, replayed_event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-provenance",
               summary: "Direct provenance replay",
               idempotency_scope: "terminal:forged"
             })

    assert replayed_event.id == event.id
    assert repo.aggregate(ProgressEvent, :count) == 1
  end

  defp actor(address, type \\ "architect") do
    [_core_name, terminal] = String.split(address, "/")
    %Actor{id: address, type: type, idempotency_scope: "terminal:core/" <> terminal}
  end

  defp work_key_shaped_secret, do: "wk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp create_work_package(repo, overrides \\ []) do
    attrs =
      Keyword.merge([id: "SYMPP-P1-005", kind: "mcp"], overrides)
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end
end
