import { describe, expect, it } from "vitest";

import { applyDemo, demoLedger } from "./mock";
import { buildBoard, openAt, unresolvedPkgs, viewAt, waitsOnOthers, type Hydrated } from "./model";
import { refusalText } from "./operator";

const NOW = Date.parse("2026-11-09T12:00:00Z");

function read(hydrated: Hydrated) {
  return buildBoard({ generated_at: new Date(NOW).toISOString(), ...hydrated }, {}).board;
}

describe("the hydrated board as the board reads it", () => {
  it("takes each goal's phase from the backend and fills the archived shelf from its own read", () => {
    const ledger = demoLedger(NOW);
    const { board } = buildBoard(ledger.hydrated, {}, ledger.archived);
    const phases = Object.fromEntries(viewAt(board, NOW).map((view) => [view.goal.id, view.phase]));

    expect(phases).toMatchObject({ "wr-owner": "active", "wr-recap": "unresolved", "wr-language": "intake", "wr-restore": "done", "wr-vod": "archived" });
  });

  it("lists open asks from goals and cards, and decisions that still need the operator", () => {
    const ledger = demoLedger(NOW);
    const answered = applyDemo(ledger, { kind: "answer", askId: "ask-slack", answer: { text: "Added." } }, NOW);
    const { board } = buildBoard(answered.hydrated, {}, answered.archived);

    expect(board.asks.filter((ask) => openAt(ask, NOW)).map((ask) => ask.id).sort()).toEqual(["ask-release", "ask-vod"]);
    expect(board.asks.find((ask) => ask.id === "ask-vod")).toMatchObject({ cardId: "card-jjdesktop-t6vv", goalId: null });
    expect(board.asks.find((ask) => ask.id === "ask-release")).toMatchObject({ redirect: "Neither: tell the architect what to do instead", choices: [{ id: "owner-only" }, { id: "owner-and-workers" }] });
    expect(board.decisions.find((decision) => decision.id === "dec-recap-share")).toMatchObject({ state: "feedback", undelivered: "terminal_finished" });
    // A card has no area of its own: it takes the area of a goal in the same repository.
    expect(board.cards.find((card) => card.id === "card-jjdesktop-t6vv")?.area).toEqual(["Nextide-Misc", "nextide-web"]);
  });

  it("reads a package's v2 progress, worker, staleness and ending", () => {
    const board = read({
      work_request_details: [
        {
          work_request: { id: "wr", title: "Goal", phase: "active", repo: "acme/app", worked_on: { address: "desk/t1", role: "architect", liveness: "unknown" } },
          work_packages: [
            { id: "exited", status: "dispatched", progress: "worker_exited", dispatched_at: "2026-11-09T11:00:00Z", worker_terminal: { address: "desk/t2", state: "finished", status: "finished" } },
            { id: "unseen", status: "dispatched", progress: "implementing", worker_terminal: { address: "lap/t3", state: "live", status: "unknown" }, observation_stale: ["review"], review_signal: { mode: "deep", status: "in_progress", round: 2 } },
            { id: "upstream", status: "ready", pr_signal: { status: "open", number: 9, url: "https://github.com/up/app/pull/9", repository: "up/app", checks: { status: "passing" } } },
            { id: "old", status: "ended", delivery: { outcome: "legacy", legacy_status: "closed" } },
          ],
        },
      ],
    });
    const [view] = viewAt(board, NOW);
    const live = Object.fromEntries(view.live.map((entry) => [entry.pkg.id, entry]));

    expect(view.goal.owner).toMatchObject({ address: "desk/t1", liveness: "unknown" });
    expect(live.exited).toMatchObject({ stage: "implementing", pkg: { exited: true, owner: { liveness: "finished" } } });
    expect(live.unseen.pkg).toMatchObject({ owner: { liveness: "unknown" }, review: { mode: "deep", state: "unknown", round: 2 } });
    expect(live.upstream).toMatchObject({ stage: "ready", pkg: { ci: "passing", pr: { repo: "up/app", open: true } } });
    expect(view.done.map((pkg) => [pkg.id, pkg.outcome])).toEqual([["old", "completed"]]);
  });
});

describe("replaying the past", () => {
  it("shows an answered ask only while it was open", () => {
    const board = read({ work_request_details: [{ work_request: { id: "wr", phase: "active", inserted_at: "2026-11-09T08:00:00Z" }, asks: [{ id: "a", work_request_id: "wr", state: "answered", asked_at: "2026-11-09T10:00:00Z", resolved_at: "2026-11-09T11:00:00Z" }] }] });
    const open = (at: string) => viewAt(board, Date.parse(at))[0]?.asks.map((ask) => ask.id);
    expect([open("2026-11-09T09:30:00Z"), open("2026-11-09T10:30:00Z"), open("2026-11-09T11:30:00Z")]).toEqual([[], ["a"], []]);
  });
});

describe("an unresolved goal", () => {
  it("follows a superseded package to its successor", () => {
    const ended = (id: string, outcome: string, successor: string | null = null) => ({ id, status: "ended", delivery: { outcome, successor_work_package_id: successor, recorded_at: "2026-11-09T10:00:00Z" } });
    const board = read({ work_request_details: [{ work_request: { id: "wr", phase: "unresolved" }, work_packages: [ended("a", "superseded", "b"), ended("b", "skipped"), ended("c", "pr_merged")] }] });
    const [view] = viewAt(board, NOW);
    expect(unresolvedPkgs(view).map((pkg) => pkg.id)).toEqual(["a"]);
  });

  it("offers Finish only for a PR into another repository than the goal's, whatever name the goal shows", () => {
    const pkg = (id: string, repository: string) => ({ id, status: "ready", pr_signal: { status: "open", number: 1, url: "u", repository } });
    const board = read({ work_request_details: [{ work_request: { id: "wr", phase: "active", repo: "acme/sympp", repo_display: "sympp", repo_aliases: ["acme/sympp"] }, work_packages: [pkg("own", "Acme/Sympp"), pkg("upstream", "openai/symphony")] }] });
    expect(viewAt(board, NOW)[0].live.filter((view) => waitsOnOthers(view.pkg)).map((view) => view.pkg.id)).toEqual(["upstream"]);
  });

  it("shows a review as done only when it is accepted for the PR's current head", () => {
    const board = (accepted: string) => read({ work_request_details: [{ work_request: { id: "wr", phase: "active" }, work_packages: [{ id: "p", status: "ready", pr_signal: { status: "open", number: 1, url: "u", head_sha: "bbbb2222" }, review_signal: { mode: "fast", status: "passed", accepted_head: accepted } }] }] });
    expect(viewAt(board("aaaa1111"), NOW)[0].live[0].pkg.review).toMatchObject({ mode: "fast", state: null });
    expect(viewAt(board("bbbb2222"), NOW)[0].live[0].pkg.review).toMatchObject({ mode: "fast", state: "done" });
  });
});

describe("a refused action", () => {
  it("says what to do next in words, else the backend's message", () => {
    expect(refusalText({ error: { message: "WorkRequest is archived; restore it first", next_action: "restore" } })).toBe("This goal is archived. Restore it first.");
    expect(refusalText({ error: { message: "This decision is acknowledged", next_action: "none: only flagged decisions are reviewed" } })).toBe("Nothing is left to do here. It was already handled.");
    expect(refusalText({ error: { message: "This ask is already answered" } })).toBe("This ask is already answered");
  });
});
