# The factory runtime as the installed service runs it: the packaged
# supervision tree, including the Observer, on a disposable ledger. Only the
# outside world is replaced: GitHub's HTTP endpoint is the journey's loopback
# provider, and `hc`, `gh` and Review Suite are the journey's programs on PATH
# and under HOME. The journey owns the clock: a `sweep` or `terminals` line on
# stdin delivers that tick to the running Observer and answers once it ran.
alias SymphonyElixir.SymphonyPlusPlus.Observer

github = System.fetch_env!("ACCEPTANCE_GITHUB")
endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

Application.put_env(:symphony_elixir, :sympp_repo_database, System.fetch_env!("SYMPP_DATABASE"))
Application.put_env(:symphony_elixir, :server_port_override, 0)
Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(endpoint, sympp_local_operator: true))

Application.put_env(:symphony_elixir, :sympp_github_request, fn %{method: method, url: "https://api.github.com" <> path, headers: headers, body: body} ->
  options = [method: method, url: github <> path, headers: headers, retry: false, decode_body: false]

  case Req.request(if(body, do: Keyword.put(options, :body, body), else: options)) do
    {:ok, response} -> {:ok, Map.take(response, [:status, :headers, :body])}
    {:error, reason} -> {:error, reason}
  end
end)

{:ok, _started} = Application.ensure_all_started(:symphony_elixir)
IO.puts("sympp API bridge: http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}")

ticks = %{"sweep" => :sweep, "terminals" => :terminals}

Stream.repeatedly(fn -> IO.gets("") end)
|> Enum.reduce_while(:ok, fn
  :eof, _acc ->
    {:halt, :ok}

  line, _acc ->
    tick = String.trim(line)
    send(Observer, Map.fetch!(ticks, tick))
    # The Observer handles its mailbox in order, so this returns after the tick ran.
    :sys.get_state(Observer, 60_000)
    IO.puts("watcher: #{tick} done")
    {:cont, :ok}
end)

System.halt(0)
