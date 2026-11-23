defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestReadPage do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.{Toon, WorkerContext}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  # Budget each representation independently, at 3.5 UTF-8 bytes per estimated token.
  @max_bytes 17_500

  @type result :: {:ok, map()} | {:tool_error, String.t()}

  @spec rows(map(), [[String.t()]], term(), String.t() | nil, pos_integer()) :: result()
  def rows(payload, paths, scope, cursor, max_bytes \\ @max_bytes) do
    payload = safe_payload(payload)
    rows = for path <- paths, row <- get_in(payload, path), do: {path, row}
    base = Enum.reduce(paths, payload, &put_in(&2, &1, []))
    size = length(rows)

    # Cursor positions stay valid across status updates, and fail if the
    # ordered IDs changed. A continuation never silently skips a removed row.
    scope = {scope, Enum.map(rows, fn {path, row} -> {path, Map.take(row, ~w(id from to))} end)}

    with {:ok, offset} <- position(scope, cursor),
         true <- is_nil(cursor) or offset < size do
      remaining = Enum.drop(rows, offset)
      remaining_count = size - offset

      render = fn count ->
        page =
          remaining
          |> Enum.take(count)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.reduce(base, &put_rows/2)
          |> continuation(scope, offset + count, size)

        bounded_result(page, max_bytes)
      end

      case largest_page(remaining_count, render) do
        nil -> {:tool_error, "row_exceeds_read_budget"}
        result -> {:ok, result}
      end
    else
      _invalid -> {:tool_error, "invalid_cursor"}
    end
  end

  @spec document(map(), term(), String.t() | nil) :: result()
  def document(payload, scope, cursor) do
    payload = safe_payload(payload)

    case is_nil(cursor) && bounded_result(payload, @max_bytes) do
      %{} = result -> {:ok, result}
      _needs_chunk -> document_chunk(Jason.encode!(payload), scope, cursor)
    end
  end

  @spec position(term(), String.t() | nil) :: {:ok, non_neg_integer()} | {:tool_error, String.t()}
  def position(_scope, nil), do: {:ok, 0}

  def position(scope, cursor) do
    with [key, offset] <- String.split(cursor, ".", parts: 2),
         true <- key == cursor_key(scope),
         {offset, ""} when offset > 0 <- Integer.parse(offset) do
      {:ok, offset}
    else
      _invalid -> {:tool_error, "invalid_cursor"}
    end
  end

  @spec cursor(term(), pos_integer()) :: String.t()
  def cursor(scope, offset), do: cursor_key(scope) <> "." <> Integer.to_string(offset)

  defp continuation(payload, scope, offset, size) when offset < size, do: Map.put(payload, "next_cursor", cursor(scope, offset))
  defp continuation(payload, _scope, _offset, _size), do: payload

  defp put_rows({path, values}, payload), do: put_in(payload, path, values)

  defp document_chunk(json, scope, cursor) do
    size = byte_size(json)
    scope = {scope, :crypto.hash(:sha256, json)}

    with {:ok, offset} <- position(scope, cursor),
         true <- offset < size and :binary.at(json, offset) not in 128..191 do
      render = fn bytes ->
        chunk = json |> binary_part(offset, bytes) |> utf8_prefix()

        %{"chunk" => chunk}
        |> continuation(scope, offset + byte_size(chunk), size)
        |> bounded_result(@max_bytes)
      end

      {:ok, largest_page(min(size - offset, @max_bytes), render)}
    else
      _invalid -> {:tool_error, "invalid_cursor"}
    end
  end

  defp largest_page(size, render) do
    render.(size) || search(1, size - 1, render, nil)
  end

  defp search(first, last, _render, best) when first > last, do: best

  defp search(first, last, render, best) do
    middle = div(first + last, 2)

    case render.(middle) do
      nil -> search(first, middle - 1, render, best)
      result -> search(middle + 1, last, render, result)
    end
  end

  defp bounded_result(payload, max_bytes) do
    if byte_size(Jason.encode!(payload)) <= max_bytes do
      text = Toon.encode_json(payload)
      if byte_size(text) <= max_bytes, do: ToolResult.read_tool_result(payload, text)
    end
  end

  defp utf8_prefix(binary) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _trailing} -> valid
    end
  end

  defp cursor_key(scope) do
    :crypto.hash(:sha256, :erlang.term_to_binary(scope))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  defp safe_payload(payload), do: payload |> WorkerContext.agent_safe() |> Redactor.json_safe()
end
