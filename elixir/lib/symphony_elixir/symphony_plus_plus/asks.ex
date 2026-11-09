defmodule SymphonyElixir.SymphonyPlusPlus.Asks do
  @moduledoc """
  Asks: the only source of "Needs you".

  | From | Event | To | Actor |
  |---|---|---|---|
  | — | `open` | open | any Herdr terminal, attributed to it |
  | open | `answer` | answered | the operator over HTTP (the answer is delivered to the asking terminal), or the asker or WorkRequest owner recording a conversational answer |
  | open | `withdraw` | withdrawn | the asker or WorkRequest owner; also automatic when the package it names ends or the WorkRequest is archived |

  An answer or withdrawal may record one decision in the same transaction.
  Asks never block planning, slicing or dispatch, and never change a phase.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, HumanDecisionPrompt, Id, Ownership}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Phase, WorkRequest}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @type repo :: module()
  @type delivery :: %{required(String.t()) => String.t()}

  @doc "Opens an ask on a WorkRequest, optionally naming one of its packages."
  @spec open(repo(), Terminal.t(), map()) :: {:ok, Ask.t()} | {:error, term()}
  def open(repo, %Terminal{} = terminal, attrs) when is_map(attrs) do
    with {:ok, question} <- text(attrs["question"], :invalid_question),
         {:ok, prompt} <- decision_prompt(attrs["decision_prompt"]) do
      repo
      |> transact(fn -> insert(repo, terminal, attrs["work_request_id"], attrs["work_package_id"], question, prompt) end)
      |> DashboardPubSub.broadcast_changed_on_success()
    end
  end

  defp insert(repo, terminal, work_request_id, work_package_id, question, prompt) do
    with {:ok, %WorkRequest{} = work_request} <- fetch(repo, WorkRequest, work_request_id),
         :ok <- Phase.require_writable(work_request),
         :ok <- require_not_completed(work_request),
         :ok <- require_open_package(repo, work_request.id, work_package_id) do
      now = DateTime.utc_now(:microsecond)

      {:ok,
       repo.insert!(%Ask{
         id: Id.random("ask"),
         work_request_id: work_request.id,
         work_package_id: work_package_id,
         question: question,
         decision_prompt: prompt,
         state: "open",
         asked_by_terminal: terminal.key,
         asked_by_address: terminal.display_address,
         inserted_at: now,
         updated_at: now
       })}
    end
  end

  # Operator completion withdrew the WorkRequest's asks; it takes no new ones.
  defp require_not_completed(%WorkRequest{operator_completed_at: %DateTime{}}), do: {:error, :work_request_completed}
  defp require_not_completed(%WorkRequest{}), do: :ok

  defp require_open_package(_repo, _work_request_id, nil), do: :ok

  defp require_open_package(repo, work_request_id, work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{work_request_id: ^work_request_id, status: "ended"} -> {:error, :work_package_ended}
      %WorkPackage{work_request_id: ^work_request_id} -> :ok
      _other -> {:error, :not_found}
    end
  end

  @doc """
  The asker or the WorkRequest owner records a conversational answer
  (`to: "answered"`) or withdraws the ask (`to: "withdrawn"`), optionally with
  one decision recorded in the same transaction.
  """
  @spec resolve(repo(), Terminal.t(), String.t(), String.t(), String.t() | nil, map() | nil) ::
          {:ok, Ask.t(), map() | nil} | {:error, term()}
  def resolve(repo, %Terminal{} = terminal, ask_id, to, answer, decision) when to in ["answered", "withdrawn"] do
    with {:ok, answer} <- resolution_answer(to, answer),
         {:ok, {ask, decision}} <-
           repo
           |> transact(fn -> resolve_in_transaction(repo, terminal, ask_id, to, answer, decision) end)
           |> DashboardPubSub.broadcast_changed_on_success() do
      {:ok, ask, decision}
    end
  end

  def resolve(_repo, %Terminal{}, _ask_id, _to, _answer, _decision), do: {:error, :invalid_to}

  defp resolve_in_transaction(repo, terminal, ask_id, to, answer, decision) do
    with {:ok, ask} <- fetch_open(repo, ask_id),
         :ok <- require_asker_or_owner(repo, ask, terminal),
         {:ok, ask} <- close(repo, ask, to, answer, terminal.display_address),
         {:ok, decision} <- record_decision(repo, ask, decision, terminal.display_address) do
      {:ok, {ask, decision}}
    end
  end

  defp resolution_answer("answered", answer), do: text(answer, :missing_answer)
  defp resolution_answer("withdrawn", nil), do: {:ok, nil}
  defp resolution_answer("withdrawn", answer), do: text(answer, :invalid_answer)

  defp require_asker_or_owner(repo, %Ask{} = ask, %Terminal{key: key}) do
    cond do
      ask.asked_by_terminal == key -> :ok
      match?(%WorkedOn{terminal_key: ^key}, Ownership.owner(repo, ask.work_request_id)) -> :ok
      true -> {:error, {:not_asker_or_owner, ask}}
    end
  end

  @doc """
  The operator answers an open ask. With a decision prompt the answer is the
  chosen option (and note); otherwise free text. The answer is then delivered
  to the asking terminal's input without submitting it.
  """
  @spec answer_by_operator(repo(), String.t(), map()) :: {:ok, Ask.t(), delivery()} | {:error, term()}
  def answer_by_operator(repo, ask_id, params) when is_map(params) do
    repo
    |> transact(fn ->
      with {:ok, ask} <- fetch_open(repo, ask_id),
           {:ok, answer} <- HumanDecisionPrompt.answer_text_result(ask.decision_prompt, params),
           {:ok, answer} <- text(answer, :missing_answer) do
        close(repo, ask, "answered", answer, "operator")
      end
    end)
    |> DashboardPubSub.broadcast_changed_on_success()
    |> case do
      {:ok, ask} -> deliver(repo, ask)
      error -> error
    end
  end

  # The factory types `Answer: …` into the asking terminal's composer without
  # pressing Enter, so the agent sees it on its next turn and a person can
  # still edit it. A finished or unknown terminal keeps the answer on the ask.
  defp deliver(_repo, %Ask{asked_by_terminal: nil} = ask), do: {:ok, ask, %{"state" => "not_delivered", "reason" => "no_asking_terminal"}}

  defp deliver(repo, %Ask{} = ask) do
    case delivery_target(ask) do
      {:ok, target} ->
        if HerdrCore.paste(target, "Answer: " <> ask.answer) == :ok do
          now = DateTime.utc_now(:microsecond)
          repo.update_all(from(row in Ask, where: row.id == ^ask.id), set: [delivered_at: now, updated_at: now])
          {:ok, %{ask | delivered_at: now}, %{"state" => "delivered", "to" => ask.asked_by_address}}
        else
          {:ok, ask, %{"state" => "not_delivered", "reason" => "send_failed"}}
        end

      {:error, reason} ->
        {:ok, ask, %{"state" => "not_delivered", "reason" => reason}}
    end
  end

  # Answers are typed only into a terminal the factory's own herdr-core sees
  # live. Herdr machine names are local aliases, so a terminal on another core
  # can't be addressed safely from here; its answer stays on the ask.
  defp delivery_target(%Ask{asked_by_terminal: key}) do
    case Terminal.split_key(key) do
      {core_id, terminal} -> target_in_view(HerdrCore.view(core_id, terminal, confirm: true), terminal)
      :error -> {:error, "terminal_unreachable"}
    end
  end

  defp target_in_view({:live, _record}, terminal), do: {:ok, terminal}
  defp target_in_view(:finished, _terminal), do: {:error, "terminal_finished"}
  defp target_in_view(_unseen_or_unknown, _terminal), do: {:error, "terminal_unreachable"}

  @doc "Withdraws the open asks that name these packages, which have just ended. Joins the caller's transaction."
  @spec withdraw_for_packages(repo(), [String.t()]) :: :ok
  def withdraw_for_packages(_repo, []), do: :ok

  def withdraw_for_packages(repo, work_package_ids) do
    withdraw_all(repo, from(ask in Ask, where: ask.work_package_id in ^work_package_ids))
  end

  @doc "Withdraws every open ask on WorkRequests that were archived or operator-completed. Joins the caller's transaction."
  @spec withdraw_for_work_requests(repo(), [String.t()]) :: :ok
  def withdraw_for_work_requests(_repo, []), do: :ok

  def withdraw_for_work_requests(repo, work_request_ids) do
    withdraw_all(repo, from(ask in Ask, where: ask.work_request_id in ^work_request_ids))
  end

  defp withdraw_all(repo, query) do
    now = DateTime.utc_now(:microsecond)
    repo.update_all(from(ask in query, where: ask.state == "open"), set: [state: "withdrawn", answered_by: "subject_ended", resolved_at: now, updated_at: now])
    :ok
  end

  @doc "Asks on these WorkRequests, open first, then newest first, keyed by WorkRequest id."
  @spec by_work_request(repo(), [String.t()]) :: %{String.t() => [Ask.t()]}
  def by_work_request(_repo, []), do: %{}

  def by_work_request(repo, work_request_ids) do
    work_request_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(&repo.all(from(ask in Ask, where: ask.work_request_id in ^&1, order_by: [desc: ask.inserted_at, desc: ask.id])))
    |> Enum.sort_by(&(&1.state != "open"))
    |> Enum.group_by(& &1.work_request_id)
  end

  @doc "How many open asks each WorkRequest has; WorkRequests with none are left out."
  @spec open_counts(repo(), [String.t()]) :: %{String.t() => pos_integer()}
  def open_counts(_repo, []), do: %{}

  def open_counts(repo, work_request_ids) do
    work_request_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids ->
      repo.all(
        from(ask in Ask,
          where: ask.work_request_id in ^ids and ask.state == "open",
          group_by: ask.work_request_id,
          select: {ask.work_request_id, count(ask.id)}
        )
      )
    end)
    |> Map.new()
  end

  @doc "An ask as MCP and the boards show it."
  @spec public(Ask.t()) :: map()
  def public(%Ask{} = ask) do
    %{
      "id" => ask.id,
      "work_request_id" => ask.work_request_id,
      "work_package_id" => ask.work_package_id,
      "question" => Redactor.redact_text(ask.question),
      "decision_prompt" => Redactor.redact_output(ask.decision_prompt),
      "state" => ask.state,
      "asked_by" => ask.asked_by_address,
      "asked_at" => iso(ask.inserted_at),
      "answer" => Redactor.redact_text(ask.answer),
      "answered_by" => ask.answered_by,
      "resolved_at" => iso(ask.resolved_at),
      "delivered_at" => iso(ask.delivered_at)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp close(repo, %Ask{} = ask, to, answer, by) do
    now = DateTime.utc_now(:microsecond)
    {:ok, repo.update!(Ecto.Changeset.change(ask, state: to, answer: answer, answered_by: by, resolved_at: now, updated_at: now))}
  end

  defp record_decision(_repo, _ask, nil, _by), do: {:ok, nil}

  defp record_decision(repo, %Ask{} = ask, decision, by) when is_map(decision) do
    attrs =
      decision
      |> Map.take(["decision", "rationale", "scope_impact", "source_type"])
      |> Map.merge(%{"source_id" => ask.id, "created_by" => by})

    WorkRequestRepository.record_decision(repo, ask.work_request_id, attrs)
  end

  defp record_decision(_repo, _ask, _decision, _by), do: {:error, :invalid_decision}

  defp fetch_open(repo, ask_id) do
    with {:ok, %Ask{} = ask} <- fetch(repo, Ask, ask_id),
         :ok <- require_writable_request(repo, ask.work_request_id) do
      if ask.state == "open", do: {:ok, ask}, else: {:error, {:ask_not_open, ask.state}}
    end
  end

  defp require_writable_request(repo, work_request_id) do
    case repo.get(WorkRequest, work_request_id) do
      %WorkRequest{} = work_request -> Phase.require_writable(work_request)
      nil -> {:error, :not_found}
    end
  end

  defp fetch(repo, schema, id) when is_binary(id) do
    case repo.get(schema, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp fetch(_repo, _schema, _id), do: {:error, :not_found}

  defp text(value, reason) when is_binary(value) do
    case value |> String.trim() |> Redactor.redact_text() do
      "" -> {:error, reason}
      text -> {:ok, text}
    end
  end

  defp text(_value, reason), do: {:error, reason}

  defp decision_prompt(nil), do: {:ok, nil}

  defp decision_prompt(prompt) do
    case HumanDecisionPrompt.normalize(prompt) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_decision_prompt, HumanDecisionPrompt.error_message(reason)}}
    end
  end

  # `fun` returns `{:ok, value}` or `{:error, reason}`; an error rolls back
  # everything the transaction wrote.
  defp transact(repo, fun) do
    repo.transaction(
      fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
