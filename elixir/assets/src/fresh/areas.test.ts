import { afterEach, expect, it } from "vitest";

import { areaFor, githubSlug, setAreas } from "./areas";

afterEach(() => setAreas([]));

it("files a repository under its GitHub owner unless an operator rule names its area", () => {
  expect(areaFor("nextidemedia/live-chat")).toEqual(["nextidemedia", "live-chat"]);
  // A display name can be bare; the remote still names the owner.
  expect(areaFor("sympp", githubSlug("https://github.com/JJLiebig/sympp.git", "sympp"))).toEqual(["JJLiebig", "sympp"]);
  expect(areaFor("notes")).toEqual(["Unfiled", "notes"]);

  setAreas([["live-chat", ["Nextide", "Live"]]]);
  expect(areaFor("nextidemedia/live-chat")).toEqual(["Nextide", "Live"]);
});
