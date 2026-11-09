defmodule SymphonyElixir.SymphonyPlusPlus.Cards.Git do
  @moduledoc """
  A card terminal's GitHub repository, base branch and current branch, read
  with `git -C <cwd>` on the factory host, where the factory's herdr-core runs
  the terminals it lists.

  The repository (origin remote) and base branch (`origin/HEAD`) are cached
  per cwd for 5 minutes; the current branch is read on every call. A cwd whose origin isn't
  on GitHub has no card. The base is empty when `origin/HEAD` isn't set.
  """

  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity

  @cache_key {__MODULE__, :repositories}
  @timeout_ms 2_000
  @cache_ms 5 * 60_000

  @type t :: %{repository: String.t(), base_branch: String.t() | nil, branch: String.t() | nil}

  @spec read(String.t()) :: {:ok, t()} | :error
  def read(cwd) when is_binary(cwd) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, {repository, base}} <- repository(git, cwd) do
      {:ok, %{repository: repository, base_branch: base, branch: branch(git, cwd)}}
    else
      _unavailable -> :error
    end
  end

  defp repository(git, cwd) do
    cache = :persistent_term.get(@cache_key, %{})
    now = System.monotonic_time(:millisecond)

    case Map.fetch(cache, cwd) do
      {:ok, {entry, at}} when now - at < @cache_ms ->
        {:ok, entry}

      _missing_or_old ->
        with {:ok, entry} <- read_repository(git, cwd) do
          :persistent_term.put(@cache_key, Map.put(cache, cwd, {entry, now}))
          {:ok, entry}
        end
    end
  end

  defp read_repository(git, cwd) do
    with {:ok, origin} <- run(git, cwd, ["remote", "get-url", "origin"]),
         {:ok, {owner, name}} <- RepoIdentity.github_repository(origin) do
      {:ok, {owner <> "/" <> name, base(git, cwd)}}
    else
      _not_github -> :error
    end
  end

  defp base(git, cwd) do
    case run(git, cwd, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, "origin/" <> base} when base != "" -> base
      _unset -> nil
    end
  end

  # A detached HEAD has no branch.
  defp branch(git, cwd) do
    case run(git, cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, branch} when branch != "" -> branch
      _detached -> nil
    end
  end

  defp run(git, cwd, args) do
    task = Task.async(fn -> System.cmd(git, ["-C", cwd | args], stderr_to_stdout: false) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      _failed -> :error
    end
  rescue
    _error -> :error
  end
end
