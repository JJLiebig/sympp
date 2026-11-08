defmodule SymphonyElixir.SymphonyPlusPlus.AuditEventTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Timeline
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

  test "terminal actor and trusted agent run are recorded and exposed in the timeline", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               actor("box/t1"),
               work_package.id,
               %{
                 idempotency_key: "progress:actor",
                 summary: "Actor update",
                 agent_run_id: "forged-run-123",
                 payload: %{phase: "implementation"}
               },
               agent_run_id: "trusted-run-123"
             )

    assert event.actor_id == "box/t1"
    assert event.actor_type == "architect"
    assert event.idempotency_scope == "terminal:core/t1"
    assert event.agent_run_id == "trusted-run-123"

    assert {:ok, [timeline_item]} = Timeline.fetch(repo, work_package.id)
    assert timeline_item.actor == %{id: "box/t1", type: "architect"}
    assert timeline_item.agent_run_id == "trusted-run-123"
    assert timeline_item.payload == %{"phase" => "implementation"}
  end

  test "terminal append with idempotency renders one redacted progress event", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    secret = work_key_shaped_secret()

    attrs = %{
      idempotency_key: "progress:terminal-append",
      summary: "Architect wrote progress",
      body: "Append completed.",
      payload: %{
        safe: "visible",
        claim_secret: secret,
        nested: %{authorization: "Bearer raw"}
      }
    }

    assert {:ok, first} = PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, attrs)
    assert {:ok, second} = PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, attrs)
    assert first.id == second.id
    assert repo.aggregate(ProgressEvent, :count) == 1

    assert first.payload == %{
             "safe" => "visible",
             "claim_secret" => "[REDACTED]",
             "nested" => %{"authorization" => "[REDACTED]"}
           }

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")
    assert progress_markdown =~ "Architect wrote progress"
    assert progress_markdown =~ "box/t1"
    refute progress_markdown =~ "[REDACTED]"
    refute progress_markdown =~ secret
    refute inspect(first.payload) =~ secret
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

  test "direct progress append also bounds stored payloads", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-bounded-payload",
               summary: "Direct bounded payload",
               payload: %{
                 long_text: String.duplicate("b", 5_000),
                 long_list: Enum.to_list(1..120),
                 struct_payload: %SecretPayload{large_blob: String.duplicate("c", 5_000), safe: "visible"}
               }
             })

    assert String.length(event.payload["long_text"]) < 4_100
    assert event.payload["long_text"] =~ "[truncated]"
    assert length(event.payload["long_list"]) == 101
    assert List.last(event.payload["long_list"]) == "[truncated]"
    assert event.payload["struct_payload"]["large_blob"] =~ "[truncated]"
    assert event.payload["struct_payload"]["safe"] == "visible"
  end

  test "progress payload storage and rendering are JSON-safe without dropping colliding keys", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:json-safe",
               summary: "JSON-safe payload",
               payload: %{
                 :secret => "raw-atom-secret",
                 "secret" => "raw-string-secret",
                 :Secret => "raw-capital-atom-secret",
                 "Secret" => "raw-capital-string-secret",
                 "x-api-key" => "raw-hyphen-api-key",
                 "x_api_key" => "raw-underscore-api-key",
                 {:tuple, :key} => "tuple-value",
                 "{:tuple, :key}" => "string-tuple-value",
                 1 => "integer-value",
                 "1" => "string-integer-value",
                 :created_at => ~U[2026-05-01 10:00:00Z],
                 :date => ~D[2026-05-01],
                 :naive_datetime => ~N[2026-05-01 10:01:02],
                 :time => ~T[10:01:02],
                 :headers => [{"authorization", "raw-header-token"}]
               }
             })

    assert event.payload ==
             %{
               ":secret" => "[REDACTED]",
               "secret" => "[REDACTED]",
               ":Secret" => "[REDACTED]",
               "Secret" => "[REDACTED]",
               "x-api-key" => "[REDACTED]",
               "x_api_key" => "[REDACTED]",
               "created_at" => "2026-05-01T10:00:00Z",
               "date" => "2026-05-01",
               "naive_datetime" => "2026-05-01T10:01:02",
               "time" => "10:01:02",
               "headers" => [["authorization", "[REDACTED]"]]
             }
             |> Map.merge(Map.take(event.payload, ["{:tuple, :key}", "\"{:tuple, :key}\"", "{:tuple, :key}#2", "1", "\"1\"", "1#2"]))

    assert map_size(event.payload) == 15
    assert Enum.count(Map.values(event.payload), &(&1 == "tuple-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "string-tuple-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "integer-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "string-integer-value")) == 1

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")

    refute progress_markdown =~ "\"created_at\": \"2026-05-01T10:00:00Z\""
    refute progress_markdown =~ "\":secret\": \"[REDACTED]\""
    refute progress_markdown =~ "raw-atom-secret"
    refute progress_markdown =~ "raw-string-secret"
    refute progress_markdown =~ "raw-capital-atom-secret"
    refute progress_markdown =~ "raw-capital-string-secret"
    refute progress_markdown =~ "raw-hyphen-api-key"
    refute progress_markdown =~ "raw-underscore-api-key"
    refute progress_markdown =~ "raw-header-token"
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

  test "direct and terminal idempotency keys have separate scopes", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, audit_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, %{
               idempotency_key: "progress:shared-key",
               summary: "Terminal"
             })

    assert {:ok, direct_event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:shared-key",
               summary: "Direct",
               payload: %{system: "visible"}
             })

    assert audit_event.id != direct_event.id
    assert direct_event.idempotency_scope == "direct"

    assert {:ok, replayed_audit_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, %{
               idempotency_key: "progress:shared-key",
               summary: "Terminal replay"
             })

    assert replayed_audit_event.id == audit_event.id
    assert repo.aggregate(ProgressEvent, :count) == 2
  end

  test "a replay from the same terminal under another role conflicts", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    attrs = %{idempotency_key: "progress:role-replay", summary: "As architect"}

    assert {:ok, _event} = PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1"), work_package.id, attrs)

    assert {:error, :idempotency_scope_conflict} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, actor("box/t1", "chief"), work_package.id, attrs)

    assert repo.aggregate(ProgressEvent, :count) == 1
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
