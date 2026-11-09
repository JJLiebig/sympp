defmodule SymphonyElixirWeb.SymppDashboardApi.LocalOperatorActions do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Blockers
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService

  import Ecto.Query, only: [from: 2]

  @local_operator_actor "local-operator"

  @doc """
  Ends a dispatched or ready WorkPackage as `finished`: its PR waits on someone
  else, so sympp stops watching it. The WorkRequest can complete; packages that
  depend on it stay blocked.
  """
  @spec finish_work_package_for_local_operator(module(), String.t()) :: {:ok, WorkPackage.t()} | {:error, term()}
  def finish_work_package_for_local_operator(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, work_package} <- require_work_request_package(work_package),
         {:ok, _delivery} <-
           WorkRequestService.record_work_package_delivery(repo, work_package.work_request_id, work_package.id, %{
             outcome: "finished",
             idempotency_key: "local-operator-finish:#{work_package.id}",
             recorded_by: @local_operator_actor
           }) do
      WorkPackageRepository.get(repo, work_package_id)
    end
  end

  @spec hide_work_package_for_local_operator(module(), String.t()) :: {:ok, WorkPackage.t()} | {:error, term()}
  def hide_work_package_for_local_operator(repo, work_package_id) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
        hide_work_package_for_local_operator_in_transaction(repo, work_package)
      end
    end)
  end

  defp hide_work_package_for_local_operator_in_transaction(repo, %WorkPackage{} = work_package) do
    with :ok <- require_hideable_work_package(work_package),
         :ok <- require_direct_work_package(work_package),
         {:ok, _settings} <- append_hidden_work_package_id_for_local_operator(repo, work_package.id) do
      {:ok, work_package}
    end
  end

  defp require_hideable_work_package(%WorkPackage{} = work_package) do
    if Lifecycle.ended?(work_package), do: :ok, else: {:error, :not_delivered}
  end

  defp require_direct_work_package(%WorkPackage{work_request_id: work_request_id})
       when work_request_id in [nil, ""],
       do: :ok

  defp require_direct_work_package(%WorkPackage{}), do: {:error, :work_request_package}

  defp require_work_request_package(%WorkPackage{work_request_id: work_request_id} = work_package)
       when is_binary(work_request_id) and work_request_id != "",
       do: {:ok, work_package}

  defp require_work_request_package(%WorkPackage{}), do: {:error, :work_request_package_required}

  @spec clear_work_package_blocker_for_local_operator(module(), String.t(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def clear_work_package_blocker_for_local_operator(repo, work_package_id, blocker_id, params) do
    summary =
      case text_param(params, "resolution") do
        nil -> "Cleared by the operator"
        resolution -> "Cleared by the operator: " <> resolution
      end

    with true <- valid_package_route_id?(work_package_id),
         {:ok, blocker, _how} <- Blockers.set(repo, nil, work_package_id, to_string(blocker_id || ""), false, summary) do
      {:ok, blocker}
    else
      false -> {:error, :not_found}
      {:error, reason} when reason in [:blocker_not_found, :invalid_blocker_id] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_package_route_id?(work_package_id) when is_binary(work_package_id) do
    String.trim(work_package_id) != "" and not String.contains?(work_package_id, ["\0", "\n", "\r", "\t"])
  end

  defp valid_package_route_id?(_work_package_id), do: false

  defp append_hidden_work_package_id_for_local_operator(_repo, work_package_id)
       when not is_binary(work_package_id) or byte_size(work_package_id) == 0 do
    {:error, :not_found}
  end

  defp append_hidden_work_package_id_for_local_operator(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _settings} <- ensure_operator_settings_for_local_operator(repo),
         {:ok, _settings} <- OperatorSettingsRepository.update(repo, %{}),
         {1, _rows} <-
           repo.update_all(append_hidden_work_package_id_query(work_package_id, now), []),
         %OperatorSettings{} = settings <- repo.get(OperatorSettings, OperatorSettings.settings_id()) do
      {:ok, settings}
    else
      {0, _rows} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_operator_settings_for_local_operator(module()) :: {:ok, OperatorSettings.t()} | {:error, term()}
  def ensure_operator_settings_for_local_operator(repo) do
    repo.insert(OperatorSettings.default(), on_conflict: :nothing, conflict_target: :id)
  end

  defp append_hidden_work_package_id_query(work_package_id, now) do
    from(settings in OperatorSettings,
      where: settings.id == ^OperatorSettings.settings_id(),
      update: [
        set: [
          hidden_work_package_ids:
            fragment(
              """
              CASE
                WHEN EXISTS (
                  SELECT 1
                  FROM json_each(COALESCE(?, '[]'))
                  WHERE value IS NOT NULL
                    AND value = ?
                )
                THEN COALESCE((
                  SELECT json_group_array(value)
                  FROM (
                    SELECT DISTINCT value
                    FROM json_each(COALESCE(?, '[]'))
                    WHERE value IS NOT NULL
                  )
                ), '[]')
                ELSE json_insert(
                  COALESCE((
                    SELECT json_group_array(value)
                    FROM (
                      SELECT DISTINCT value
                      FROM json_each(COALESCE(?, '[]'))
                      WHERE value IS NOT NULL
                    )
                  ), '[]'),
                  '$[#]',
                  ?
                )
              END
              """,
              settings.hidden_work_package_ids,
              ^work_package_id,
              settings.hidden_work_package_ids,
              settings.hidden_work_package_ids,
              ^work_package_id
            ),
          updated_at: ^now
        ]
      ]
    )
  end

  defp local_operator_transaction(repo, fun) when is_function(fun, 0) do
    repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_local_operator_transaction_result()
  end

  defp normalize_local_operator_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_local_operator_transaction_result({:error, reason}), do: {:error, reason}

  @spec text_param(map(), String.t(), term()) :: String.t() | term()
  def text_param(params, key, default \\ nil) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      nil ->
        default

      value ->
        to_string(value)
    end
  end
end
