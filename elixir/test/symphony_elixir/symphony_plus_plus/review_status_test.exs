defmodule SymphonyElixir.SymphonyPlusPlus.ReviewStatusTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.ReviewStatus

  setup do
    on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_review_command, nil) end)
    :ok
  end

  describe "Review Suite state" do
    test "is read locally on the factory host and with hc exec on other machines" do
      head = "abc123" <> String.duplicate("0", 34)
      done = Jason.encode!(%{"review" => "rvw_read0001", "done" => true, "status" => "done", "head" => head, "reviewed_head" => head, "accepted_head" => head, "progress" => "1/1", "rounds" => 2})
      test_pid = self()

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        send(test_pid, {:command, command, args, timeout})

        case command do
          "python3" -> {:ok, {done, 0}}
          "hc" -> {:ok, {Jason.encode!(%{"code" => 0, "stdout" => Base.encode64(done), "timed_out" => false}), 0}}
        end
      end)

      assert {:ok, review} = ReviewStatus.read("rvw_read0001", nil)
      assert_received {:command, "python3", [_script, "--id", "rvw_read0001", "--show-status", "--json"], timeout}
      assert timeout > 3_000 and timeout <= ReviewStatus.timeout_ms()
      assert %{"done" => true, "reviewed_head" => ^head, "accepted_head" => ^head, "status" => "passed", "current" => 1, "total" => 1, "round" => 2} = review
      assert ReviewStatus.state({:ok, review}, head) == :done
      assert ReviewStatus.state({:ok, review}, "abc123") == :pending
      # Review Suite can keep `done` while reporting the cycle no longer holds.
      for status <- ["stale", "failed", "fix-pending", "invalidated"] do
        stale = Jason.encode!(%{"review" => "rvw_read0001", "done" => true, "status" => status, "accepted_head" => head})
        Application.put_env(:symphony_elixir, :sympp_review_command, fn "python3", _args, _timeout -> {:ok, {stale, 0}} end)
        assert ReviewStatus.state(ReviewStatus.read("rvw_read0001", nil), head) == :pending
      end

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        send(test_pid, {:command, command, args, timeout})

        case command do
          "python3" -> {:ok, {done, 0}}
          "hc" -> {:ok, {Jason.encode!(%{"code" => 0, "stdout" => Base.encode64(done), "timed_out" => false}), 0}}
        end
      end)

      assert {:ok, ^review} = ReviewStatus.read("rvw_read0001", "worker-box") |> then(fn {:ok, remote} -> {:ok, Map.put(remote, "observed_at", review["observed_at"])} end)
      assert_received {:command, "hc", ["exec", "--json", "--on", "worker-box", "--timeout", seconds, "--", "sh", "-c", command, "sh", "rvw_read0001"], timeout}
      assert String.to_float(seconds) == timeout / 1_000
      # The skills install first, else the Codex marketplace plugin.
      assert command =~ ~s("$HOME/.agents/skills/review-suite/plugins/review-suite/scripts/review.py")
      assert command =~ ~s("${CODEX_HOME:-$HOME/.codex}"/plugins/cache/review-suite/review-suite/*/scripts/review.py)
    end
  end

  test "linked reads share the remaining deadline locally and through hc" do
    for machine <- [nil, "worker-box"] do
      Process.put(:review_clock, 0)
      clock = fn -> Process.get(:review_clock) end
      head = String.duplicate("a", 40)
      terminal = %{"review" => "rvw_terminal", "branch" => "worker", "done" => true, "status" => "done", "accepted_head" => head}
      predecessor = Map.merge(terminal, %{"review" => "rvw_start", "superseded_by" => %{"review" => "rvw_terminal"}})

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        id = List.last(args -- ["--show-status", "--json"])
        elapsed = if id == "rvw_start", do: 823, else: 6_200

        inner_ms =
          if command == "hc" do
            {seconds, _} = Float.parse(Enum.at(args, 5))
            round(seconds * 1_000)
          else
            timeout
          end

        assert timeout == 30_000 - clock.()
        assert inner_ms == timeout
        Process.put(:review_clock, clock.() + elapsed)

        if elapsed < min(timeout, inner_ms) do
          payload = if id == "rvw_start", do: predecessor, else: terminal
          answer(command, Jason.encode!(payload))
        else
          :error
        end
      end)

      assert {:ok, review} = ReviewStatus.read("rvw_start", machine, clock: clock)
      assert review["evidence_id"] == "rvw_terminal"
      assert ReviewStatus.state({:ok, review}, head) == :done
      assert ReviewStatus.state({:ok, review}, String.duplicate("b", 40)) == :pending
    end
  end

  test "expired budgets and unusable successors never revive an accepted predecessor" do
    for machine <- [nil, "worker-box"],
        failure <- [:exhausted, :late, :timeout, :remote_timeout, :malformed, :missing, :cycle, :branch, :identity] do
      Process.put(:review_clock, 0)
      clock = fn -> Process.get(:review_clock) end
      head = String.duplicate("a", 40)
      done = %{"review" => "rvw_start", "branch" => "worker", "done" => true, "status" => "done", "accepted_head" => head}
      predecessor = Map.put(done, "superseded_by", %{"review" => "rvw_terminal"})

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        id = List.last(args -- ["--show-status", "--json"])

        if id == "rvw_start" do
          Process.put(:review_clock, if(failure == :exhausted, do: 30_000, else: 823))
          answer(command, Jason.encode!(predecessor))
        else
          assert failure != :exhausted
          assert timeout == 29_177
          terminal = Map.put(done, "review", "rvw_terminal")

          case failure do
            :late ->
              Process.put(:review_clock, 30_001)
              answer(command, Jason.encode!(terminal))

            :timeout ->
              :error

            :remote_timeout ->
              if command == "hc", do: {:ok, {Jason.encode!(%{"code" => 0, "stdout" => Base.encode64(Jason.encode!(terminal)), "timed_out" => true}), 0}}, else: :error

            :malformed ->
              answer(command, "{")

            :missing ->
              answer(command, Jason.encode!(%{"error" => "unknown review cycle id: rvw_terminal"}), 2)

            :cycle ->
              answer(command, Jason.encode!(Map.put(terminal, "superseded_by", %{"review" => "rvw_start"})))

            :branch ->
              answer(command, Jason.encode!(Map.put(terminal, "branch", "another")))

            :identity ->
              answer(command, Jason.encode!(done))
          end
        end
      end)

      result = ReviewStatus.read("rvw_start", machine, clock: clock)
      assert result == if(failure == :missing, do: :not_started, else: :unknown)
      refute ReviewStatus.state(result, head) == :done
    end
  end

  defp answer(command, output, status \\ 0)
  defp answer("python3", output, status), do: {:ok, {output, status}}

  defp answer("hc", output, status) do
    {:ok, {Jason.encode!(%{"code" => status, "stdout" => Base.encode64(output), "timed_out" => false}), 0}}
  end
end
