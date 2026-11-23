defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon do
  @moduledoc """
  Minimal TOON encoder for agent-facing Symphony++ context.

  The encoder accepts JSON-like maps, lists, and primitive values and returns a
  deterministic text representation for prompts. It does not decode TOON and it
  is not a storage format; callers should keep canonical JSON/Ecto/MCP payloads
  as the source of truth and derive TOON only at the LLM text boundary.

  Compact JSON remains preferable for deeply nested or highly non-uniform
  payloads, printable integer arrays that are ambiguous with Elixir charlists,
  surfaces that already require exact JSON contracts, and latency paths where
  local benchmarking shows JSON is faster despite TOON's smaller tabular form.
  """

  @type primitive :: nil | boolean() | number() | String.t()
  @type json_like :: primitive() | [json_like()] | %{optional(String.t() | atom()) => json_like()}

  @spec encode(json_like()) :: String.t()
  def encode(value) do
    reject_ambiguous_arrays!(value)
    encode_json(value)
  end

  @doc "Encodes a value from a JSON payload, where integer lists are arrays."
  @spec encode_json(json_like()) :: String.t()
  def encode_json(value) do
    value
    |> emit_root()
    |> Enum.join("\n")
  end

  defp emit_root(%_{} = value), do: raise_unsupported(value)
  defp emit_root(%{} = map) when map_size(map) == 0, do: []
  defp emit_root(%{} = map), do: emit_map_fields(map, 0)
  defp emit_root(list) when is_list(list), do: emit_array(nil, list, 0)
  defp emit_root(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value), do: [encode_primitive(value)]
  defp emit_root(value), do: raise_unsupported(value)

  defp emit_map_fields(map, depth) do
    map
    |> sorted_entries()
    |> Enum.flat_map(fn {key, value} -> emit_field(key, value, depth) end)
  end

  defp emit_field(_key, %_{} = value, _depth), do: raise_unsupported(value)

  defp emit_field(key, %{} = map, depth) when map_size(map) == 0 do
    [indent(depth) <> encode_key(key) <> ":"]
  end

  defp emit_field(key, %{} = map, depth) do
    [indent(depth) <> encode_key(key) <> ":" | emit_map_fields(map, depth + 1)]
  end

  defp emit_field(key, list, depth) when is_list(list), do: emit_array(key, list, depth)

  defp emit_field(key, value, depth) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    [indent(depth) <> encode_key(key) <> ": " <> encode_primitive(value)]
  end

  defp emit_field(_key, value, _depth), do: raise_unsupported(value)

  defp emit_array(key, [], depth), do: [array_header(key, 0, depth) <> ":"]

  defp emit_array(key, list, depth) do
    cond do
      Enum.all?(list, &primitive?/1) ->
        [array_header(key, length(list), depth) <> ": " <> Enum.map_join(list, ",", &encode_primitive/1)]

      tabular_rows?(list) ->
        fields = list |> hd() |> sorted_entries() |> Enum.map(&elem(&1, 0))

        rows =
          Enum.map(list, fn row ->
            values = row |> normalized_entry_map() |> Map.take(fields)
            indent(depth + 1) <> Enum.map_join(fields, ",", &encode_primitive(Map.fetch!(values, &1)))
          end)

        [array_header(key, length(list), depth) <> "{" <> Enum.map_join(fields, ",", &encode_key/1) <> "}:" | rows]

      true ->
        [array_header(key, length(list), depth) <> ":" | Enum.flat_map(list, &emit_list_item(&1, depth + 1))]
    end
  end

  defp emit_list_item(value, depth) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    [indent(depth) <> "- " <> encode_primitive(value)]
  end

  defp emit_list_item(%_{} = value, _depth), do: raise_unsupported(value)
  defp emit_list_item(%{} = map, depth) when map_size(map) == 0, do: [indent(depth) <> "-"]

  defp emit_list_item(%{} = map, depth) do
    [{key, value} | rest] = sorted_entries(map)

    sibling_fields =
      Enum.flat_map(rest, fn {field_key, field_value} ->
        emit_field(field_key, field_value, depth + 1)
      end)

    emit_first_list_item_field(key, value, depth) ++ sibling_fields
  end

  defp emit_list_item([], depth), do: [indent(depth) <> "- [0]:"]

  defp emit_list_item(list, depth) when is_list(list) do
    if Enum.all?(list, &primitive?/1) do
      line =
        indent(depth) <>
          "- " <> array_header_token(nil, length(list)) <> ": " <> Enum.map_join(list, ",", &encode_primitive/1)

      [line]
    else
      header = indent(depth) <> "- " <> array_header_token(nil, length(list)) <> ":"
      [header | Enum.flat_map(list, &emit_list_item(&1, depth + 1))]
    end
  end

  defp emit_list_item(value, _depth), do: raise_unsupported(value)

  defp emit_first_list_item_field(_key, %_{} = value, _depth), do: raise_unsupported(value)

  defp emit_first_list_item_field(key, %{} = map, depth) when map_size(map) == 0 do
    [indent(depth) <> "- " <> encode_key(key) <> ":"]
  end

  defp emit_first_list_item_field(key, %{} = map, depth) do
    [indent(depth) <> "- " <> encode_key(key) <> ":" | emit_map_fields(map, depth + 2)]
  end

  defp emit_first_list_item_field(key, [], depth) do
    [indent(depth) <> "- " <> array_header_token(key, 0) <> ":"]
  end

  defp emit_first_list_item_field(key, list, depth) when is_list(list) do
    cond do
      Enum.all?(list, &primitive?/1) ->
        line =
          indent(depth) <>
            "- " <> array_header_token(key, length(list)) <> ": " <> Enum.map_join(list, ",", &encode_primitive/1)

        [line]

      tabular_rows?(list) ->
        fields = list |> hd() |> sorted_entries() |> Enum.map(&elem(&1, 0))

        rows =
          Enum.map(list, fn row ->
            values = row |> normalized_entry_map() |> Map.take(fields)
            indent(depth + 2) <> Enum.map_join(fields, ",", &encode_primitive(Map.fetch!(values, &1)))
          end)

        header =
          indent(depth) <>
            "- " <> array_header_token(key, length(list)) <> "{" <> Enum.map_join(fields, ",", &encode_key/1) <> "}:"

        [header | rows]

      true ->
        header = indent(depth) <> "- " <> array_header_token(key, length(list)) <> ":"
        [header | Enum.flat_map(list, &emit_list_item(&1, depth + 2))]
    end
  end

  defp emit_first_list_item_field(key, value, depth) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    [indent(depth) <> "- " <> encode_key(key) <> ": " <> encode_primitive(value)]
  end

  defp emit_first_list_item_field(_key, value, _depth), do: raise_unsupported(value)

  defp tabular_rows?([%{} | _] = rows) do
    first_fields = rows |> hd() |> sorted_entries() |> Enum.map(&elem(&1, 0))

    first_fields != [] and
      Enum.all?(rows, fn
        %{} = row ->
          entries = sorted_entries(row)
          Enum.map(entries, &elem(&1, 0)) == first_fields and Enum.all?(entries, fn {_key, value} -> primitive?(value) end)

        _other ->
          false
      end)
  end

  defp tabular_rows?(_list), do: false

  defp array_header(key, length, depth), do: indent(depth) <> array_header_token(key, length)
  defp array_header_token(nil, length), do: "[" <> Integer.to_string(length) <> "]"
  defp array_header_token(key, length), do: encode_key(key) <> "[" <> Integer.to_string(length) <> "]"

  defp sorted_entries(%{} = map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))

    keys = Enum.map(entries, &elem(&1, 0))

    if Enum.uniq(keys) == keys do
      entries
    else
      raise ArgumentError, "TOON map keys must be unique after string normalization"
    end
  end

  defp normalized_entry_map(%{} = map), do: Map.new(sorted_entries(map))

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(_key), do: raise(ArgumentError, "TOON map keys must be strings or atoms")

  defp encode_key(key) do
    key = normalize_key(key)

    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.]*$/, key), do: key, else: encode_quoted_string(key)
  end

  defp encode_primitive(nil), do: "null"
  defp encode_primitive(true), do: "true"
  defp encode_primitive(false), do: "false"
  defp encode_primitive(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_primitive(value) when is_float(value), do: encode_float(value)
  defp encode_primitive(value) when is_binary(value), do: encode_string(value)

  defp encode_string(value) do
    if quote_string?(value), do: encode_quoted_string(value), else: value
  end

  defp quote_string?(value) do
    value == "" or value != String.trim(value) or String.starts_with?(value, "-") or numeric_like?(value) or typed_literal?(value) or
      structural_character?(value) or String.contains?(value, [",", ":", "[", "]", "{", "}", "\"", "\\"])
  end

  defp structural_character?(<<>>), do: false
  defp structural_character?(<<char::utf8, _rest::binary>>) when char < 0x20 or char in [0x2028, 0x2029], do: true
  defp structural_character?(<<_char::utf8, rest::binary>>), do: structural_character?(rest)

  defp typed_literal?("true"), do: true
  defp typed_literal?("false"), do: true
  defp typed_literal?("null"), do: true
  defp typed_literal?(value), do: Regex.match?(~r/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/, value)

  defp numeric_like?(value), do: Regex.match?(~r/^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/, value)

  defp encode_float(value) when value == 0.0, do: "0"

  defp encode_float(value) do
    decimal =
      value
      |> Decimal.from_float()
      |> Decimal.normalize()

    if abs(value) >= 1.0e-6 and abs(value) < 1.0e21 do
      Decimal.to_string(decimal, :normal)
    else
      decimal
      |> Decimal.to_string(:scientific)
      |> String.replace("E", "e")
      |> String.replace("e+", "e")
    end
  end

  defp encode_quoted_string(value) do
    [?\", escape_string(value), ?\"]
    |> IO.iodata_to_binary()
  end

  defp escape_string(<<>>), do: []
  defp escape_string(<<char::utf8, rest::binary>>), do: [escape_char(char) | escape_string(rest)]

  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?"), do: "\\\""
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(char) when char < 0x20 or char in [0x2028, 0x2029], do: "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")
  defp escape_char(char), do: <<char::utf8>>

  defp primitive?(nil), do: true
  defp primitive?(value) when is_boolean(value) or is_number(value) or is_binary(value), do: true
  defp primitive?(_value), do: false

  defp reject_ambiguous_arrays!(%_{}), do: :ok
  defp reject_ambiguous_arrays!(%{} = value), do: Enum.each(value, fn {_key, field} -> reject_ambiguous_arrays!(field) end)

  defp reject_ambiguous_arrays!(list) when is_list(list) do
    if list != [] and List.ascii_printable?(list) do
      raise ArgumentError, "TOON cannot distinguish printable integer arrays from charlists; use compact JSON for this shape or convert text to binary strings"
    end

    Enum.each(list, &reject_ambiguous_arrays!/1)
  end

  defp reject_ambiguous_arrays!(_value), do: :ok

  defp indent(depth), do: String.duplicate("  ", depth)

  defp raise_unsupported(value) do
    raise ArgumentError, "unsupported TOON value type: #{value |> type_name()}"
  end

  defp type_name(%_{}), do: "struct"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(value) when is_pid(value), do: "pid"
  defp type_name(value) when is_reference(value), do: "reference"
  defp type_name(_value), do: "unknown"
end
