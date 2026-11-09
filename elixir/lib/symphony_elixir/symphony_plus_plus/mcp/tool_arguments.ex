defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog

  @type arguments :: %{optional(String.t()) => term()}
  @type tool_call_result :: {:ok, arguments()} | {:error, integer(), String.t(), map()}
  @type tool_error :: {:tool_error, String.t()}

  @doc """
  Checks a call's arguments against the tool's one input schema: unknown keys
  are refused (sync_pr and dispatch_work_package drop them), and required
  arguments must be present with the right type.
  """
  @spec tool_arguments(map(), String.t()) :: tool_call_result()
  def tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> validate_arguments(name, arguments)
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec optional_string_argument(arguments(), String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | tool_error()
  def optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_string_list_argument(arguments(), String.t()) :: {:ok, [String.t()]} | tool_error()
  def optional_string_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          values =
            values
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          {:ok, values}
        else
          {:tool_error, "invalid_#{key}"}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_positive_integer_argument(arguments(), String.t()) :: {:ok, pos_integer() | nil} | tool_error()
  def optional_positive_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_nonnegative_integer_argument(arguments(), String.t()) :: {:ok, non_neg_integer() | nil} | tool_error()
  def optional_nonnegative_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec required_string_array(arguments(), String.t()) :: {:ok, [String.t()]} | tool_error()
  def required_string_array(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:tool_error, "invalid_#{key}"}
        end

      :error ->
        {:tool_error, "missing_#{key}"}

      {:ok, _values} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec required_argument(arguments(), String.t()) :: {:ok, String.t()} | tool_error()
  def required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  @spec required_object(arguments(), String.t()) :: {:ok, map()} | tool_error()
  def required_object(arguments, key) do
    case Map.get(arguments, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  @spec optional_object_argument(arguments(), String.t()) :: {:ok, map() | nil} | tool_error()
  def optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_list_argument(arguments(), String.t()) :: {:ok, list() | nil} | tool_error()
  def optional_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_boolean(arguments(), String.t(), boolean()) :: {:ok, boolean()} | tool_error()
  def optional_boolean(arguments, key, default) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
      :error -> {:ok, default}
    end
  end

  @spec optional_argument(arguments(), String.t(), term()) :: term()
  def optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  @spec validate_tool_required_arguments(map(), arguments()) :: :ok | {:error, String.t()}
  def validate_tool_required_arguments(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Enum.find_value(:ok, fn key ->
      case validate_required_argument(arguments, properties, key) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_arguments(name, arguments) do
    schema = ToolCatalog.input_schema(name)
    allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()
    arguments = if name in ["sync_pr", "dispatch_work_package"], do: Map.take(arguments, MapSet.to_list(allowed)), else: arguments
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(schema, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_required_argument(arguments, properties, key) do
    case Map.fetch(arguments, key) do
      :error -> {:error, "missing_#{key}"}
      {:ok, nil} -> {:error, "missing_#{key}"}
      {:ok, value} -> validate_required_argument_value(properties, key, value)
    end
  end

  defp validate_required_argument_value(properties, key, value) do
    case get_in(properties, [key, "type"]) do
      "string" -> validate_required_string_argument(key, value)
      "object" -> validate_required_object_argument(key, value)
      "array" -> validate_required_array_argument_value(properties, key, value)
      "integer" -> validate_required_integer_argument(properties, key, value)
      "boolean" when is_boolean(value) -> :ok
      _type -> {:error, "invalid_#{key}"}
    end
  end

  defp validate_required_string_argument(key, value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok
  end

  defp validate_required_string_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_object_argument(_key, value) when is_map(value), do: :ok
  defp validate_required_object_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_integer_argument(properties, key, value) when is_integer(value) do
    minimum = properties |> Map.get(key, %{}) |> Map.get("minimum")

    if is_integer(minimum) and value < minimum, do: {:error, "invalid_#{key}"}, else: :ok
  end

  defp validate_required_integer_argument(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_array_argument_value(properties, key, values) when is_list(values) do
    validate_required_array_argument(properties, key, values)
  end

  defp validate_required_array_argument_value(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_array_argument(properties, key, values) do
    cond do
      properties |> Map.get(key, %{}) |> Map.get("minItems", 0) > 0 and values == [] ->
        {:error, "missing_#{key}"}

      get_in(properties, [key, "items", "type"]) == "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      true ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
    end
  end
end
