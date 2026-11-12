import { expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
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
