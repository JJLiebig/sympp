defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionFeedback do
  @moduledoc """
  Operator review of flagged decisions.

  | From | Event | To | Actor |
  |---|---|---|---|
  | — | `record_decision(flag: false)` | (not flagged) | any Herdr terminal |
  | — | `record_decision(flag: true)` | `recorded` | any Herdr terminal, attributed to it |
  | recorded | `ack` | `acknowledged` | operator (HTTP) |
  | recorded | `feedback(text)` | `feedback` | operator (HTTP); the factory types `Decision feedback: <text>` into the recording terminal |

  Feedback that can't be typed into the recording terminal stays on the
  decision with its reason in `undelivered_reason`. The operator's `dismiss`
  clears that marker; the feedback text stays. Every other event is refused
  with the current state and the next action.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, Phase, WorkRequest}

  @type repo :: module()
  @type delivery :: %{required(String.t()) => String.t()}
  @type refusal :: {:decision_transition_refused, String.t(), String.t()}

  @doc "The review fields `record_decision` stores: a flagged decision starts `recorded`."
  @spec record_attrs(boolean()) :: map()
  def record_attrs(true), do: %{"flagged" => true, "review_state" => "recorded"}
  def record_attrs(false), do: %{"flagged" => false}

  @doc "Acknowledges a recorded decision."
  @spec ack(repo(), String.t()) :: {:ok, DecisionLogEntry.t()} | {:error, refusal() | term()}
  def ack(repo, decision_id), do: review_recorded(repo, decision_id, review_state: "acknowledged")

  @doc """
  Records the operator's feedback on a recorded decision, then types
  `Decision feedback: <text>` into the recording terminal without submitting
  it. `delivery` says whether that reached the terminal.
  """
  @spec feedback(repo(), String.t(), term()) :: {:ok, DecisionLogEntry.t(), delivery()} | {:error, refusal() | term()}
  def feedback(repo, decision_id, text) do
    with {:ok, text} <- feedback_text(text),
         {:ok, decision} <- review_recorded(repo, decision_id, review_state: "feedback", feedback: text) do
      deliver(repo, decision)
    end
  end

  @doc "Clears the undelivered marker on feedback. The feedback text stays."
  @spec dismiss(repo(), String.t()) :: {:ok, DecisionLogEntry.t()} | {:error, refusal() | term()}
  def dismiss(repo, decision_id) do
    repo
    |> transact(fn -> clear_undelivered(repo, decision_id) end)
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  @doc "The review state, or `not_flagged`."
  @spec state(DecisionLogEntry.t()) :: String.t()
  def state(%DecisionLogEntry{flagged: true, review_state: state}) when is_binary(state), do: state
  def state(%DecisionLogEntry{}), do: "not_flagged"

  @doc "What the operator can do next with this decision."
  @spec next_action(DecisionLogEntry.t()) :: String.t()
  def next_action(%DecisionLogEntry{} = decision) do
    case {state(decision), decision.undelivered_reason} do
      {"recorded", _reason} -> "ack or feedback"
      {"feedback", reason} when is_binary(reason) -> "dismiss"
      {"not_flagged", _reason} -> "none: only flagged decisions are reviewed"
      _done -> "none"
    end
  end

  @doc """
  Flagged decisions that need the operator, keyed by WorkRequest id: recorded
  ones, and feedback that wasn't delivered. Oldest first.
  """
  @spec to_review(repo(), [String.t()]) :: %{String.t() => [DecisionLogEntry.t()]}
  def to_review(_repo, []), do: %{}

  def to_review(repo, work_request_ids) do
    work_request_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids ->
      repo.all(
        from(decision in DecisionLogEntry,
          where:
            decision.work_request_id in ^ids and decision.flagged and
              (decision.review_state == "recorded" or not is_nil(decision.undelivered_reason)),
          order_by: [asc: decision.sequence, asc: decision.id]
        )
      )
    end)
    |> Enum.group_by(& &1.work_request_id)
  end

  @doc "A flagged decision as the boards show it for review."
  @spec board_entry(DecisionLogEntry.t()) :: map()
  def board_entry(%DecisionLogEntry{} = decision) do
    %{
      id: decision.id,
      work_request_id: decision.work_request_id,
      decision: Redactor.redact_text(decision.decision),
      rationale: Redactor.redact_text(decision.rationale),
      scope_impact: Redactor.redact_text(decision.scope_impact),
      recorded_by: decision.recorded_by_address,
      created_at: iso(decision.created_at),
      review_state: decision.review_state,
      feedback: Redactor.redact_text(decision.feedback),
      undelivered_reason: decision.undelivered_reason,
      next_action: next_action(decision)
    }
  end

  defp deliver(repo, %DecisionLogEntry{recorded_by_terminal: nil} = decision), do: undelivered(repo, decision, "no_recording_terminal")

  defp deliver(repo, %DecisionLogEntry{} = decision) do
    case HerdrCore.deliver(decision.recorded_by_terminal, "Decision feedback: " <> decision.feedback) do
      :ok -> {:ok, decision, %{"state" => "delivered", "to" => decision.recorded_by_address}}
      {:error, reason} -> undelivered(repo, decision, reason)
    end
  end

  defp undelivered(repo, %DecisionLogEntry{} = decision, reason) do
    decision = repo.update!(Ecto.Changeset.change(decision, undelivered_reason: reason, updated_at: now()))
    DashboardPubSub.broadcast_changed()
    {:ok, decision, %{"state" => "not_delivered", "reason" => reason}}
  end

  defp review_recorded(repo, decision_id, changes) do
    repo
    |> transact(fn ->
      with {:ok, decision} <- fetch_recorded(repo, decision_id), do: review(repo, decision, changes)
    end)
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp clear_undelivered(repo, decision_id) do
    with {:ok, decision} <- fetch_reviewable(repo, decision_id) do
      if is_binary(decision.undelivered_reason),
        do: {:ok, repo.update!(Ecto.Changeset.change(decision, undelivered_reason: nil, updated_at: now()))},
        else: refuse(decision)
    end
  end

  defp fetch_recorded(repo, decision_id) do
    with {:ok, decision} <- fetch_reviewable(repo, decision_id) do
      if state(decision) == "recorded", do: {:ok, decision}, else: refuse(decision)
    end
  end

  defp fetch_reviewable(repo, decision_id) when is_binary(decision_id) do
    with %DecisionLogEntry{} = decision <- repo.get(DecisionLogEntry, decision_id),
         %WorkRequest{} = work_request <- repo.get(WorkRequest, decision.work_request_id),
         :ok <- Phase.require_writable(work_request) do
      if decision.flagged, do: {:ok, decision}, else: refuse(decision)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp fetch_reviewable(_repo, _decision_id), do: {:error, :not_found}

  defp refuse(%DecisionLogEntry{} = decision), do: {:error, {:decision_transition_refused, state(decision), next_action(decision)}}

  defp review(repo, %DecisionLogEntry{} = decision, changes) do
    at = now()
    {:ok, repo.update!(Ecto.Changeset.change(decision, Keyword.merge(changes, reviewed_at: at, updated_at: at)))}
  end

  defp feedback_text(text) when is_binary(text) do
    case text |> String.trim() |> Redactor.redact_text() do
      "" -> {:error, :missing_feedback}
      text -> {:ok, text}
    end
  end

  defp feedback_text(_text), do: {:error, :missing_feedback}

  # `fun` returns `{:ok, value}` or `{:error, reason}`; an error rolls back.
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

  defp now, do: DateTime.utc_now(:microsecond)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
