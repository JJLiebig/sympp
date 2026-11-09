defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.RateGovernor do
  @moduledoc """
  Header-driven GitHub rate limiting, per credential.

  Every answer records `x-ratelimit-remaining`, `x-ratelimit-limit`,
  `x-ratelimit-reset` and `x-ratelimit-resource`. Background reads stop while
  less than 10 % of a resource's budget remains; interactive reads may spend it
  down to 1. A 403 or 429 rate-limit answer pauses the credential until
  `retry-after` or the reset time, else for a backoff that starts at 30 s and
  doubles up to 15 min. A pause is only ever extended, never shortened, so a
  late success can't clear a newer pause. The backoff resets after the first
  successful answer once a pause has expired.

  State lives in a public ETS table owned by the `Observer`.
  """

  @table __MODULE__
  @background_floor 0.10
  @initial_backoff_ms 30_000
  @max_backoff_ms 15 * 60_000

  @type credential :: String.t()
  @type priority :: :background | :interactive
  @type headers :: %{optional(String.t()) => [String.t()] | String.t()}

  @doc "Creates the governor's table; the owning process keeps it alive."
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  @doc "Whether a request for `resource` may be sent now."
  @spec allow(credential(), String.t(), priority(), integer()) :: :ok | {:error, {:rate_limited, integer()}}
  def allow(credential, resource, priority, now_ms \\ now_ms()) do
    state = get(credential)

    cond do
      state.paused_until > now_ms ->
        {:error, {:rate_limited, state.paused_until}}

      exhausted?(Map.get(state.resources, resource), priority, now_ms) ->
        {:error, {:rate_limited, state.resources[resource].reset_ms}}

      true ->
        :ok
    end
  end

  defp exhausted?(%{remaining: remaining, limit: limit, reset_ms: reset_ms}, priority, now_ms) when reset_ms > now_ms do
    case priority do
      :background -> remaining < limit * @background_floor
      :interactive -> remaining < 1
    end
  end

  defp exhausted?(_resource, _priority, _now_ms), do: false

  @doc "Records the budget headers of a successful or ordinary failed answer."
  @spec record(credential(), headers(), integer()) :: :ok
  def record(credential, headers, now_ms \\ now_ms()) do
    state = get(credential)
    state = if state.paused_until <= now_ms, do: %{state | backoff_ms: nil}, else: state

    state =
      case budget(headers) do
        {resource, budget} -> put_in(state, [:resources, resource], budget)
        nil -> state
      end

    put(credential, state)
  end

  @doc """
  Records a 403 or 429 rate-limit answer and returns the time the credential is
  paused until.
  """
  @spec penalize(credential(), headers(), integer()) :: integer()
  def penalize(credential, headers, now_ms \\ now_ms()) do
    state = get(credential)

    state =
      case budget(headers) do
        {resource, budget} -> put_in(state, [:resources, resource], budget)
        nil -> state
      end

    {until_ms, backoff_ms} =
      case retry_after_ms(headers) || reset_wait_ms(headers, now_ms) do
        wait when is_integer(wait) -> {now_ms + wait, state.backoff_ms}
        nil -> next_backoff(state.backoff_ms, now_ms)
      end

    paused_until = max(state.paused_until, until_ms)
    put(credential, %{state | paused_until: paused_until, backoff_ms: backoff_ms})
    paused_until
  end

  @doc "Whether an answer is a rate-limit refusal (any 429, or a 403 that says so)."
  @spec rate_limited?(integer(), headers(), term()) :: boolean()
  def rate_limited?(429, _headers, _body), do: true

  def rate_limited?(403, headers, body) do
    header(headers, "retry-after") != nil or header(headers, "x-ratelimit-remaining") == "0" or
      (is_map(body) and is_binary(body["message"]) and String.contains?(String.downcase(body["message"]), "rate limit"))
  end

  def rate_limited?(_status, _headers, _body), do: false

  @doc false
  @spec reset(credential()) :: :ok
  def reset(credential) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, credential)
    :ok
  end

  @doc false
  @spec state(credential()) :: map()
  def state(credential), do: get(credential)

  defp next_backoff(nil, now_ms), do: {now_ms + @initial_backoff_ms, @initial_backoff_ms}

  defp next_backoff(previous_ms, now_ms) do
    backoff_ms = min(previous_ms * 2, @max_backoff_ms)
    {now_ms + backoff_ms, backoff_ms}
  end

  defp retry_after_ms(headers) do
    with value when is_binary(value) <- header(headers, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds * 1_000
    else
      _missing -> nil
    end
  end

  defp reset_wait_ms(headers, now_ms) do
    with "0" <- header(headers, "x-ratelimit-remaining"),
         reset_ms when is_integer(reset_ms) <- reset_ms(headers),
         true <- reset_ms > now_ms do
      reset_ms - now_ms
    else
      _not_exhausted -> nil
    end
  end

  defp budget(headers) do
    with remaining when is_binary(remaining) <- header(headers, "x-ratelimit-remaining"),
         limit when is_binary(limit) <- header(headers, "x-ratelimit-limit"),
         {remaining, ""} <- Integer.parse(remaining),
         {limit, ""} <- Integer.parse(limit),
         reset_ms when is_integer(reset_ms) <- reset_ms(headers) do
      {header(headers, "x-ratelimit-resource") || "core", %{remaining: remaining, limit: limit, reset_ms: reset_ms}}
    else
      _missing -> nil
    end
  end

  defp reset_ms(headers) do
    with value when is_binary(value) <- header(headers, "x-ratelimit-reset"),
         {seconds, ""} <- Integer.parse(value) do
      seconds * 1_000
    else
      _missing -> nil
    end
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _rest] when is_binary(value) -> value
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp get(credential) do
    empty = %{resources: %{}, paused_until: 0, backoff_ms: nil}

    if :ets.whereis(@table) == :undefined do
      empty
    else
      case :ets.lookup(@table, credential) do
        [{^credential, state}] -> state
        [] -> empty
      end
    end
  end

  defp put(credential, state) do
    create_table()
    :ets.insert(@table, {credential, state})
    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
