defmodule SymphonyElixir.SymphonyPlusPlus.MCP.FailedCall do
  @moduledoc """
  Durable counts of failed MCP tool calls, always on.

  A failed `tools/call` adds one to its row in `sympp_failed_calls`, keyed by
  UTC day, tool, reason and layer (`endpoint`, `bridge` or `tool`). Calls to
  tools that don't exist count under `unknown`. Arguments are never stored.
  A request crosses several layers in one process; only the first layer that
  sees a tool call's failure counts it, and each call of a batch counts once.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ToolCatalog}

  defmodule Count do
    @moduledoc false

    use Ecto.Schema

    @primary_key false
    schema "sympp_failed_calls" do
      field(:day, :date)
      field(:tool, :string)
      field(:reason, :string)
      field(:layer, :string)
      field(:count, :integer)
      field(:last_at, :utc_datetime_usec)
    end
  end

  @boundary_key {__MODULE__, :boundary}
  @safe_reason ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @doc """
  Runs one request's handling. A raised or thrown failure of a tool call is
  counted as `unhandled_tool_failure` and re-raised.
  """
  @spec protect(Config.t() | map(), term(), atom(), (-> result)) :: result when result: term()
  def protect(context, payload, layer, fun) when is_function(fun, 0) do
    root? = Process.get(@boundary_key) == nil
    if root?, do: Process.put(@boundary_key, MapSet.new())

    try do
      fun.()
    rescue
      exception ->
        record(context, payload, "unhandled_tool_failure", layer)
        reraise(exception, __STACKTRACE__)
    catch
      kind, reason ->
        record(context, payload, "unhandled_tool_failure", layer)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if root?, do: Process.delete(@boundary_key)
    end
  end

  @doc "Counts the failure in a JSON-RPC response to a tool call and returns the response unchanged."
  @spec observe_response(Config.t() | map(), term(), term(), atom()) :: term()
  def observe_response(context, payload, response, layer) do
    case response do
      %{"error" => %{"code" => code} = error} when is_integer(code) ->
        record(context, payload, reason(Map.get(error, "data"), code), layer)

      _success_or_other ->
        :ok
    end

    response
  end

  @doc "Counts a tool call refused before it produced a JSON-RPC response."
  @spec observe_error(Config.t() | map(), term(), String.t(), atom()) :: :ok
  def observe_error(context, payload, reason, layer) when is_binary(reason), do: record(context, payload, reason, layer)

  @doc """
  Failure counts, newest day first. `since` (YYYY-MM-DD) and `tool` narrow
  them.
  """
  @spec summary(module(), map()) :: {:ok, map()} | {:tool_error, String.t()} | {:error, term()}
  def summary(repo, arguments) when is_map(arguments) do
    with {:ok, since} <- since_argument(Map.get(arguments, "since")),
         {:ok, tool} <- tool_argument(Map.get(arguments, "tool")) do
      rows = repo.all(summary_query(since, tool))

      {:ok,
       %{
         "total" => rows |> Enum.map(& &1.count) |> Enum.sum(),
         "failures" => Enum.map(rows, &public/1)
       }}
    end
  rescue
    error -> {:error, error}
  end

  defp summary_query(since, tool) do
    query = from(row in Count, order_by: [desc: row.day, desc: row.count, asc: row.tool, asc: row.reason, asc: row.layer])
    query = if since, do: from(row in query, where: row.day >= ^since), else: query
    if tool, do: from(row in query, where: row.tool == ^tool), else: query
  end

  defp since_argument(nil), do: {:ok, nil}

  defp since_argument(value) when is_binary(value) do
    case value |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:tool_error, "invalid_since"}
    end
  end

  defp since_argument(_value), do: {:tool_error, "invalid_since"}

  defp tool_argument(nil), do: {:ok, nil}
  defp tool_argument(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp tool_argument(_value), do: {:tool_error, "invalid_tool"}

  defp public(%Count{} = row) do
    %{
      "day" => Date.to_iso8601(row.day),
      "tool" => row.tool,
      "reason" => row.reason,
      "layer" => row.layer,
      "count" => row.count,
      "last_at" => DateTime.to_iso8601(row.last_at)
    }
  end

  defp record(context, payload, reason, layer) do
    with [_ | _] = calls <- payload |> tool_calls() |> Enum.reject(&counted?/1),
         repo when is_atom(repo) and not is_nil(repo) <- repo(context) do
      mark_counted(calls)
      now = DateTime.utc_now(:microsecond)
      Enum.each(calls, &increment(repo, tool_name(&1), safe_reason(reason), Atom.to_string(layer), now))
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp counted?(call) do
    case Process.get(@boundary_key) do
      %MapSet{} = counted -> MapSet.member?(counted, call)
      _no_boundary -> false
    end
  end

  defp mark_counted(calls) do
    case Process.get(@boundary_key) do
      %MapSet{} = counted -> Process.put(@boundary_key, Enum.into(calls, counted))
      _no_boundary -> :ok
    end
  end

  # Counting must never fail the call it describes.
  defp increment(repo, tool, reason, layer, now) do
    repo.insert_all(
      Count,
      [%{day: DateTime.to_date(now), tool: tool, reason: reason, layer: layer, count: 1, last_at: now}],
      on_conflict: [inc: [count: 1], set: [last_at: now]],
      conflict_target: [:day, :tool, :reason, :layer],
      log: false
    )
  rescue
    _error -> :ok
  end

  defp repo(%Config{repo: repo}), do: repo
  defp repo(%{config: %Config{repo: repo}}), do: repo
  defp repo(_context), do: nil

  defp tool_calls(payloads) when is_list(payloads), do: Enum.flat_map(payloads, &tool_calls/1)
  defp tool_calls(%{"jsonrpc" => "2.0", "method" => "tools/call"} = call), do: [call]
  defp tool_calls(_payload), do: []

  defp tool_name(%{"params" => %{"name" => name}}), do: if(ToolCatalog.known_tool?(name), do: name, else: "unknown")
  defp tool_name(_call), do: "unknown"

  defp reason(%{"code" => reason}, _code) when is_binary(reason), do: reason
  defp reason(%{"reason" => reason}, _code) when is_binary(reason), do: reason
  defp reason(_data, code), do: class_reason(code)

  defp safe_reason(reason) when is_binary(reason), do: if(Regex.match?(@safe_reason, reason), do: reason, else: "other")

  defp class_reason(-32_600), do: "invalid_request"
  defp class_reason(-32_601), do: "method_not_found"
  defp class_reason(-32_602), do: "invalid_params"
  defp class_reason(-32_001), do: "unauthorized"
  defp class_reason(-32_003), do: "forbidden"
  defp class_reason(-32_004), do: "not_found"
  defp class_reason(-32_009), do: "precondition_failed"
  defp class_reason(_code), do: "server_error"
end
