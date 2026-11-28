import { expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { blockedOn } from "./blocked";
import { demoLedger } from "./mock";
import { buildBoard } from "./model";
import { PreviewLink } from "./worker-links";

it("successive board reads add and remove a live worker's preview link", () => {
  const ledger = demoLedger(Date.now());
  const slice = ledger.hydrated.work_request_details!.flatMap((detail) => detail.work_packages ?? []).find((pkg) => pkg.worker_terminal?.preview_url)!;
  const terminal = slice.worker_terminal!;
  const render = () => {
    const { board } = buildBoard(ledger.hydrated, {});
    const pkg = board.goals.flatMap((goal) => goal.pkgs).find((pkg) => pkg.id === slice.id)!;
    return renderToStaticMarkup(<PreviewLink terminal={pkg.owner!} />);
  };
  terminal.preview_url = null;
  expect(render()).not.toContain('target="_blank"');
  terminal.preview_url = "https://demo-host:3000/design";
  expect(render()).toContain('href="https://demo-host:3000/design" target="_blank"');
  terminal.preview_url = null;
  expect(render()).not.toContain('target="_blank"');
  terminal.preview_url = "https://demo-host:3000/design";
  terminal.state = "finished";
  expect(render()).not.toContain('target="_blank"');
});

it("only an open blocker marks a package Blocked; hover names each one and a click opens the first with a target", () => {
  const pkgs = buildBoard(demoLedger(Date.now()).hydrated, {}).board.goals.flatMap((goal) => goal.pkgs);
  const blocked = (title: string) => blockedOn(pkgs.find((pkg) => pkg.title === title)!.blockers);
  expect(blocked("Pin third-party actions by SHA")).toBeNull();
  expect(blocked("Slack delivery with dedupe")).toEqual({
    lines: ["PR control-dashboard#313", "hold: Waits on the site install and readback on both hosts before the release chief m…"],
    target: { kind: "pr", id: "nextidemedia/control-dashboard#313" },
  });
  expect(blocked("Forward Herdr labels in _meta")!.target).toEqual({ kind: "work_package", id: "wr-owner-3", goalId: "wr-owner" });
});
