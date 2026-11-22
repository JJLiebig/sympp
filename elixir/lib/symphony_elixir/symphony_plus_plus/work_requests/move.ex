defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Move do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, DashboardPubSub, FactoryRepos, RepoIdentity}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{DefaultClient, PullRequest, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{Actor, ProgressEvent}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, Qualification}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Phase, Repository, WorkRequest}

  @spec run(module(), String.t(), map(), Terminal.t()) :: {:ok, map()} | {:error, term()}
  def run(repo, id, %{repo: destination} = attrs, %Terminal{} = terminal) do
    with {:ok, destination, destination_key} <- FactoryRepos.repository_scope(destination),
         {:ok, request} <- Repository.get(repo, id),
         :ok <- Phase.require_writable(request) do
      if stored_key(request.repo) == destination_key do
        {:ok, result("unchanged", request, [])}
      else
        target = %{attrs | repo: destination, base_branch: BaseBranch.canonicalize(attrs.base_branch)}
        move(repo, request, Map.put(target, :key, destination_key), terminal)
      end
    end
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  defp move(repo, request, target, terminal) do
    with :ok <- validate_base_branch(target.base_branch),
         {:ok, packages} <- Repository.list_work_packages(repo, request.id),
         keys = repository_keys(request.repo, packages),
         {:ok, source} <- move_scope(repo, request.repo, packages, keys, target.key) do
      # Resolve checkout origins and GitHub's canonical name before the write.
      # The proof covers any newer attachment from the same source repository.
      renamed_to = confirmed_rename(repo, source.key, target.key, source.attachments)
      target = Map.put(target, :renamed_to, renamed_to)

      result =
        repo.transact(
          fn -> apply_move(repo, request.id, source, target, terminal) end,
          mode: :immediate
        )

      case result do
        {:ok, %{"status" => "moved"}} = moved -> DashboardPubSub.broadcast_changed_on_success(moved)
        other -> other
      end
    end
  end

  defp apply_move(repo, id, source, target, terminal) do
    with {:ok, current} <- Repository.get(repo, id),
         :ok <- Phase.require_writable(current) do
      cond do
        stored_key(current.repo) == target.key -> {:ok, result("unchanged", current, [])}
        current.repo == source.repo -> persist_move(repo, current, source, target, terminal)
        true -> {:error, :work_request_scope_changed}
      end
    end
  end

  defp persist_move(repo, request, source, target, terminal) do
    base = target.base_branch || request.base_branch
    allowed_source = if target.renamed_to, do: source.key

    with {:ok, current_packages} <- Repository.list_work_packages(repo, request.id),
         {:ok, current} <- move_scope(repo, source.repo, current_packages, source.keys, target.key),
         true <- current.key == source.key,
         %{packages: packages, attachments: attachments} = current,
         :ok <- require_portable_attachments(attachments, allowed_source, target.key),
         {:ok, updated} <- repo.update(Changeset.change(request, repo: target.repo, base_branch: base)),
         {:ok, decision} <- record_decision(repo, request, updated, target.rationale, terminal),
         :ok <- move_packages(repo, packages, attachments, request, updated),
         :ok <- move_attachments(repo, attachments, source.key, target.renamed_to, decision.id, terminal) do
      if target.renamed_to, do: carry_ci(repo, source.key, target.key)
      {:ok, result("moved", updated, packages)}
    else
      false -> {:error, :work_request_scope_changed}
      {:error, _reason} = error -> error
    end
  end

  defp repository_keys(request_repo, packages) do
    values = [request_repo | for(package <- packages, not Lifecycle.ended?(package), do: package.repo)]
    values |> Enum.uniq() |> Map.new(&{&1, scope_key(&1)})
  end

  defp move_scope(repo, request_repo, packages, keys, destination) do
    open = Enum.reject(packages, &Lifecycle.ended?/1)

    with true <- Enum.all?(open, &Map.has_key?(keys, &1.repo)),
         {:ok, attachments} <- PlanningRepository.pr_attachments(repo, Enum.map(open, & &1.id)),
         {:ok, source} <- source_key(request_repo, open, keys, attachments, destination) do
      moving = Enum.filter(open, &moves?(&1, request_repo, source, keys, attachments[&1.id]))
      links = Map.take(attachments, Enum.map(moving, & &1.id))
      {:ok, %{repo: request_repo, key: source, keys: keys, packages: moving, attachments: links}}
    else
      false -> {:error, :work_request_scope_changed}
      {:error, _reason} = error -> error
    end
  end

  defp source_key(request_repo, open, keys, attachments, destination) do
    case stored_key(request_repo) do
      {:stored, _path} -> checkout_source_key(request_repo, open, keys, attachments, destination)
      key -> {:ok, key}
    end
  end

  # A checkout's origin can be edited before the move. For a request scoped to
  # that checkout, attachments on packages with the same scope are evidence of
  # its previous repository. A conflicting origin by itself cannot settle it.
  defp checkout_source_key(request_repo, open, keys, attachments, destination) do
    recorded =
      for package <- open,
          package.repo == request_repo,
          key = attachment_key(attachments[package.id]),
          not is_nil(key),
          uniq: true,
          do: key

    case recorded do
      [key] -> require_unambiguous_source(key, open, keys, destination)
      [] -> require_unambiguous_source(Map.fetch!(keys, request_repo), open, keys, destination)
      _different_repos -> {:error, :ambiguous_source_repository}
    end
  end

  defp require_unambiguous_source(source, open, keys, destination) do
    unresolved? = source == destination or match?({:stored, _}, source)

    if unresolved? and Enum.any?(open, &(Map.fetch!(keys, &1.repo) != source)),
      do: {:error, :ambiguous_source_repository},
      else: {:ok, source}
  end

  defp moves?(package, request_repo, source, keys, attachment) do
    package.repo == request_repo or Map.fetch!(keys, package.repo) == source or
      (match?({:stored, _}, stored_key(package.repo)) and attachment_key(attachment) == source)
  end

  defp attachment_key({:ok, %{ref: ref}}), do: stored_key(ref.repository)
  defp attachment_key(_missing), do: nil

  defp scope_key(value) do
    case stored_key(value) do
      {:stored, _} = key ->
        case RepoIdentity.local_git_origin_remote(value) do
          nil -> key
          origin -> stored_key(origin)
        end

      key ->
        key
    end
  end

  defp stored_key(value) do
    case FactoryRepos.repository_scope(value) do
      {:ok, _scope, key} -> key
      {:error, :invalid_repo_remote} -> {:stored, value}
    end
  end

  # GitHub's old repository endpoint follows the rename and returns the
  # canonical full name. A matching PR number or head alone cannot prove this.
  defp confirmed_rename(repo, {:github, source}, {:github, destination}, attachments) when source != destination do
    needs_proof? = map_size(attachments) > 0 or Qualification.repository_has_ci?(repo, source)

    with true <- needs_proof?,
         {:ok, %{"id" => id, "full_name" => canonical}} <- DefaultClient.get_json("repos/#{source}", []),
         true <- is_integer(id) and id > 0 and is_binary(canonical),
         true <- String.downcase(canonical) == destination do
      canonical
    else
      _unverified -> nil
    end
  end

  defp confirmed_rename(_repo, _source, _destination, _attachments), do: nil

  defp require_portable_attachments(attachments, allowed_source, destination) do
    blockers =
      for {id, attachment} <- Enum.sort(attachments),
          not portable_attachment?(attachment, allowed_source, destination) do
        url =
          case attachment do
            {:ok, %{ref: ref}} -> ref.url
            {:error, _reason} -> nil
          end

        %{"work_package_id" => id, "pr_url" => url}
      end

    if blockers == [], do: :ok, else: {:error, {:attached_pull_requests, blockers}}
  end

  defp portable_attachment?({:ok, _ref} = attachment, allowed_source, destination),
    do: attachment_key(attachment) in [allowed_source, destination]

  defp portable_attachment?({:error, _reason}, _allowed_source, _destination), do: false

  defp move_packages(repo, packages, attachments, request, destination) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      base =
        if inherits_base?(package, request, destination, attachments),
          do: destination.base_branch,
          else: package.base_branch

      changeset =
        Changeset.change(package, %{
          repo: destination.repo,
          base_branch: base,
          contract_revision: package.contract_revision + 1
        })

      case repo.update(changeset) do
        {:ok, _package} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp inherits_base?(package, request, destination, attachments) do
    destination.base_branch != request.base_branch and
      is_nil(package.worktree_path) and not Map.has_key?(attachments, package.id) and
      BaseBranch.equivalent?(package.base_branch, request.base_branch)
  end

  defp move_attachments(_repo, _attachments, _source, nil, _decision_id, _terminal), do: :ok

  defp move_attachments(repo, attachments, source, destination, decision_id, terminal) do
    actor = Actor.from_terminal(terminal)

    Enum.reduce_while(attachments, :ok, fn {id, {:ok, attachment}}, :ok ->
      with true <- stored_key(attachment.ref.repository) == source,
           {:ok, ref} <- PullRequest.parse_number(attachment.ref.number, destination),
           {:ok, _event} <- append_attachment(repo, actor, id, attachment, ref, decision_id) do
        {:cont, :ok}
      else
        false -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Append the current reference so the usual GitHub and delivery paths use
  # the new name. The old attachment and its observations remain in history.
  defp append_attachment(repo, actor, id, attachment, ref, decision_id) do
    previous = repo.get_by!(ProgressEvent, work_package_id: id, sequence: attachment.sequence)
    payload = Map.merge(previous.payload, PullRequestProgress.stringify_keys(ref))

    PlanningRepository.append_audit_progress_event_for_work_package(repo, actor, id, %{
      "summary" => "Pull request link updated after repository rename",
      "status" => "pr_attached",
      "idempotency_key" => "move_work_request:" <> decision_id,
      "payload" => Map.put(payload, "source_tool", "attach_pr")
    })
  end

  defp carry_ci(repo, {:github, source}, {:github, destination}) do
    if Qualification.repository_has_ci?(repo, source), do: Qualification.mark_repository_has_ci(repo, destination)
  end

  defp record_decision(repo, %WorkRequest{} = old, %WorkRequest{} = new, rationale, terminal) do
    Repository.record_decision(repo, old.id, %{
      "source_type" => "architect",
      "source_id" => "move_work_request",
      "decision" => "Moved the WorkRequest from #{old.repo} (#{old.base_branch}) to #{new.repo} (#{new.base_branch}).",
      "rationale" => rationale,
      "scope_impact" => "Repository scope for open work",
      "created_by" => terminal.display_address,
      "recorded_by_terminal" => terminal.key,
      "recorded_by_address" => terminal.display_address
    })
  end

  defp validate_base_branch(nil), do: :ok

  defp validate_base_branch(branch) do
    with false <- String.contains?(branch, <<0>>),
         git when is_binary(git) <- System.find_executable("git") || System.find_executable("git.exe"),
         {output, 0} <- System.cmd(git, ["check-ref-format", "--branch", branch], stderr_to_stdout: true),
         true <- String.trim(output) == branch do
      :ok
    else
      nil -> {:error, :git_not_found}
      _invalid -> {:error, :invalid_base_branch}
    end
  end

  defp result(status, request, packages) do
    %{
      "status" => status,
      "work_request_id" => request.id,
      "repo" => request.repo,
      "base_branch" => request.base_branch,
      "moved_work_package_count" => length(packages)
    }
  end
end
