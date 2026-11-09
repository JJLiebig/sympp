defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Surface do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Response, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  @version_resource "sympp://health/version"
  @agent_text_mime_type "text/vnd.toon"

  @doc "The tools this server lists for its surface profile."
  @spec tool_specs(Config.t()) :: [map()]
  def tool_specs(%Config{} = config), do: ToolCatalog.startup_tool_specs(config.surface_profile, config)

  @spec tool_names(Config.t()) :: [String.t()]
  def tool_names(%Config{} = config), do: Enum.map(tool_specs(config), & &1["name"])

  @spec resource_specs() :: [map()]
  def resource_specs do
    [%{"uri" => @version_resource, "name" => "sympp version", "mimeType" => "application/json"}]
  end

  @spec work_package_resource_id(binary()) :: {:ok, String.t(), String.t()} | :error
  def work_package_resource_id(rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [work_package_id, resource_path] ->
        if String.trim(work_package_id) != "" and valid_resource_path?(resource_path) do
          {:ok, work_package_id, resource_path}
        else
          :error
        end

      _parts ->
        :error
    end
  end

  @doc """
  Reads a WorkPackage's rendered document. Any trusted caller can read these,
  so they use the agent encoding, which redacts secret-shaped keys and values.
  """
  @spec read_work_package_virtual_resource(module(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, integer(), String.t(), map()}
  def read_work_package_virtual_resource(repo, work_package_id, file_name, uri) do
    with {:ok, state} <- render_state(repo, work_package_id, file_name, uri),
         {:ok, toon} <- WorkerContext.encode_virtual_file(state, file_name, uri: uri) do
      {:ok, Response.text_resource(uri, toon, @agent_text_mime_type)}
    else
      {:error, _code, _message, _data} = error -> error
      {:error, _reason} -> service_error(uri)
    end
  end

  defp render_state(repo, work_package_id, file_name, uri) do
    if file_name in PlanningRenderer.virtual_files() do
      case PlanningRepository.get_render_state(repo, work_package_id, file_name, nil) do
        {:ok, state} -> {:ok, state}
        {:error, :not_found} -> {:error, -32_004, "Not found", %{"resource" => uri, "reason" => "not_found"}}
        {:error, _reason} -> service_error(uri)
      end
    else
      {:error, -32_601, "Method not found", %{"resource" => uri, "reason" => "unknown_virtual_file"}}
    end
  end

  defp valid_resource_path?(resource_path) when is_binary(resource_path) do
    String.trim(resource_path) != "" and not String.contains?(resource_path, "/")
  end

  defp service_error(resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
end
