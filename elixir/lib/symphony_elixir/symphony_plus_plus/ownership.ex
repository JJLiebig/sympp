defmodule SymphonyElixir.SymphonyPlusPlus.Ownership do
  @moduledoc """
  "Worked on by <terminal>": which Herdr terminal owns a WorkRequest.

  | From | Event | To |
  |---|---|---|
  | — | owner-gated write on a WorkRequest with no live owner | live (caller) |
  | live | owner-gated write from the same terminal | live |
  | live | owner-gated write from another terminal | refused `owned_by_other_terminal` |
  | live | the factory's herdr-core reports the terminal finished | finished (`taken_over` when a write replaces it) |
  | live | the owner's bridge sent `detach` and the factory's core can't see it live | finished (`terminal_finished`) |
  | live | heartbeat lapsed without `detach`, or the core is unreachable | live (liveness `unknown`) |
  | live | operator Release | finished (`released_by_operator`) |
  | live | WorkRequest archived | finished (`subject_ended`) |

  Liveness is never inferred from how recently a tool was called. A partial
  unique index allows one live row per subject, so two terminals racing for one
  WorkRequest end with exactly one owner.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, Id}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @subject "work_request"

  @type repo :: module()
  @type owner :: %{required(String.t()) => term()}

  @doc """
  Runs an owner-gated write for `terminal` on a WorkRequest.

  Ownership is taken atomically before the write runs. If the write fails and
  this call had just taken ownership, the new row is removed again, so a failed
  write leaves ownership as it was.
  """
  @spec gated(repo(), String.t(), Terminal.t(), (-> result)) ::
          result | {:error, {:owned_by_other_terminal, owner()}} | {:error, term()}
        when result: term()
  def gated(repo, work_request_id, %Terminal{} = terminal, fun) when is_function(fun, 0) do
    case acquire(repo, work_request_id, terminal) do
      {:ok, %WorkedOn{}, :held} ->
        fun.()

      {:ok, %WorkedOn{} = row, :acquired} ->
        result = fun.()
        if failed?(result), do: repo.delete_all(from(worked_on in WorkedOn, where: worked_on.id == ^row.id))
        result

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Takes or confirms ownership of a WorkRequest for `terminal`."
  @spec acquire(repo(), String.t(), Terminal.t()) ::
          {:ok, WorkedOn.t(), :held | :acquired} | {:error, {:owned_by_other_terminal, owner()}} | {:error, term()}
  def acquire(repo, work_request_id, %Terminal{} = terminal) when is_binary(work_request_id) do
    # The common case, a terminal writing to a WorkRequest it already owns,
    # needs no write lock.
    case held_unchanged(repo, work_request_id, terminal) do
      %WorkedOn{} = row -> {:ok, row, :held}
      nil -> acquire_with_lock(repo, work_request_id, terminal)
    end
  end

  defp held_unchanged(repo, work_request_id, %Terminal{} = terminal) do
    with %WorkRequest{archived_at: nil} <- repo.get(WorkRequest, work_request_id),
         %WorkedOn{terminal_key: key, role: role, domain: domain, display_address: address} = row
         when key == terminal.key and role == terminal.role and domain == terminal.domain and address == terminal.display_address <-
           live_row(repo, @subject, work_request_id) do
      row
    else
      _other -> nil
    end
  end

  defp acquire_with_lock(repo, work_request_id, terminal) do
    repo.transaction(fn -> acquire_in_transaction(repo, work_request_id, terminal) end, mode: :immediate)
    |> case do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {:ok, row, how}} -> notify_acquired({:ok, row, how})
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error ->
      message = String.downcase(Exception.message(error))
      if String.contains?(message, ["locked", "busy"]), do: {:error, :database_busy}, else: reraise(error, __STACKTRACE__)
  end

  defp acquire_in_transaction(repo, work_request_id, terminal) do
    case repo.get(WorkRequest, work_request_id) do
      nil ->
        {:error, :not_found}

      %WorkRequest{archived_at: %DateTime{}} ->
        {:error, :work_request_archived}

      %WorkRequest{} ->
        case live_row(repo, @subject, work_request_id) do
          nil -> insert(repo, work_request_id, terminal)
          %WorkedOn{terminal_key: key} = row when key == terminal.key -> {:ok, refresh_role(repo, row, terminal), :held}
          %WorkedOn{} = row -> take_over_or_refuse(repo, row, work_request_id, terminal)
        end
    end
  end

  defp take_over_or_refuse(repo, %WorkedOn{} = row, work_request_id, terminal) do
    if finished_on_factory_core?(row) do
      finish(repo, row, "taken_over")
      insert(repo, work_request_id, terminal)
    else
      {:error, {:owned_by_other_terminal, refusal(row)}}
    end
  end

  defp insert(repo, work_request_id, %Terminal{} = terminal) do
    now = DateTime.utc_now(:microsecond)

    row = %WorkedOn{
      id: Id.random("wo"),
      subject_kind: @subject,
      subject_id: work_request_id,
      terminal_key: terminal.key,
      display_address: terminal.display_address,
      role: terminal.role,
      domain: terminal.domain,
      state: "live",
      started_at: now
    }

    case repo.insert(Ecto.Changeset.unique_constraint(Ecto.Changeset.change(row), [:subject_kind, :subject_id], name: :sympp_worked_on_one_live_per_subject_index)) do
      {:ok, row} ->
        {:ok, row, :acquired}

      {:error, %Ecto.Changeset{}} ->
        case live_row(repo, @subject, work_request_id) do
          %WorkedOn{} = owner -> {:error, {:owned_by_other_terminal, refusal(owner)}}
          nil -> {:error, :ownership_conflict}
        end
    end
  end

  # Labels can change while the same terminal keeps ownership.
  defp refresh_role(repo, %WorkedOn{} = row, %Terminal{} = terminal) do
    case Ecto.Changeset.change(row, role: terminal.role, domain: terminal.domain, display_address: terminal.display_address) do
      %Ecto.Changeset{changes: changes} when changes == %{} -> row
      changeset -> repo.update!(changeset)
    end
  end

  @doc "Operator Release: ends a WorkRequest's live ownership so another terminal can take it."
  @spec release(repo(), String.t()) :: {:ok, WorkedOn.t()} | {:error, :not_found | :not_owned}
  def release(repo, work_request_id) when is_binary(work_request_id) do
    repo.transaction(
      fn ->
        cond do
          is_nil(repo.get(WorkRequest, work_request_id)) -> {:error, :not_found}
          row = live_row(repo, @subject, work_request_id) -> {:ok, finish(repo, row, "released_by_operator")}
          true -> {:error, :not_owned}
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, {:ok, row}} -> DashboardPubSub.broadcast_changed_on_success({:ok, row})
      {:ok, error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Ends every live row on a subject that has ended or been archived."
  @spec end_subject(repo(), String.t(), String.t()) :: :ok
  def end_subject(repo, subject_kind, subject_id) do
    query = from(row in WorkedOn, where: row.subject_kind == ^subject_kind and row.subject_id == ^subject_id)
    finish_all(repo, query, "subject_ended")
  end

  @doc "Removes the rows of deleted subjects."
  @spec delete_subjects(repo(), String.t(), [String.t()]) :: :ok
  def delete_subjects(_repo, _subject_kind, []), do: :ok

  def delete_subjects(repo, subject_kind, subject_ids) do
    subject_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.each(&repo.delete_all(from(worked_on in WorkedOn, where: worked_on.subject_kind == ^subject_kind and worked_on.subject_id in ^&1)))
  end

  @doc """
  A bridge detached cleanly. Its terminal's rows end unless the factory's own
  herdr-core still sees that terminal live.
  """
  @spec detached(repo(), String.t()) :: :ok
  def detached(repo, terminal_key) when is_binary(terminal_key) do
    with {core_id, address} <- Terminal.split_key(terminal_key),
         view when not is_tuple(view) <- HerdrCore.view(core_id, address) do
      finish_all(repo, from(worked_on in WorkedOn, where: worked_on.terminal_key == ^terminal_key), "terminal_finished")
    else
      _live_or_invalid -> :ok
    end
  end

  @doc "Live owners of WorkRequests, by WorkRequest id, as public payloads."
  @spec owners(repo(), [String.t()]) :: %{String.t() => owner()}
  def owners(_repo, []), do: %{}

  def owners(repo, work_request_ids) when is_list(work_request_ids) do
    work_request_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids ->
      repo.all(from(worked_on in WorkedOn, where: worked_on.subject_kind == @subject and worked_on.state == "live" and worked_on.subject_id in ^ids))
    end)
    |> Map.new(&{&1.subject_id, public(&1)})
  end

  @doc "WorkRequests a terminal owns, most recent first."
  @spec owned_by(repo(), String.t()) :: [WorkedOn.t()]
  def owned_by(repo, terminal_key) when is_binary(terminal_key) do
    repo.all(
      from(worked_on in WorkedOn,
        where: worked_on.terminal_key == ^terminal_key and worked_on.state == "live" and worked_on.subject_kind == @subject,
        order_by: [desc: worked_on.started_at]
      )
    )
  end

  @doc "The live owner row of a WorkRequest, if any."
  @spec owner(repo(), String.t()) :: WorkedOn.t() | nil
  def owner(repo, work_request_id), do: live_row(repo, @subject, work_request_id)

  @doc "A row as the board and MCP show it, with live / unknown / finished liveness."
  @spec public(WorkedOn.t()) :: owner()
  def public(%WorkedOn{} = row) do
    %{
      "address" => row.display_address,
      "role" => row.role,
      "domain" => row.domain,
      "liveness" => liveness(row),
      "since" => DateTime.to_iso8601(row.started_at)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  `live` when the factory's core sees the terminal live or its bridge
  heartbeat is fresh; `finished` when the core reports it finished; otherwise
  `unknown`, which keeps the owner.
  """
  @spec liveness(WorkedOn.t()) :: String.t()
  def liveness(%WorkedOn{state: "finished"}), do: "finished"

  def liveness(%WorkedOn{terminal_key: key}) do
    case Terminal.split_key(key) do
      {core_id, address} -> core_liveness(HerdrCore.view(core_id, address), key)
      :error -> "unknown"
    end
  end

  defp core_liveness({:live, _record}, _key), do: "live"
  defp core_liveness(:finished, _key), do: "finished"
  defp core_liveness(_unseen_or_unknown, key), do: if(ClientLeases.terminal_live?(key), do: "live", else: "unknown")

  defp refusal(%WorkedOn{} = row) do
    status =
      case Terminal.split_key(row.terminal_key) do
        {core_id, address} -> HerdrCore.status_state(core_id, address)
        :error -> "unknown"
      end

    %{
      "address" => row.display_address,
      "role" => row.role,
      "status_state" => status,
      "since" => DateTime.to_iso8601(row.started_at),
      "next_action" => "ask #{row.display_address}, or wait until it finishes"
    }
  end

  defp finished_on_factory_core?(%WorkedOn{terminal_key: key}) do
    case Terminal.split_key(key) do
      {core_id, address} -> HerdrCore.view(core_id, address) == :finished
      :error -> false
    end
  end

  defp live_row(repo, subject_kind, subject_id) do
    repo.one(
      from(worked_on in WorkedOn,
        where: worked_on.subject_kind == ^subject_kind and worked_on.subject_id == ^subject_id and worked_on.state == "live"
      )
    )
  end

  defp finish(repo, %WorkedOn{} = row, reason) do
    {:ok, row} = repo.update(Ecto.Changeset.change(row, state: "finished", finish_reason: reason, finished_at: DateTime.utc_now(:microsecond)))
    row
  end

  defp finish_all(repo, query, reason) do
    now = DateTime.utc_now(:microsecond)

    case repo.update_all(from(worked_on in query, where: worked_on.state == "live"), set: [state: "finished", finish_reason: reason, finished_at: now, updated_at: now]) do
      {0, _rows} -> :ok
      {_count, _rows} -> DashboardPubSub.broadcast_changed()
    end

    :ok
  end

  defp notify_acquired({:ok, _row, :acquired} = result) do
    DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_acquired(result), do: result

  defp failed?({:error, _reason}), do: true
  defp failed?({:error, _code, _message, _data}), do: true
  defp failed?(_result), do: false
end
