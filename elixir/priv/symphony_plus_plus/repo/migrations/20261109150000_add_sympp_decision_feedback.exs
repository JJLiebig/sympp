defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppDecisionFeedback do
  use Ecto.Migration

  # Decision feedback: a flagged decision starts in review_state "recorded";
  # the operator acknowledges it or sends feedback, which the factory types
  # into the recording terminal. Feedback that couldn't be typed keeps its
  # reason in undelivered_reason until the operator dismisses the marker.
  # The recording terminal is stored like an ask's: key (core id plus address)
  # and display address. Existing decisions stay unflagged.
  def change do
    alter table(:sympp_work_request_decision_logs) do
      add(:flagged, :boolean, null: false, default: false)
      add(:review_state, :text)
      add(:feedback, :text)
      add(:reviewed_at, :utc_datetime_usec)
      add(:undelivered_reason, :text)
      add(:recorded_by_terminal, :text)
      add(:recorded_by_address, :text)
    end
  end
end
