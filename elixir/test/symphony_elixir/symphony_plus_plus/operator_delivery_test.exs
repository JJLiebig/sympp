defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDeliveryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.{Asks, DashboardPubSub, Repo}
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository

  test "asynchronous answers settle on their original memory ledger" do
    {:ok, pid} = Repo.start_link(database: ":memory:", name: nil, pool_size: 1, log: false)
    Process.unlink(pid)
    previous = Repo.put_dynamic_repo(pid)

    original =
      for key <- [:sympp_herdr_core, :sympp_herdr_send], into: %{} do
        {key, Application.get_env(:symphony_elixir, key)}
      end

    on_exit(fn ->
      Enum.each(original, fn {key, value} -> Application.put_env(:symphony_elixir, key, value) end)
      Repo.put_dynamic_repo(previous)
      GenServer.stop(pid)
    end)

    assert :ok = Repository.migrate(Repo)

    {:ok, request} =
      Repository.create(Repo, %{
        title: "Memory delivery",
        repo: "example/delivery",
        base_branch: "main",
        work_type: "feature",
        human_description: "Keep the answer and its delivery outcome on the same ledger.",
        desired_dispatch_shape: "single_package"
      })

    terminal = %Terminal{key: "memory/t1", core_id: "memory", address: "t1", display_address: "memory/t1", role: "chief"}
    {:ok, ask} = Asks.open(Repo, terminal, %{"work_request_id" => request.id, "question" => "Ship?"})
    caller = self()

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn ->
      {:ok, %{core_id: "memory", terminals: %{"t1" => %{"state" => "live"}}}}
    end)

    Application.put_env(:symphony_elixir, :sympp_herdr_send, fn target, text, mode ->
      send(caller, {:typed, self(), target, text, mode})
      :ok
    end)

    :ok = DashboardPubSub.subscribe()
    assert {:ok, _ask, %{"state" => "pending"}} = Asks.answer_by_operator(Repo, ask.id, %{"answer" => "Yes"}, async: true)
    assert_receive {:typed, sender, "t1", "Answer: Yes", :prefill}
    monitor = Process.monitor(sender)
    assert_receive {:DOWN, ^monitor, :process, ^sender, reason}
    assert reason in [:normal, :noproc]
    assert_receive :operator_dashboard_changed
    assert_receive :operator_dashboard_changed
    stored = Repo.get!(Ask, ask.id)
    assert stored.delivered_at != nil
    assert Asks.delivery_status(stored) == %{"state" => "delivered", "to" => "memory/t1"}
  end
end
