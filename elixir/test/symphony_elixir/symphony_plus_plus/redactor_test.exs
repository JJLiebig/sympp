defmodule SymphonyElixir.SymphonyPlusPlus.RedactorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  test "keeps task launch paths and ordinary sk fragments copyable" do
    for path <- [
          "/srv/factory/.worktrees/app/feat-panel-task-ui-4z6x44z4",
          ~S(C:\Code\.worktrees\app\task-ui-4z6x44z4),
          "/work/sk-0123456789abcdefghijklmnopqrstuv",
          ~S(C:\work\sk-0123456789abcdefghijklmnopqrstuv),
          "task-0123456789abcdefghijklmnopqrstuv",
          "sk-ui-4z6x44z4"
        ] do
      assert Redactor.redact_text("cd #{path}") == "cd #{path}"
    end
  end

  test "redacts standalone secret-shaped tokens with punctuation or whitespace boundaries" do
    for token <- [
          "sk-0123456789abcdefghijklmnopqrstuv",
          "sk-proj-0123456789_abcdefghijklmnop-qrstuv"
        ],
        {prefix, suffix} <- [{"", ""}, {"token: ", "."}, {"\"", "\""}, {"key=", "&page=1"}, {"https://", "@example.test/path"}, {"https://", ":pw@example.test"}, {"https://user:", "@example.test"}] do
      assert Redactor.redact_text(prefix <> token <> suffix) == prefix <> "[REDACTED]" <> suffix
    end
  end
end
