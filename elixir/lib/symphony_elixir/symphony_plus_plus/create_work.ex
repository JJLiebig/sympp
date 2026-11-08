defmodule SymphonyElixir.SymphonyPlusPlus.CreateWork do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type request :: map()
  @type creation :: %{
          work_package: WorkPackage.t(),
          virtual_files: %{String.t() => String.t()},
          policy: Templates.template()
        }

  @type error ::
          :invalid_acceptance_criteria
          | :invalid_allowed_file_globs
          | :invalid_kind
          | :invalid_policy_template
          | :invalid_request
          | :invalid_status
          | :invalid_review_requirement
          | :sensitive_review_requirement
          | :invalid_work_package_id
          | :missing_acceptance_criteria
          | :parent_not_supported
          | :policy_template_mismatch
          | :kind_not_dispatchable
          | :unknown_policy_template
          | {:missing_required_field, String.t()}
          | Changeset.t()
          | WorkPackageRepository.error()
          | PlanningRepository.error()
          | Renderer.error()

  @spec activate(module(), WorkPackage.t()) :: {:ok, creation()} | {:error, error()}
  def activate(repo, %WorkPackage{} = work_package), do: activate(repo, work_package, [])

  @spec activate(module(), WorkPackage.t(), keyword()) :: {:ok, creation()} | {:error, error()}
  def activate(repo, %WorkPackage{status: "planned"} = work_package, opts) when is_atom(repo) and is_list(opts) do
    with {:ok, policy} <- Templates.expand(work_package.policy_template || work_package.kind),
         policy = effective_policy(policy, work_package.review_requirement),
         {:ok, acceptance_criteria} <- normalize_acceptance_criteria(work_package.acceptance_criteria),
         :ok <- require_acceptance_criteria(policy, acceptance_criteria) do
      repo.transaction(fn -> activate_transaction(repo, work_package, policy) end)
      |> case do
        {:ok, creation} -> {:ok, creation}
        {:error, reason} -> {:error, reason}
      end
      |> maybe_broadcast_changed(opts)
    end
  end

  def activate(_repo, %WorkPackage{}, _opts), do: {:error, :invalid_status}

  defp maybe_broadcast_changed(result, opts) do
    if Keyword.get(opts, :broadcast?, true) do
      DashboardPubSub.broadcast_changed_on_success(result)
    else
      result
    end
  end

  defp activate_transaction(repo, work_package, policy) do
    revision = work_package.contract_revision

    with {:ok, activated} <- Lifecycle.transition(repo, work_package, :dispatch, expected_contract_revision: revision),
         {:ok, _scope_node} <- append_scope_plan_node(repo, activated),
         {:ok, virtual_files} <- Renderer.render_all(repo, activated.id) do
      %{
        work_package: activated,
        virtual_files: virtual_files,
        policy: policy
      }
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  @spec response_payload(creation(), keyword()) :: map()
  def response_payload(%{work_package: work_package, virtual_files: virtual_files, policy: policy}, opts \\ []) do
    worker_bootstrap = Keyword.get(opts, :worker_bootstrap)

    %{
      work_package: work_package_payload(work_package),
      policy: policy_payload(policy),
      virtual_files: virtual_files
    }
    |> maybe_put_worker_bootstrap(worker_bootstrap)
  end

  @spec error_message(term()) :: String.t()
  def error_message({:missing_required_field, field}), do: "Missing required create-work field: #{field}"
  def error_message(:invalid_acceptance_criteria), do: "acceptance_criteria must be a list of nonblank strings"
  def error_message(:invalid_allowed_file_globs), do: "allowed_file_globs must be a list of nonblank strings"
  def error_message(:invalid_kind), do: "kind must be a nonblank string when provided"
  def error_message(:invalid_policy_template), do: "policy_template must be a nonblank string when provided"
  def error_message(:invalid_request), do: "Create-work request must be an object"
  def error_message(:invalid_review_requirement), do: "review_requirement must contain a non-empty type and optional args object"
  def error_message(:sensitive_review_requirement), do: "review_requirement must not contain secrets"
  def error_message(:invalid_work_package_id), do: "id must be a nonblank string when provided"
  def error_message(:missing_acceptance_criteria), do: "acceptance_criteria is required for this work kind"
  def error_message(:parent_not_supported), do: "Create-work does not accept parent_id"
  def error_message(:policy_template_mismatch), do: "policy_template must select the work kind policy"

  def error_message(:kind_not_dispatchable),
    do: "Create-work supports standard_pr (ordinary PR work), quick_fix, hotfix, docs, investigation, adapter, mcp (MCP server, protocol, tool, or plugin work), skill, and hooks only"

  def error_message(:unknown_policy_template), do: "No policy template exists for requested kind"
  def error_message(%Changeset{} = changeset), do: "Invalid create-work request: #{inspect(changeset.errors)}"
  def error_message(reason), do: "Failed to create work: #{inspect(reason)}"

  defp append_scope_plan_node(repo, %WorkPackage{} = work_package) do
    PlanningRepository.append_plan_node(repo, %{
      work_package_id: work_package.id,
      title: initial_scope_title(work_package),
      body: nonblank_or(work_package.engineering_scope, "Use the engineering scope from context.md."),
      status: "pending"
    })
  end

  defp initial_scope_title(%WorkPackage{kind: "investigation"}), do: "Investigate requested scope"
  defp initial_scope_title(%WorkPackage{}), do: "Implement requested scope"

  defp nonblank_or(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp nonblank_or(_value, fallback), do: fallback

  defp maybe_put_worker_bootstrap(payload, nil), do: payload
  defp maybe_put_worker_bootstrap(payload, bootstrap), do: Map.put(payload, :worker_bootstrap, redacted_worker_bootstrap(bootstrap))

  defp redacted_worker_bootstrap(bootstrap) when is_map(bootstrap) do
    bootstrap
    |> redact_bootstrap_launch_prompt(:launch_prompt)
    |> redact_bootstrap_launch_prompt("launch_prompt")
  end

  defp redact_bootstrap_launch_prompt(bootstrap, key) do
    case Map.fetch(bootstrap, key) do
      {:ok, prompt} when is_binary(prompt) -> Map.put(bootstrap, key, Redactor.redact_text(prompt))
      _result -> bootstrap
    end
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: work_package.title,
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: work_package.product_description,
      engineering_scope: work_package.engineering_scope,
      allowed_file_globs: work_package.allowed_file_globs,
      review: work_package.review_requirement,
      policy_template: work_package.policy_template,
      acceptance_criteria: work_package.acceptance_criteria,
      status: work_package.status,
      parent_id: work_package.parent_id,
      owner_id: work_package.owner_id
    }
  end

  defp policy_payload(policy) do
    %{
      template: policy.template,
      constraints: policy.constraints,
      required_gates: policy.required_gates
    }
  end

  defp require_acceptance_criteria(%{required_gates: required_gates}, []) do
    if "package_acceptance" in required_gates do
      {:error, :missing_acceptance_criteria}
    else
      :ok
    end
  end

  defp require_acceptance_criteria(_policy, _acceptance_criteria), do: :ok

  defp normalize_acceptance_criteria(criteria) when is_list(criteria) do
    criteria = Enum.map(criteria, &normalize_acceptance_criterion/1)

    if Enum.all?(criteria, &valid_acceptance_criterion?/1) do
      {:ok, criteria}
    else
      {:error, :invalid_acceptance_criteria}
    end
  end

  defp normalize_acceptance_criteria(nil), do: {:ok, []}
  defp normalize_acceptance_criteria(_criteria), do: {:error, :invalid_acceptance_criteria}

  defp effective_policy(policy, _review_requirement), do: policy

  defp normalize_acceptance_criterion(value) when is_binary(value), do: String.trim(value)
  defp normalize_acceptance_criterion(_value), do: :invalid

  defp valid_acceptance_criterion?(value) when is_binary(value), do: value != ""
  defp valid_acceptance_criterion?(_value), do: false
end
