defmodule SymphonyElixir.SymphonyPlusPlus.Observer.Observation do
  @moduledoc """
  The Observer's last snapshot of one watched package.

    * `pr` - the GitHub snapshot of the PR it watches (state, head, merge
      evidence, CI rollup, failing check names, Codex receipt);
    * `review` - the last Review Suite status read by `review_id`;
    * `stale` - inputs that could not be read on the last sweep (`github`,
      `review`, `stacking`). A stale input blocks qualification and merge
      eligibility and never causes a transition;
    * `stacked_on` - the packages whose unmerged commits the PR carries
      (`WorkPackages.Stacking`); it keeps the PR from qualifying.
  """

  use Ecto.Schema

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:work_package_id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "sympp_work_package_observations" do
    field(:pr, :map)
    field(:review, :map)
    field(:stale, StringList, default: [])
    field(:stacked_on, StringList, default: [])
    field(:observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
