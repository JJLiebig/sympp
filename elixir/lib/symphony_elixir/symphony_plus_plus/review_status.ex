defmodule SymphonyElixir.SymphonyPlusPlus.ReviewStatus do
  @moduledoc """
  Reads a package's Review Suite cycle by the `review_id` dispatch minted.

  Review Suite keeps its state on the machine that ran the review, so the read
  runs on the worker's machine: directly when that is the factory host, else
  through `hc exec --on <machine>`. It runs `review.py --id <id> --show-status
  --json` from the installed review-suite skill with a 3 s limit.

  Results:
    * `{:ok, review}` - the cycle's public status;
    * `:not_started` - the host answered and has no cycle with that id yet;
    * `:unknown` - the host, the script or its answer was unusable.

  The command runner is the `:sympp_review_command` application setting:
  `nil` disables reads (every result is `:unknown`), or a function
  `(command, args, timeout_ms) -> {:ok, {output, exit_status}} | :error`, where
  `command` is `"python3"` or `"hc"`.
  """

  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore

  @timeout_ms 3_000
  @max_output_bytes 256_000
  @script_path ".agents/skills/review-suite/plugins/review-suite/scripts/review.py"
  @plugin_glob "plugins/cache/review-suite/review-suite/*/scripts/review.py"
  @list_limit 20
  @string_limit 240

  @type result :: {:ok, map()} | :not_started | :unknown

  @spec read(String.t(), String.t() | nil) :: result()
  def read(review_id, machine) when is_binary(review_id) do
    case Application.get_env(:symphony_elixir, :sympp_review_command, &run/3) do
      nil -> :unknown
      runner when is_function(runner, 3) -> read_with(runner, review_id, machine)
    end
  end

  defp read_with(runner, review_id, machine) do
    if local?(machine), do: read_local(runner, review_id), else: read_remote(runner, review_id, machine)
  end

  defp local?(machine), do: machine in [nil, ""] or machine == HerdrCore.machine_name()

  defp read_local(runner, review_id) do
    case runner.("python3", [local_script(), "--id", review_id, "--show-status", "--json"], @timeout_ms) do
      {:ok, {output, status}} -> parse(output, status)
      _unavailable -> :unknown
    end
  end

  # Review Suite installed as a skill, else as the Codex marketplace plugin.
  # Every install reads the same state directory on that machine.
  defp local_script do
    home = System.user_home!()
    codex_home = nonblank(System.get_env("CODEX_HOME")) || Path.join(home, ".codex")
    plugins = codex_home |> Path.join(@plugin_glob) |> Path.wildcard() |> Enum.sort(:desc)

    Enum.find([Path.join(home, @script_path) | plugins], Path.join(home, @script_path), &File.regular?/1)
  end

  defp read_remote(runner, review_id, machine) do
    command =
      ~s(for s in "$HOME/#{@script_path}" "${CODEX_HOME:-$HOME/.codex}"/#{@plugin_glob}; do ) <>
        ~s([ -f "$s" ] && exec python3 "$s" --id "$1" --show-status --json; done; exit 127)

    args = ["exec", "--json", "--on", machine, "--timeout", "3", "--", "sh", "-c", command, "sh", review_id]

    with {:ok, {output, 0}} <- runner.("hc", args, @timeout_ms + 2_000),
         {:ok, %{"code" => status, "stdout" => stdout, "timed_out" => false}} when is_integer(status) <- Jason.decode(output),
         {:ok, decoded} <- Base.decode64(stdout) do
      parse(decoded, status)
    else
      _unavailable -> :unknown
    end
  end

  defp parse(output, 0) do
    case Jason.decode(output) do
      {:ok, %{"review" => review} = payload} when is_binary(review) -> {:ok, normalize(payload)}
      _unusable -> :unknown
    end
  end

  defp parse(output, 2) do
    case Jason.decode(output) do
      {:ok, %{"error" => "unknown review cycle id" <> _rest}} -> :not_started
      _unusable -> :unknown
    end
  end

  defp parse(_output, _status), do: :unknown

  @doc """
  The review state that qualification reads: `:done` only when the cycle is
  done for `head_sha` and Review Suite doesn't report it failed, stale or
  invalidated.
  """
  @spec state(result(), String.t() | nil) :: :done | :pending | :unknown
  def state({:ok, %{"done" => true, "status" => "passed", "reviewed_head" => reviewed}}, head) when is_binary(reviewed) and is_binary(head) do
    if String.starts_with?(head, reviewed) or String.starts_with?(reviewed, head), do: :done, else: :pending
  end

  def state({:ok, _review}, _head), do: :pending
  def state(:not_started, _head), do: :pending
  def state(_unknown, _head), do: :unknown

  defp normalize(payload) do
    %{
      "evidence_id" => text(payload["review"]),
      "mode" => text(payload["mode"]),
      "status" => observed_status(payload),
      "provider_status" => text(payload["status"]),
      "done" => payload["done"] == true,
      "reviewed_head" => text(payload["head"]),
      "next_action" => text(payload["next_action"]),
      "round" => non_negative(payload["rounds"]),
      "step" => text(payload["current"]),
      "steps" => list(payload["steps"], ~w(index name state)),
      "round_history" => list(payload["round_history"], ~w(number lane step status outcome findings started_at finished_at)),
      "started_at" => text(payload["started_at"]),
      "round_started_at" => text(payload["round_started_at"]),
      "validation" => validation(payload["validation"]),
      "observed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> Map.merge(progress(payload["progress"]))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp observed_status(payload) do
    case {payload["done"], payload["status"]} do
      {_done, "head_changed_after_review"} -> "inspection_needed"
      {_done, status} when status in ["stale", "fix-pending", "failed", "invalidated"] -> "failed"
      {_done, "done"} -> "passed"
      {true, _status} -> "passed"
      _active -> "in_progress"
    end
  end

  defp progress(value) when is_binary(value) do
    case Regex.run(~r/(\d+)\/(\d+)/, value) do
      [_match, current, total] -> %{"current" => String.to_integer(current), "total" => String.to_integer(total)}
      nil -> %{}
    end
  end

  defp progress(_value), do: %{}

  defp validation(%{} = value), do: value |> Map.take(~w(focused full_suite ci review_green note)) |> Map.new(fn {key, val} -> {key, text(val)} end)
  defp validation(_value), do: nil

  defp list(values, keys) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.take(-@list_limit)
    |> Enum.map(fn item -> item |> Map.take(keys) |> Map.new(fn {key, val} -> {key, if(is_binary(val), do: text(val), else: val)} end) end)
  end

  defp list(_values, _keys), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil

  defp nonblank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp nonblank(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @string_limit)
    end
  end

  defp text(_value), do: nil

  defp run(name, args, timeout_ms) do
    case executable(name) do
      nil ->
        :error

      executable ->
        port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :hide, args: args])
        collect(port, "", System.monotonic_time(:millisecond) + timeout_ms)
    end
  rescue
    _error -> :error
  end

  defp executable("hc"), do: HerdrCore.command_path()
  defp executable("python3"), do: System.find_executable("python3") || System.find_executable("python")

  defp collect(port, output, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= @max_output_bytes ->
        collect(port, output <> data, deadline_ms)

      {^port, {:data, _excess}} ->
        close(port)

      {^port, {:exit_status, status}} ->
        {:ok, {output, status}}
    after
      remaining_ms -> close(port)
    end
  end

  defp close(port) do
    Port.close(port)
    :error
  catch
    _kind, _reason -> :error
  end
end
