defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Config do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @default_repo_root __DIR__ |> Path.join("../../../../..") |> Path.expand()
  @source_revision_key {__MODULE__, :source_revision}

  @enforce_keys [:mode, :repo, :version]
  defstruct [
    :mode,
    :repo,
    :version,
    :source_revision,
    :database,
    :repo_root,
    health_ledger_mode: :live,
    local_daemon_trusted: false
  ]

  @type t :: %__MODULE__{
          mode: :stdio | :http,
          repo: module(),
          version: String.t(),
          source_revision: String.t() | nil,
          database: String.t() | nil,
          repo_root: String.t() | nil,
          health_ledger_mode: :live | :configured_identity,
          local_daemon_trusted: boolean()
        }

  @switches [
    database: :string,
    mode: :string,
    repo_root: :string,
    help: :boolean
  ]

  @spec default(keyword()) :: t()
  def default(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :stdio),
      repo: Keyword.get(opts, :repo, Repo),
      version: Keyword.get(opts, :version, application_version()),
      source_revision: Keyword.get_lazy(opts, :source_revision, &source_revision/0),
      database: Keyword.get(opts, :database),
      repo_root: Keyword.get(opts, :repo_root),
      health_ledger_mode: Keyword.get(opts, :health_ledger_mode, :live),
      local_daemon_trusted: Keyword.get(opts, :local_daemon_trusted, false)
    }
  end

  @doc false
  @spec source_revision() :: String.t() | nil
  def source_revision do
    case :persistent_term.get(@source_revision_key, :unset) do
      :unset ->
        revision = load_source_revision()
        :persistent_term.put(@source_revision_key, revision)
        revision

      revision ->
        revision
    end
  end

  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()} | :help
  def parse(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          :help
        else
          parse_options(opts)
        end

      {_opts, _argv, _invalid} ->
        {:error, usage()}
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.mcp [--mode stdio] [--database <sqlite-path>] [--repo-root <path>]",
      Repo.default_database_help_text()
    ]
    |> Enum.join("\n")
  end

  defp parse_options(opts) do
    with {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, "stdio")),
         {:ok, repo_root} <- optional_nonblank(opts, :repo_root) do
      {:ok,
       default(
         mode: mode,
         database: Keyword.get(opts, :database),
         repo_root: expand_optional_path(repo_root)
       )}
    end
  end

  defp parse_mode("stdio"), do: {:ok, :stdio}
  defp parse_mode(_mode), do: {:error, "Only STDIO MCP mode is supported for SYMPP-P3-001.\n#{usage()}"}

  defp optional_nonblank(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, usage()}, else: {:ok, value}

      {:ok, _value} ->
        {:error, usage()}

      :error ->
        {:ok, nil}
    end
  end

  defp expand_optional_path(nil), do: nil
  defp expand_optional_path(path), do: Path.expand(path)

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _missing -> "0.1.0"
    end
  end

  defp load_source_revision do
    env_revision = source_revision_from_env()

    if env_revision do
      env_revision
    else
      source_revision_from_git()
    end
  end

  defp source_revision_from_env do
    "SYMPP_SOURCE_REVISION"
    |> System.get_env()
    |> normalize_source_revision()
  end

  defp source_revision_from_git do
    with git when is_binary(git) <- System.find_executable("git") || System.find_executable("git.exe"),
         {revision, 0} <- System.cmd(git, ["-C", @default_repo_root, "rev-parse", "--verify", "HEAD"], stderr_to_stdout: true),
         revision when is_binary(revision) <- normalize_source_revision(revision) do
      revision
    else
      _missing_or_invalid -> nil
    end
  end

  defp normalize_source_revision(revision) when is_binary(revision) do
    revision = String.trim(revision)

    if revision =~ ~r/\A[0-9a-f]{40}\z/i do
      String.downcase(revision)
    end
  end

  defp normalize_source_revision(_revision), do: nil
end
