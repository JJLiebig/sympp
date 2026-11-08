defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Timeline do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  @type item :: %{
          id: String.t(),
          work_package_id: String.t(),
          sequence: non_neg_integer(),
          created_at: DateTime.t(),
          summary: String.t(),
          body: String.t() | nil,
          status: String.t(),
          actor: map(),
          idempotency_key: String.t() | nil,
          agent_run_id: String.t() | nil,
          payload: map()
        }

  @spec fetch(Repository.repo(), String.t()) :: {:ok, [item()]} | {:error, Repository.error()}
  def fetch(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, events} <- Repository.list_progress_events(repo, work_package_id) do
      {:ok, Enum.map(events, &to_item/1)}
    end
  end

  @spec to_item(ProgressEvent.t()) :: item()
  def to_item(%ProgressEvent{} = event) do
    %{
      id: event.id,
      work_package_id: event.work_package_id,
      sequence: event.sequence,
      created_at: event.created_at,
      summary: event.summary,
      body: event.body,
      status: event.status,
      actor: actor(event),
      idempotency_key: event.idempotency_key,
      agent_run_id: event.agent_run_id,
      payload: event.payload || %{}
    }
  end

  defp actor(%ProgressEvent{} = event) do
    %{
      id: event.actor_id,
      type: event.actor_type
    }
  end
end
