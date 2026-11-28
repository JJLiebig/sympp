defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{MetadataProjection, Sanitizer}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.BlockerTarget

  @spec blockers([ProgressEvent.t()]) :: [map()]
  def blockers(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> MetadataProjection.chronological_progress_events()
    |> Enum.reduce(%{}, fn event, blockers ->
      payload = event.payload || %{}
      blocker_id = normalize_blocker_id(Map.get(payload, "blocker_id") || event.idempotency_key || event.id)
      active = payload["active"] == true
      blocker = blocker_state(payload, active, Sanitizer.redacted_text(event.summary))

      Map.put(
        blockers,
        blocker_id,
        Map.merge(blocker, %{
          id: blocker_id,
          active: active,
          body: Sanitizer.redacted_text(event.body),
          status: event.status,
          actor: actor(event),
          event_id: event.id,
          updated_at: Sanitizer.timestamp(event.created_at)
        })
      )
    end)
    |> Map.values()
    |> Enum.sort_by(&{not &1.active, &1.updated_at || "", &1.id || ""})
  end

  defp blocker_state(%{"target" => %{} = target, "state" => state}, _active, summary), do: BlockerTarget.present(target, state, summary)
  defp blocker_state(_payload, true, summary), do: %{target: nil, summary: summary, state: "waiting", unknown: false, hold: "legacy", next_action: "reclassify"}
  defp blocker_state(_payload, false, summary), do: BlockerTarget.present(nil, "cleared", summary)

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
