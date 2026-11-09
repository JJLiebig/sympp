System.put_env("SYMPP_OPEN_DASHBOARD", "0")
# Tests never read the machine's real herdr-core, Review Suite state or GitHub
# token; a test that needs one sets its source to a function.
Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
Application.put_env(:symphony_elixir, :sympp_review_command, nil)
Application.put_env(:symphony_elixir, :sympp_gh_token_command, fn -> nil end)
ExUnit.start()

if System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" do
  existing_excludes = Keyword.get(ExUnit.configuration(), :exclude, [])
  ExUnit.configure(exclude: Enum.uniq(existing_excludes ++ [:live_e2e]))
end

Code.require_file("support/github_test_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/work_package_factory.exs", __DIR__)
Code.require_file("support/canonical_work_package_fixtures.ex", __DIR__)
