defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Move do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, DashboardPubSub, FactoryRepos}
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
      source_key = scope_key(request.repo)

      if source_key == destination_key do
        {:ok, result("unchanged", request, [])}
      else
        move(repo, request, source_key, destination_key, %{attrs | repo: destination}, terminal)
      end
    end
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  defp move(repo, request, source_key, destination_key, attrs, terminal) do
    with {:ok, {_packages, attachments}} <- moving_packages(repo, request, source_key) do
      # Provider I/O stays outside the write transaction. The proof is about
      # the repository pair, so it covers any newer attachment from that source.
      rename? = confirmed_rename?(repo, source_key, destination_key, attachments)

      result =
        repo.transact(
          fn -> apply_move(repo, request.id, source_key, destination_key, rename?, attrs, terminal) end,
          mode: :immediate
        )

      case result do
        {:ok, %{"status" => "moved"}} = moved -> DashboardPubSub.broadcast_changed_on_success(moved)
        other -> other
      end
    end
  end

  defp apply_move(repo, id, source_key, destination_key, rename?, attrs, terminal) do
    with {:ok, current} <- Repository.get(repo, id),
         :ok <- Phase.require_writable(current) do
      case scope_key(current.repo) do
        ^destination_key -> {:ok, result("unchanged", current, [])}
        ^source_key -> persist_move(repo, current, source_key, destination_key, rename?, attrs, terminal)
        _new_source -> {:error, :work_request_scope_changed}
      end
    end
  end

  defp persist_move(repo, request, source_key, destination_key, rename?, attrs, terminal) do
    base = BaseBranch.canonicalize(attrs.base_branch) || request.base_branch
    allowed_source = if rename?, do: source_key

    with {:ok, {packages, attachments}} <- moving_packages(repo, request, source_key),
         :ok <- require_portable_attachments(attachments, allowed_source, destination_key),
         {:ok, updated} <- repo.update(Changeset.change(request, repo: attrs.repo, base_branch: base)),
         {:ok, decision} <- record_decision(repo, request, updated, attrs.rationale, terminal),
         :ok <- move_packages(repo, packages, request, updated),
         :ok <- move_attachments(repo, attachments, allowed_source, destination_key, decision.id, terminal) do
      if rename?, do: carry_ci(repo, source_key, destination_key)
      {:ok, result("moved", updated, packages)}
    end
  end

  defp moving_packages(repo, request, source_key) do
    with {:ok, packages} <- Repository.list_work_packages(repo, request.id),
         packages = Enum.filter(packages, &(not Lifecycle.ended?(&1) and scope_key(&1.repo) == source_key)),
         {:ok, attachments} <- PlanningRepository.pr_attachments(repo, Enum.map(packages, & &1.id)) do
      {:ok, {packages, attachments}}
    end
  end

  defp scope_key(value) do
    case FactoryRepos.repository_scope(value) do
      {:ok, _scope, key} -> key
      {:error, :invalid_repo_remote} -> {:stored, value}
    end
  end

  # GitHub's old repository endpoint follows the rename and returns the
  # canonical full name. A matching PR number or head alone cannot prove this.
  defp confirmed_rename?(repo, {:github, source}, {:github, destination}, attachments) do
    needs_proof? = map_size(attachments) > 0 or Qualification.repository_has_ci?(repo, source)

    with true <- needs_proof?,
         {:ok, %{"id" => id, "full_name" => canonical}} <- DefaultClient.get_json("repos/#{source}", []),
         true <- is_integer(id) and id > 0 and is_binary(canonical) do
      String.downcase(canonical) == destination
    else
      _unverified -> false
    end
  end

  defp confirmed_rename?(_repo, _source, _destination, _attachments), do: false

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

  defp portable_attachment?({:ok, %{ref: ref}}, allowed_source, destination),
    do: scope_key(ref.repository) in [allowed_source, destination]

  defp portable_attachment?({:error, _reason}, _allowed_source, _destination), do: false

  defp move_packages(repo, packages, request, destination) do
    base_changed? = destination.base_branch != request.base_branch

    Enum.reduce_while(packages, :ok, fn package, :ok ->
      base =
        if base_changed? and BaseBranch.equivalent?(package.base_branch, request.base_branch),
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

  defp move_attachments(_repo, _attachments, nil, _destination, _decision_id, _terminal), do: :ok

  defp move_attachments(repo, attachments, source, {:github, destination}, decision_id, terminal) do
    actor = Actor.from_terminal(terminal)

    Enum.reduce_while(attachments, :ok, fn {id, {:ok, attachment}}, :ok ->
      with true <- scope_key(attachment.ref.repository) == source,
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
