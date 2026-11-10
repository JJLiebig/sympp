defmodule SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt do
  @moduledoc false

  @custom_redirect_choice_id "__custom_redirect__"
  @top_level_keys ["tl_dr", "details", "options", "custom_redirect_label"]
  @option_keys ["id", "label", "description", "pros", "cons", "answer", "recommended"]

  @type option :: %{
          required(String.t()) => String.t() | [String.t()] | boolean()
        }
  @type t :: %{
          required(String.t()) => String.t() | [option()]
        }

  @spec custom_redirect_choice_id() :: String.t()
  def custom_redirect_choice_id, do: @custom_redirect_choice_id

  @spec normalize(term()) :: {:ok, t() | nil} | {:error, atom()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%{} = prompt) do
    prompt = stringify_keys(prompt)

    with :ok <- reject_unknown_keys(prompt, @top_level_keys),
         {:ok, tl_dr} <- required_trimmed_string(prompt, "tl_dr"),
         {:ok, details} <- required_trimmed_string(prompt, "details"),
         {:ok, options} <- normalized_options(Map.get(prompt, "options")),
         {:ok, custom_redirect_label} <- optional_trimmed_string(prompt, "custom_redirect_label") do
      prompt =
        %{"tl_dr" => tl_dr, "details" => details, "options" => options}
        |> maybe_put("custom_redirect_label", custom_redirect_label)

      {:ok, prompt}
    end
  end

  def normalize(_prompt), do: {:error, :must_be_map}

  @spec error_message(atom()) :: String.t()
  def error_message(:blank_string), do: "must contain nonblank strings"
  def error_message(:duplicate_option_id), do: "must contain unique option ids"
  def error_message(:invalid_list), do: "must contain string lists"
  def error_message(:invalid_options), do: "must contain 1 to 4 options"
  def error_message(:invalid_recommended), do: "recommended must be a boolean"
  def error_message(:multiple_recommended_options), do: "at most one option may be recommended"
  def error_message(:must_be_map), do: "must be a map"
  def error_message(:option_must_be_map), do: "options must be maps"
  def error_message(:reserved_option_id), do: "contains a reserved option id"
  def error_message(:unknown_key), do: "contains unknown keys"
  def error_message(_reason), do: "is invalid"

  @spec answer_text(term(), map()) :: String.t()
  def answer_text(decision_prompt, params) when is_map(params) do
    case answer_text_result(decision_prompt, params) do
      {:ok, answer} -> answer
      {:error, _reason} -> ""
    end
  end

  @type answer_error :: :invalid_answer_choice | :missing_answer | :missing_custom_redirect_note

  @spec answer_text_result(term(), map()) :: {:ok, String.t()} | {:error, answer_error()}
  def answer_text_result(decision_prompt, params) when is_map(params) do
    params = stringify_keys(params)

    case normalize(decision_prompt) do
      {:ok, prompt} when is_map(prompt) -> structured_answer_text_result(prompt, params)
      _not_structured -> legacy_answer_text_result(decision_prompt, params)
    end
  end

  def answer_text_result(_decision_prompt, _params), do: {:error, :missing_answer}

  defp structured_answer_text_result(prompt, params) do
    choice = trimmed_string_value(Map.get(params, "answer_choice"))
    note = trimmed_string_value(Map.get(params, "answer_note"))
    choice_answer_text_result(prompt, choice, note)
  end

  defp legacy_answer_text_result(decision_prompt, params) do
    case trimmed_string(Map.get(params, "answer")) do
      {:ok, answer} ->
        {:ok, answer}

      :error ->
        choice = trimmed_string_value(Map.get(params, "answer_choice"))
        note = trimmed_string_value(Map.get(params, "answer_note"))
        choice_answer_text_result(decision_prompt, choice, note)
    end
  end

  defp choice_answer_text_result(decision_prompt, nil, nil) do
    case normalize(decision_prompt) do
      {:ok, prompt} when is_map(prompt) -> {:error, :missing_answer}
      _error -> {:ok, ""}
    end
  end

  defp choice_answer_text_result(_decision_prompt, @custom_redirect_choice_id, nil),
    do: {:error, :missing_custom_redirect_note}

  defp choice_answer_text_result(decision_prompt, "redirect", nil) do
    case normalize(decision_prompt) do
      {:ok, prompt} when is_map(prompt) -> choice_answer_base(prompt, "redirect")
      _error -> {:error, :missing_custom_redirect_note}
    end
  end

  defp choice_answer_text_result(_decision_prompt, @custom_redirect_choice_id, note), do: {:ok, note}

  defp choice_answer_text_result(decision_prompt, choice, note) do
    with {:ok, base} <- choice_answer_base(decision_prompt, choice) do
      {:ok, append_note(base, note)}
    end
  end

  defp choice_answer_base(decision_prompt, choice) do
    case normalize(decision_prompt) do
      {:ok, prompt} when is_map(prompt) -> prompt_choice_answer_from_prompt(prompt, choice)
      _error -> {:ok, generic_choice_answer(choice)}
    end
  end

  defp normalized_options(options) when is_list(options) and length(options) in 1..4 do
    with {:ok, options} <- normalize_option_list(options),
         :ok <- reject_duplicate_option_ids(options),
         :ok <- reject_multiple_recommended_options(options) do
      {:ok, options}
    end
  end

  defp normalized_options(_options), do: {:error, :invalid_options}

  defp normalize_option_list(options) do
    options
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, normalized} ->
      case normalize_option(option) do
        {:ok, option} -> {:cont, {:ok, [option | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_option(%{} = option) do
    option = stringify_keys(option)

    with :ok <- reject_unknown_keys(option, @option_keys),
         {:ok, id} <- required_trimmed_string(option, "id"),
         :ok <- reject_reserved_option_id(id),
         {:ok, label} <- required_trimmed_string(option, "label"),
         {:ok, answer} <- required_trimmed_string(option, "answer"),
         {:ok, description} <- optional_trimmed_string(option, "description"),
         {:ok, pros} <- optional_string_list(option, "pros"),
         {:ok, cons} <- optional_string_list(option, "cons"),
         {:ok, recommended} <- optional_recommended(option) do
      %{"id" => id, "label" => label, "answer" => answer}
      |> maybe_put("description", description)
      |> maybe_put("pros", pros)
      |> maybe_put("cons", cons)
      |> maybe_put("recommended", recommended)
      |> then(&{:ok, &1})
    end
  end

  defp normalize_option(_option), do: {:error, :option_must_be_map}

  defp optional_recommended(option) do
    case Map.fetch(option, "recommended") do
      :error -> {:ok, nil}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_recommended}
    end
  end

  defp reject_multiple_recommended_options(options) do
    if Enum.count(options, &(Map.get(&1, "recommended") == true)) <= 1 do
      :ok
    else
      {:error, :multiple_recommended_options}
    end
  end

  defp reject_reserved_option_id(@custom_redirect_choice_id), do: {:error, :reserved_option_id}
  defp reject_reserved_option_id(_id), do: :ok

  defp reject_duplicate_option_ids(options) do
    option_ids = Enum.map(options, &Map.fetch!(&1, "id"))

    if Enum.uniq(option_ids) == option_ids do
      :ok
    else
      {:error, :duplicate_option_id}
    end
  end

  defp reject_unknown_keys(map, allowed_keys) do
    if map |> Map.keys() |> Enum.all?(&(&1 in allowed_keys)) do
      :ok
    else
      {:error, :unknown_key}
    end
  end

  defp required_trimmed_string(map, key) do
    case trimmed_string(Map.get(map, key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :blank_string}
    end
  end

  defp optional_trimmed_string(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> optional_trimmed_string_value(value)
    end
  end

  defp optional_trimmed_string_value(value) do
    case trimmed_string(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :blank_string}
    end
  end

  defp optional_string_list(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, values} when is_list(values) ->
        normalize_string_list(values)

      {:ok, _value} ->
        {:error, :invalid_list}
    end
  end

  defp normalize_string_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case trimmed_string(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, {:error, :invalid_list}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_choice_answer_from_prompt(_prompt, nil), do: {:error, :missing_answer}

  defp prompt_choice_answer_from_prompt(prompt, choice) do
    case Enum.find(prompt["options"], &(Map.get(&1, "id") == choice)) do
      nil -> {:error, :invalid_answer_choice}
      option -> {:ok, option["answer"]}
    end
  end

  defp generic_choice_answer("narrow"), do: "Narrow the scope before continuing."
  defp generic_choice_answer("redirect"), do: "No. Change direction before continuing."
  defp generic_choice_answer(@custom_redirect_choice_id), do: generic_choice_answer("redirect")
  defp generic_choice_answer(_choice), do: "Continue with the proposed direction."

  defp append_note(base, nil), do: base
  defp append_note(base, ""), do: base
  defp append_note(base, note), do: "#{base} #{note}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp trimmed_string(_value), do: :error

  defp trimmed_string_value(value) do
    case trimmed_string(value) do
      {:ok, trimmed} -> trimmed
      :error -> nil
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested(value)} end)
  end

  defp stringify_nested(%{} = map), do: stringify_keys(map)
  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value
end
