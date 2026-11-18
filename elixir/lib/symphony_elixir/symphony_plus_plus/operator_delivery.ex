defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDelivery do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, WorkRequest}

  @text_escapes %{"&" => "&amp;", "<" => "&lt;", ">" => "&gt;"}
  @attribute_escapes Map.merge(@text_escapes, %{"\"" => "&quot;", "\t" => "&#9;", "\n" => "&#10;", "\r" => "&#13;"})
  # Includes time for the terminal lookup and HerdrCore's send deadline.
  @delivery_window_ms 90_000

  @spec deliver(module(), Ask.t() | DecisionLogEntry.t()) :: :ok | {:error, String.t()}
  def deliver(repo, %Ask{} = ask) do
    message =
      envelope(repo, ask.work_request_id, {"ask", ask.id}, [
        {"Question", ask.question},
        {"Answer", ask.answer},
        {"Status", "Already answered and resolved. No resolve_ask is needed."}
      ])

    HerdrCore.deliver(ask.asked_by_terminal, message)
  end

  def deliver(repo, %DecisionLogEntry{} = decision) do
    message =
      envelope(repo, decision.work_request_id, {"decision", decision.id}, [
        {"Decision", decision.decision},
        {"Feedback", decision.feedback}
      ])

    HerdrCore.deliver(decision.recorded_by_terminal, message)
  end

  @spec interrupted?(DateTime.t()) :: boolean()
  def interrupted?(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond) > @delivery_window_ms
  end

  defp envelope(repo, work_request_id, subject, fields) do
    attributes = [{"from", "operator"}, subject | request_attributes(repo, work_request_id)]
    header = Enum.map_join(attributes, " ", fn {name, value} -> ~s(#{name}="#{escape(value, @attribute_escapes)}") end)
    body = Enum.map_join(fields, "\n", fn {label, value} -> "#{label}: #{escape(value, @text_escapes)}" end)
    "<sympp #{header}>\n#{body}\n</sympp>"
  end

  defp request_attributes(_repo, nil), do: []

  defp request_attributes(repo, id) do
    case repo.get(WorkRequest, id) do
      %WorkRequest{title: title} when is_binary(title) -> [{"work_request", id}, {"title", Redactor.redact_text(title)}]
      _missing_title -> [{"work_request", id}]
    end
  end

  defp escape(text, replacements) do
    String.replace(text, Map.keys(replacements), &Map.fetch!(replacements, &1))
  end

  @spec start(module(), (module() -> term())) :: :ok
  def start(repo, fun) do
    # File-backed delivery owns a connection because Runtime may close the
    # request's repo on return. Memory ledgers belong to their existing pool.
    %{rows: rows} = repo.query!("PRAGMA database_list")
    [_, "main", database] = Enum.find(rows, &(Enum.at(&1, 1) == "main"))
    source = repo.get_dynamic_repo()
    source = if is_atom(source), do: Process.whereis(source), else: source

    {:ok, _pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        run(repo, source, database, fun)
      end)

    :ok
  end

  defp run(repo, source, "", fun) do
    repo.put_dynamic_repo(source)
    fun.(repo)
  end

  defp run(_repo, _source, database, fun) do
    {:ok, pid} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
    Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      GenServer.stop(pid)
    end
  end
end
