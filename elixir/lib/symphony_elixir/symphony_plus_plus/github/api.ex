defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.Api do
  @moduledoc """
  The Observer's GitHub HTTP access: GraphQL and ETag-cached REST reads.

  The token comes from `GITHUB_TOKEN` or `GH_TOKEN`, else from `gh auth token`,
  read once and kept until GitHub answers 401. Requests go out over HTTP; `gh`
  is never spawned per request. Every request passes the `RateGovernor`, and
  rate-limit refusals (403 or 429) come back as `{:rate_limited, until_ms}`,
  distinct from other refusals. Conditional REST reads keep `{etag, body}` in
  ETS keyed by `{credential, path}`; a 304 costs no budget.

  The HTTP request function is the `:sympp_github_request` application setting
  (tests replace it); it receives `%{method:, url:, headers:, body:}` and
  returns `{:ok, %{status:, headers:, body:}}` or `{:error, reason}`.
  """

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.RateGovernor
  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox

  @api "https://api.github.com"
  @token_key {__MODULE__, :token}
  @etag_table Module.concat(__MODULE__, ETags)
  @timeout_ms 10_000
  @missing_token_retry_ms 5 * 60_000
  @etag_entries 512

  @type priority :: RateGovernor.priority()
  @type error ::
          :offline
          | :github_token_required
          | :unauthorized
          | :forbidden
          | :not_found
          | {:rate_limited, integer()}
          | {:github_status, integer()}
          | :request_failed

  @doc "Creates the ETag table; the owning process keeps it alive."
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@etag_table) == :undefined do
      :ets.new(@etag_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  @doc "Whether a token is available (reads `gh auth token` at most once)."
  @spec credential() :: {:ok, String.t()} | {:error, :offline | :github_token_required}
  def credential do
    with :ok <- online(), do: stored_token(:persistent_term.get(@token_key, nil))
  end

  defp stored_token(token) when is_binary(token), do: {:ok, token}

  defp stored_token({:missing, at_ms}) do
    if now_ms() - at_ms < @missing_token_retry_ms, do: {:error, :github_token_required}, else: load_token()
  end

  defp stored_token(nil), do: load_token()

  @doc "Runs a GraphQL document and returns its `data`."
  @spec graphql(String.t(), map(), priority()) :: {:ok, map()} | {:error, error()}
  def graphql(query, variables, priority \\ :background) when is_binary(query) and is_map(variables) do
    body = Jason.encode!(%{query: query, variables: variables})

    with {:ok, token} <- credential(),
         :ok <- RateGovernor.allow(fingerprint(token), "graphql", priority),
         {:ok, response} <- send_request(token, :post, @api <> "/graphql", [], body),
         {:ok, body} <- handle(token, response) do
      case body do
        %{"data" => %{} = data} -> {:ok, data}
        _no_data -> {:error, :request_failed}
      end
    end
  end

  @doc "A conditional REST GET under `repos/`; a 304 returns the cached body."
  @spec rest_get(String.t(), priority()) :: {:ok, map() | list()} | {:error, error()}
  def rest_get("repos/" <> _rest = path, priority \\ :background) do
    with {:ok, token} <- credential(),
         credential = fingerprint(token),
         :ok <- RateGovernor.allow(credential, "core", priority) do
      cached = cached(credential, path)
      conditional = if cached, do: [{"if-none-match", elem(cached, 0)}], else: []

      with {:ok, response} <- send_request(token, :get, @api <> "/" <> path, conditional, nil),
           do: revalidated(token, credential, path, cached, response)
    end
  end

  defp revalidated(_token, credential, _path, {_etag, body}, %{status: 304} = response) do
    RateGovernor.record(credential, response.headers)
    {:ok, body}
  end

  defp revalidated(token, credential, path, _cached, response) do
    with {:ok, body} <- handle(token, response) do
      store(credential, path, header(response.headers, "etag"), body)
      {:ok, body}
    end
  end

  @doc false
  @spec forget_token() :: :ok
  def forget_token do
    :persistent_term.erase(@token_key)
    :ok
  end

  defp online do
    if OfflineSandbox.enabled?(), do: {:error, :offline}, else: :ok
  end

  defp load_token do
    token =
      [System.get_env("GITHUB_TOKEN"), System.get_env("GH_TOKEN")]
      |> Enum.find_value(&nonblank/1)
      |> Kernel.||(gh_auth_token())

    if token do
      :persistent_term.put(@token_key, token)
      {:ok, token}
    else
      # Without a token, `gh auth token` is asked again only every few minutes.
      :persistent_term.put(@token_key, {:missing, now_ms()})
      {:error, :github_token_required}
    end
  end

  defp gh_auth_token do
    runner = Application.get_env(:symphony_elixir, :sympp_gh_token_command, &run_gh_auth_token/0)
    runner.()
  end

  defp run_gh_auth_token do
    with gh when is_binary(gh) <- System.find_executable("gh") do
      task = Task.async(fn -> System.cmd(gh, ["auth", "token", "--hostname", "github.com"], stderr_to_stdout: false) end)

      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> nonblank(output)
        _failed -> nil
      end
    end
  rescue
    _error -> nil
  end

  defp send_request(token, method, url, extra_headers, body) do
    headers =
      [
        {"authorization", "Bearer " <> token},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "symphony-plus-plus"},
        {"x-github-api-version", "2022-11-28"}
      ] ++ extra_headers

    request = Application.get_env(:symphony_elixir, :sympp_github_request, &req_request/1)

    case request.(%{method: method, url: url, headers: headers, body: body}) do
      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, %{response | headers: normalize_headers(Map.get(response, :headers, %{}))}}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp req_request(%{method: method, url: url, headers: headers, body: body}) do
    options = [method: method, url: url, headers: headers, retry: false]
    options = options ++ [receive_timeout: @timeout_ms, connect_options: [timeout: @timeout_ms]]
    options = if body, do: Keyword.put(options, :body, body), else: options

    case Req.request(options) do
      {:ok, %Req.Response{} = response} -> {:ok, Map.take(response, [:status, :headers, :body])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle(token, %{status: status, headers: headers, body: body}) do
    credential = fingerprint(token)
    body = decode(body)

    cond do
      status in 200..299 ->
        RateGovernor.record(credential, headers)
        {:ok, body}

      RateGovernor.rate_limited?(status, headers, body) ->
        {:error, {:rate_limited, RateGovernor.penalize(credential, headers)}}

      status == 401 ->
        # The token was revoked or rotated: read it again next time.
        forget_token()
        {:error, :unauthorized}

      true ->
        RateGovernor.record(credential, headers)
        {:error, status_error(status)}
    end
  end

  defp status_error(403), do: :forbidden
  defp status_error(404), do: :not_found
  defp status_error(status), do: {:github_status, status}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode(body), do: body

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), List.wrap(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.update(acc, String.downcase(to_string(name)), [value], &(&1 ++ [value]))
    end)
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      _missing -> nil
    end
  end

  defp cached(credential, path) do
    if :ets.whereis(@etag_table) != :undefined do
      case :ets.lookup(@etag_table, {credential, path}) do
        [{_key, etag, body}] -> {etag, body}
        [] -> nil
      end
    end
  end

  defp store(_credential, _path, nil, _body), do: :ok

  defp store(credential, path, etag, body) do
    if :ets.whereis(@etag_table) != :undefined do
      # Paths carry head SHAs, so old entries are never asked for again.
      if :ets.info(@etag_table, :size) >= @etag_entries, do: :ets.delete_all_objects(@etag_table)
      :ets.insert(@etag_table, {{credential, path}, etag, body})
    end

    :ok
  end

  # Credentials are keyed by a digest, so the token itself never sits in ETS keys.
  defp fingerprint(token), do: :crypto.hash(:sha256, token) |> binary_part(0, 12) |> Base.encode16(case: :lower)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil
end
