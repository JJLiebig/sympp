import type { PackageOperationalState } from "./work-request";

type BoardLane = "slices" | "implementing" | "finished";

const BOARD_LANES: Record<string, BoardLane> = {
  active: "implementing",
  abandoned: "finished",
  blocked: "implementing",
  completed: "finished",
  completed_no_pr: "finished",
  delivered: "finished",
  dependency_blocked: "implementing",
  dispatched: "implementing",
  ended: "finished",
  finished: "finished",
  in_progress: "implementing",
  legacy: "finished",
  merge_ready: "implementing",
  merged: "finished",
  merging: "implementing",
  needs_attention: "implementing",
  needs_closeout: "implementing",
  prepared: "implementing",
  ready_to_finish: "implementing",
  skipped: "finished",
  started_paused: "implementing",
  superseded: "finished",
};

const RUNNING_STATUSES = new Set(["active", "in_progress", "merging", "reviewing"]);

export function isFinishedBoardStatus(status?: string | null) {
  return BOARD_LANES[status || ""] === "finished";
}

export function operationalStatusIsRunning(operational?: PackageOperationalState | null, fallbackStatus?: string | null) {
  return RUNNING_STATUSES.has(operational?.key || fallbackStatus || "");
}
