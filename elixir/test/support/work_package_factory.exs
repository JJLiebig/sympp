defmodule SymphonyElixir.WorkPackageFactory do
  @moduledoc false

  @spec attrs(keyword()) :: map()
  def attrs(overrides \\ []) do
    defaults = %{
      kind: "mcp",
      title: "Implement package",
      repo: "nextide/example",
      base_branch: "main",
      branch_pattern: "agent/example",
      product_description: "Product context",
      engineering_scope: "Engineering scope",
      acceptance_criteria: ["Create and fetch package"],
      parent_id: nil,
      phase_id: nil,
      owner_id: "agent-1"
    }

    overrides
    |> Enum.into(defaults)
    |> put_default_status()
  end

  # Executable packages default to dispatched; architect anchors keep their anchor status.
  defp put_default_status(%{kind: "delegation"} = attrs), do: Map.put_new(attrs, :status, "planning")
  defp put_default_status(attrs), do: Map.put_new(attrs, :status, "dispatched")

  @spec database_path() :: Path.t()
  def database_path do
    Path.join(System.tmp_dir!(), "sympp-work-packages-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
