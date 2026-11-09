# The factory runtime as the installed service runs it: the packaged
# supervision tree on a disposable ledger. Only the outside world and the
# clock are replaced: GitHub's HTTP endpoint is the journey's loopback provider,
# `hc`, `gh` and Review Suite are the journey's programs on PATH and under HOME,
# and the Observer's two passes run only when the journey asks. A `sweep` or
# `terminals` line on stdin runs that pass and answers once it finished.
alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, RateGovernor}
alias SymphonyElixir.SymphonyPlusPlus.{Observer, Repo}

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

# The supervised Observer would also run its passes on its own timers, between
# a journey's steps. This process runs the same passes instead, on request, and
# owns the GitHub tables the Observer process would own.
:ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Observer)
RateGovernor.create_table()
Api.create_table()

IO.puts("sympp API bridge: http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}")

passes = %{"sweep" => fn -> Observer.sweep(Repo) end, "terminals" => fn -> Observer.observe_terminals(Repo) end}

Stream.repeatedly(fn -> IO.gets("") end)
|> Enum.reduce_while(:ok, fn
  :eof, _acc ->
    {:halt, :ok}

  line, _acc ->
    tick = String.trim(line)
    :ok = Map.fetch!(passes, tick).()
    IO.puts("watcher: #{tick} done")
    {:cont, :ok}
end)

System.halt(0)
