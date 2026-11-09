defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-898",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: payload
        },
        140
      )

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end
end
