defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkPackageLaunch do
  @moduledoc """
  The worker hand-off that follows a committed dispatch: prepare the factory
  worktree (idempotently), write the worker's assignment file under the
  worktree's git dir, and build the `hc run` line that launches the worker.

  The assignment file is outside the working tree, so it never shows up in the
  worker's diff. Rewriting it on a replay keeps it current with the contract.
  """

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, WorktreeScope}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch

  @agents ["codex", "claude"]
  @assignment_file "sympp-assignment.md"
  @shell_safe ~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/

  @type hand_off :: %{
          worktree: map(),
          assignment_file: String.t(),
          launch_line: String.t()
        }

  @doc "Agents a launch line can start."
  @spec agents() :: [String.t()]
  def agents, do: @agents

  @doc """
  Prepares the worktree, writes the assignment file and returns the launch line.
  `target_repo_root` overrides the checkout on a local factory; factories with a
  repos root choose the checkout themselves.
  """
  @spec hand_off(Config.t(), Terminal.t(), WorkPackage.t(), String.t(), String.t() | nil) ::
          {:ok, hand_off()} | {:error, term()} | {:tool_error, term()} | {:tool_error, String.t(), map()}
  def hand_off(%Config{} = config, %Terminal{} = terminal, %WorkPackage{} = work_package, agent, target_repo_root \\ nil) when agent in @agents do
    with {:ok, worktree} <- prepare_worktree(config, terminal, work_package, target_repo_root),
         {:ok, assignment} <- WorkPackageDispatch.assignment(config.repo, worktree.work_package),
         {:ok, file} <- write_assignment(worktree, work_package, assignment) do
      line = launch_line(work_package, worktree.worktree_path, file, agent)
      {:ok, %{worktree: worktree, assignment_file: file, launch_line: line}}
    end
  end

  defp prepare_worktree(config, terminal, %WorkPackage{} = work_package, explicit_root) do
    with {:ok, target_repo_root} <- WorktreeScope.prepare_target_repo_root(explicit_root, work_package, config),
         {:ok, branch} <- worktree_branch(work_package),
         {:ok, result} <-
           WorkPackageService.prepare_worktree(config.repo, work_package.id, %{
             "target_repo_root" => target_repo_root,
             "base_branch" => work_package.base_branch,
             "branch" => branch
           }),
         {:ok, _event} <- append_audit(config.repo, terminal, work_package.id, result) do
      {:ok, result}
    end
  end

  # A recorded worktree keeps its branch, even if the branch pattern changed
  # since; only a new worktree derives one.
  defp worktree_branch(%WorkPackage{worktree_path: path} = work_package) do
    case WorktreeScope.live_branch(path) do
      {:ok, branch} -> {:ok, branch}
      {:error, _missing_or_invalid} -> WorktreeScope.prepare_branch(work_package)
    end
  end

  defp append_audit(repo, %Terminal{} = terminal, work_package_id, result) do
    fingerprint =
      :sha256
      |> :crypto.hash([to_string(result.status), "\0", to_string(result.worktree_path), "\0", to_string(result.branch)])
      |> Base.url_encode64(padding: false)

    actor = Actor.from_terminal(terminal)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, actor, work_package_id, %{
      "summary" => if(result.status == "already_prepared", do: "WorkPackage worktree already prepared", else: "Prepared WorkPackage worktree"),
      "status" => result.status,
      "idempotency_key" => "worktree_lifecycle:dispatch_work_package:#{work_package_id}:#{fingerprint}",
      "payload" => %{
        "type" => "worktree_lifecycle",
        "source_tool" => "dispatch_work_package",
        "work_package_id" => work_package_id,
        # Local paths stay out of the shared ledger history.
        "worktree_path" => "[REDACTED]",
        "target_repo_root" => "[REDACTED]",
        "branch" => result.branch,
        "base_branch" => result.base_branch,
        "status" => result.status
      }
    })
  end

  defp write_assignment(worktree, %WorkPackage{} = work_package, assignment) do
    with {:ok, git_dir} <- git_dir(worktree.worktree_path),
         file = Path.join(git_dir, @assignment_file),
         :ok <- File.write(file, render_assignment(work_package, worktree, assignment)) do
      {:ok, file}
    else
      {:error, reason} -> {:error, {:assignment_write_failed, reason}}
    end
  end

  defp git_dir(worktree_path) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        case System.cmd(git, ["-C", worktree_path, "rev-parse", "--absolute-git-dir"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {_output, _status} -> {:error, :git_dir_unavailable}
        end
    end
  end

  @doc false
  @spec render_assignment(WorkPackage.t(), map(), map()) :: String.t()
  def render_assignment(%WorkPackage{} = work_package, worktree, assignment) do
    """
    # WorkPackage #{work_package.id}: #{Redactor.redact_text(work_package.title)}

    You are the worker for this sympp WorkPackage. Use the installed `sympp` skill and follow
    `references/symphony-worker/procedure.md` in it.

    - Work only in `#{worktree.worktree_path}`, on branch `#{worktree.branch}`, targeting `#{worktree.base_branch}`.
    - Keep the PR small and within the contract. Branch from `#{worktree.base_branch}`; never merge or cherry-pick
      another unmerged branch. Once handed off, leave the branch alone unless your parent asks.
    #{review_step(work_package, worktree.worktree_path)}
    - Make no sympp MCP calls. Message only your parent terminal: one final handoff with the PR URL, the
      exact head, check and review results, and remaining risks, plus questions or blockers. Never message
      any other chief or architect, and never send status or acknowledgements. Keep messages short.
    - Ask your parent when scope, product intent or a dependency is unclear. Never print or store secrets.

    ## Assignment

    ```toon
    #{WorkerContext.encode_tool_payload(assignment)}
    ```
    """
  end

  defp review_step(%WorkPackage{review_mode: "none"}, _worktree_path),
    do: "- No Review Suite review is required for this WorkPackage."

  defp review_step(%WorkPackage{review_mode: review_mode, review_id: review_id}, worktree_path) do
    mode = WorkPackage.review_suite_mode(review_mode)

    """
    - Review with Review Suite (`review.py` from the installed review-suite skill) under the id sympp
      minted for this package: run `review.py --id #{review_id} --mode #{mode} --cd #{shell_arg(worktree_path)}`
      once, then wait for it to finish. Repeating the same command resumes the same review, but two starts at once can both
      launch reviewers, so never start it again while it runs.\
    """
  end

  @doc false
  @spec launch_line(WorkPackage.t(), String.t(), String.t(), String.t()) :: String.t()
  def launch_line(%WorkPackage{} = work_package, worktree_path, assignment_file, agent) do
    review_label = if work_package.review_id, do: ["--label", "sympp.review_id=" <> work_package.review_id], else: []

    (["hc", "run", "--bg", "--on", work_package.launch_machine, "--cwd", worktree_path, "--name", terminal_name(work_package.id)] ++
       ["--label", "sympp.role=worker", "--label", "sympp.work_package_id=" <> work_package.id] ++ review_label ++ ["--", agent])
    |> Enum.map_join(" ", &shell_arg/1)
    |> Kernel.<>(" " <> prompt_arg(assignment_file))
  end

  # Herdr names are 1-32 characters of a-z, 0-9, - and _.
  defp terminal_name(work_package_id) do
    case work_package_id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "-") |> String.slice(0, 32) do
      "" -> "worker"
      name -> name
    end
  end

  defp prompt_arg(file) do
    if Regex.match?(@shell_safe, file), do: ~s("Read #{file}"), else: shell_arg("Read " <> file)
  end

  defp shell_arg(value) do
    if Regex.match?(@shell_safe, value), do: value, else: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
  end
end
