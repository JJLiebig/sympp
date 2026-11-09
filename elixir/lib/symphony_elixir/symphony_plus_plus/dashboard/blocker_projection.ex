defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{MetadataProjection, Sanitizer}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  @spec blockers([ProgressEvent.t()]) :: [map()]
  def blockers(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> MetadataProjection.chronological_progress_events()
    |> Enum.reduce(%{}, fn event, blockers ->
      payload = event.payload || %{}
      blocker_id = normalize_blocker_id(Map.get(payload, "blocker_id") || event.idempotency_key || event.id)

      Map.put(blockers, blocker_id, %{
        id: blocker_id,
        active: Map.get(payload, "active") == true,
        summary: Sanitizer.redacted_text(event.summary),
        body: Sanitizer.redacted_text(event.body),
        status: event.status,
        actor: actor(event),
        event_id: event.id,
        updated_at: Sanitizer.timestamp(event.created_at)
      })
    end)
    |> Map.values()
    |> Enum.sort_by(&{not &1.active, &1.updated_at || "", &1.id || ""})
  end

  @spec blocker_event?(ProgressEvent.t()) :: boolean()
  def blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") == "set_blocker"
  end

  def blocker_event?(%ProgressEvent{}), do: false

  @spec actor(ProgressEvent.t()) :: map()
  def actor(%ProgressEvent{} = event) do
    %{
      id: event.actor_id,
      type: event.actor_type
    }
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)
end
