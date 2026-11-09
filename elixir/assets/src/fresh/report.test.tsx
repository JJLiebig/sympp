import { expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { buildGoals, type PkgView } from "./model";
import { phasesOf, PkgLine } from "./report";

it("shows caller inspection on a reviewed descendant already awaiting merge", () => {
  const { goals, now } = buildGoals({ work_request_details: [{
    work_request: { id: "wr", title: "Ship" },
    work_packages: [{ id: "wp", title: "Change", board_state: { stage: "merge" }, review_signal: { status: "inspection_needed" } }],
  }] }, {});
  const pkg = goals[0].pkgs[0];
  const view: PkgView = { pkg, stage: "merge", since: now, untimed: true, failed: false, round: 1, actor: null };
  expect(renderToStaticMarkup(<PkgLine at={now} view={view} />)).toContain("Changes since review need inspection");
  expect(view.failed).toBe(false);
});

it("builds phases from group paths, nesting a path under its first segment", () => {
  const { goals } = buildGoals({ work_request_details: [{
    work_request: { id: "wr", title: "Billing" },
    work_packages: [
      { id: "ui", title: "Page", sequence: 3, group: "Frontend" },
      { id: "api", title: "API", sequence: 1, group: "Backend" },
      { id: "invoices", title: "Invoices", sequence: 2, group: "Backend / Billing" },
      { id: "docs", title: "Docs", sequence: 4 },
    ],
  }] }, {});
  const phases = phasesOf(goals[0]).map((phase) => ({ title: phase.title, pkgs: phase.pkgs.map((pkg) => pkg.id), subs: phase.subs.map((sub) => sub.title) }));
  expect(phases).toEqual([
    { title: "Backend", pkgs: ["api", "invoices"], subs: ["Billing"] },
    { title: "Frontend", pkgs: ["ui"], subs: [] },
    { title: "Other", pkgs: ["docs"], subs: [] },
  ]);
});
