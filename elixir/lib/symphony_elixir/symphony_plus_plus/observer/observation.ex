defmodule SymphonyElixir.SymphonyPlusPlus.Observer.Observation do
  @moduledoc """
  The Observer's last snapshot of one watched package.

    * `pr` - the GitHub snapshot of the PR it watches (state, head, merge
      evidence, CI rollup, failing check names, Codex receipt);
    * `pr_absent` - branch discovery found no PR on the last sweep and the
      package has a review cycle to read on demand;
    * `review` - the last Review Suite status read by `review_id`;
    * `stale` - inputs that could not be read on their most recent check
      (`github`, `review`, `stacking`). A stale input blocks qualification
      and merge eligibility and never causes a transition;
    * `stacked_on` - the packages whose unmerged commits the PR carries
      (`WorkPackages.Stacking`); it keeps the PR from qualifying.
  """

  use Ecto.Schema

  alias SymphonyElixir.SymphonyPlusPlus.ReviewStatus
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:work_package_id, :string, autogenerate: false}

  @type t :: %__MODULE__{}
  @type review_result :: ReviewStatus.result() | :none

  schema "sympp_work_package_observations" do
    field(:pr, :map)
    field(:pr_absent, :boolean, default: false)
    field(:review, :map)
    field(:stale, StringList, default: [])
    field(:stacked_on, StringList, default: [])
    field(:observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec review_attributes(t(), review_result()) :: %{review: map() | nil, stale: [String.t()]}
  def review_attributes(%__MODULE__{} = observation, result) do
    stale =
      if result == :unknown,
        do: Enum.uniq(observation.stale ++ ["review"]),
        else: List.delete(observation.stale, "review")

    %{review: review_payload(result, observation), stale: stale}
  end

  @doc false
  @spec review_payload(review_result() | :deferred, t() | nil) :: map() | nil
  def review_payload({:ok, review}, observation), do: ReviewStatus.snapshot(review, observation && observation.review)
  def review_payload(:not_started, _observation), do: %{"status" => "not_started"}
  def review_payload(:none, _observation), do: nil
  def review_payload(result, observation) when result in [:unknown, :deferred], do: observation && observation.review
end
