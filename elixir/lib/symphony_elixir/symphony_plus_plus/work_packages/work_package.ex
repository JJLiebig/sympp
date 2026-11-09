defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, BranchPattern, Id}
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  alias SymphonyElixir.SymphonyPlusPlus.Title

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @kinds [
    "standard_pr",
    "quick_fix",
    "hotfix",
    "docs",
    "investigation",
    "adapter",
    "mcp",
    "skill",
    "hooks"
  ]
  @review_modes ["fast", "normal", "deep", "none"]
  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          group: String.t() | nil,
          sequence: pos_integer() | nil,
          kind: String.t() | nil,
          title: String.t() | nil,
          goal: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          branch_pattern: String.t() | nil,
          product_description: String.t() | nil,
          engineering_scope: String.t() | nil,
          allowed_file_globs: [String.t()] | nil,
          forbidden_file_globs: [String.t()] | nil,
          validation_steps: [String.t()] | nil,
          stop_conditions: [String.t()] | nil,
          review_requirement: map() | nil,
          policy_template: String.t() | nil,
          acceptance_criteria: [String.t()] | nil,
          worktree_path: String.t() | nil,
          worktree_target_repo_root: String.t() | nil,
          worktree_cleanup_proof: String.t() | nil,
          status: String.t() | nil,
          parent_id: String.t() | nil,
          phase_id: String.t() | nil,
          owner_id: String.t() | nil,
          contract_revision: pos_integer() | nil,
          dispatched_at: DateTime.t() | nil,
          review_mode: String.t() | nil,
          review_id: String.t() | nil,
          launch_machine: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_packages" do
    field(:work_request_id, :string)
    field(:group, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:title, :string)
    field(:goal, :string)
    field(:repo, :string)
    field(:base_branch, :string)
    field(:branch_pattern, :string)
    field(:product_description, :string)
    field(:engineering_scope, :string)
    field(:allowed_file_globs, StringList, default: [])
    field(:forbidden_file_globs, StringList, default: [])
    field(:validation_steps, StringList, default: [])
    field(:stop_conditions, StringList, default: [])
    field(:review_requirement, :map)
    field(:policy_template, :string)
    field(:acceptance_criteria, StringList, default: [])
    field(:worktree_path, :string)
    field(:worktree_target_repo_root, :string)
    field(:worktree_cleanup_proof, :string)
    field(:status, :string)
    field(:parent_id, :string)
    field(:phase_id, :string)
    field(:owner_id, :string)
    field(:contract_revision, :integer, default: 1)
    field(:dispatched_at, :utc_datetime_usec)
    field(:dispatched_by, :map)
    # Set by dispatch only: how the worker reviews its change, the Review Suite
    # id it reviews under, and the Herdr machine named in its launch line.
    field(:review_mode, :string)
    field(:review_id, :string)
    field(:launch_machine, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Review modes dispatch accepts. `none` means the worker runs no Review Suite review."
  @spec review_modes() :: [String.t()]
  def review_modes, do: @review_modes

  @doc "The Review Suite `--mode` for a review mode; `none` has no review."
  @spec review_suite_mode(String.t()) :: String.t() | nil
  def review_suite_mode("fast"), do: "fast"
  def review_suite_mode("normal"), do: "base"
  def review_suite_mode("deep"), do: "deep"
  def review_suite_mode("none"), do: nil

  @spec repo(map(), t()) :: String.t() | nil
  def repo(work_request, %__MODULE__{} = work_package) do
    nonblank(work_package.repo) || nonblank(Map.get(work_request, :repo))
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "planned")

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_packages_id_unique_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = work_package, attrs) do
    attrs = Map.drop(normalize_keys(attrs), ["id", "status", "inserted_at", "updated_at", "created_at"])

    changeset(work_package, attrs)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = work_package, attrs) do
    attrs = attrs |> normalize_keys() |> BaseBranch.canonicalize_attrs()

    work_package
    |> cast(attrs, [
      :id,
      :work_request_id,
      :group,
      :sequence,
      :kind,
      :title,
      :goal,
      :repo,
      :base_branch,
      :branch_pattern,
      :product_description,
      :engineering_scope,
      :allowed_file_globs,
      :forbidden_file_globs,
      :validation_steps,
      :stop_conditions,
      :review_requirement,
      :policy_template,
      :acceptance_criteria,
      :worktree_path,
      :worktree_target_repo_root,
      :worktree_cleanup_proof,
      :status,
      :parent_id,
      :phase_id,
      :owner_id,
      :contract_revision,
      :dispatched_at
    ])
    |> Title.validate()
    |> normalize_group()
    |> validate_required([:id, :kind, :title, :repo, :base_branch, :acceptance_criteria, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_status()
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:contract_revision, greater_than: 0)
    |> validate_branch_pattern()
    |> validate_policy_template()
    |> validate_review_requirement()
  end

  @doc """
  Normalizes a group path such as `"Backend/ Billing"` to `"Backend / Billing"`:
  segments split on `/`, trimmed and joined with `" / "`. A blank path means no
  group. An empty segment is an error.
  """
  @spec normalize_group_path(term()) :: {:ok, String.t() | nil} | :error
  def normalize_group_path(nil), do: {:ok, nil}

  def normalize_group_path(path) when is_binary(path) do
    segments = path |> String.split("/") |> Enum.map(&String.trim/1)

    cond do
      String.trim(path) == "" -> {:ok, nil}
      Enum.any?(segments, &(&1 == "")) -> :error
      true -> {:ok, Enum.join(segments, " / ")}
    end
  end

  def normalize_group_path(_path), do: :error

  @doc "The segments of a group path, outermost first."
  @spec group_segments(String.t() | nil) :: [String.t()]
  def group_segments(nil), do: []
  def group_segments(path) when is_binary(path), do: String.split(path, " / ")

  defp normalize_group(changeset) do
    case fetch_change(changeset, :group) do
      {:ok, path} ->
        case normalize_group_path(path) do
          {:ok, normalized} -> put_change(changeset, :group, normalized)
          :error -> add_error(changeset, :group, "must be names separated by /, with no empty name", validation: :group_path)
        end

      :error ->
        changeset
    end
  end

  defp validate_status(changeset), do: validate_inclusion(changeset, :status, Lifecycle.statuses())

  defp validate_branch_pattern(changeset) do
    validate_change(changeset, :branch_pattern, fn :branch_pattern, value ->
      case BranchPattern.validate(value) do
        :ok ->
          []

        {:error, reason} ->
          [branch_pattern: {BranchPattern.error_message(reason), validation: :branch_pattern, reason: reason}]
      end
    end)
  end

  defp validate_policy_template(changeset) do
    case get_field(changeset, :policy_template) do
      nil ->
        changeset

      policy_template ->
        kind = get_field(changeset, :kind)

        if canonical_policy_template?(kind, policy_template) do
          changeset
        else
          add_error(changeset, :policy_template, "is invalid", validation: :policy_template)
        end
    end
  end

  defp validate_review_requirement(changeset) do
    validate_change(changeset, :review_requirement, fn :review_requirement, requirement ->
      case ReviewRequirement.validation_error(requirement) do
        nil -> []
        message -> [review_requirement: message]
      end
    end)
  end

  defp canonical_policy_template?(kind, policy_template), do: Templates.compatible_kind?(kind, policy_template)

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp nonblank(_value), do: nil

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    Id.random("wp")
  end
end
