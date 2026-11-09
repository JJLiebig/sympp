import { Check, CircleDashed, ScanSearch, X } from "lucide-react";

import { GoalActions, ShelfCleanup } from "./actions";
import { areaLabel } from "./areas";
import { deployAt, span, type Ci, type DeployStep, type Goal, type GoalView, type Outcome, type Pr, type PkgView, type Review, type Stage } from "./model";
import { POP, useFlash } from "./motion";

// `pip` is the small square that stands for a package in a strip of dots; `bar` is its step on the track.
export const STAGE: Record<Stage, { label: string; text: string; pip: string; bar: string }> = {
  planned: { label: "Planned", text: "text-faint", pip: "border border-faint", bar: "bg-line" },
  launching: { label: "Launching", text: "text-build", pip: "border border-build", bar: "bg-build/50" },
  implementing: { label: "Implementing", text: "text-build", pip: "bg-build", bar: "bg-build" },
  review_ci: { label: "Review/CI", text: "text-review", pip: "bg-review", bar: "bg-review" },
  ready: { label: "Ready", text: "text-merge", pip: "bg-merge", bar: "bg-merge" },
  ended: { label: "Ended", text: "text-dim", pip: "bg-merge/40", bar: "bg-merge/40" },
};

export const OUTCOME: Record<Outcome, { label: string; tone: string }> = {
  merged: { label: "Merged", tone: "text-merge/80" },
  finished: { label: "Finished", tone: "text-merge/80" },
  completed: { label: "Completed without a PR", tone: "text-merge/80" },
  superseded: { label: "Superseded", tone: "text-faint" },
  abandoned: { label: "Abandoned", tone: "text-fail" },
  skipped: { label: "Skipped", tone: "text-faint" },
};

const STEPS: Stage[] = ["launching", "implementing", "review_ci", "ready"];

// Package and card rows are fixed column grids, so every column starts at the same x on every row,
// whatever is in it. Below 1280px the step bars are left out and the PR and owner columns narrow.
// Package: pip, title, CI, review, [steps], stage, time, PR, owner, action.
export const PKG_GRID = "grid grid-cols-[10px_minmax(0,1fr)_88px_128px_88px_48px_110px_150px_52px] items-center gap-x-2.5 min-[1280px]:grid-cols-[10px_minmax(0,1fr)_88px_128px_48px_88px_48px_150px_170px_52px]";
// Card: pip, task, repo and branch, CI, review, PR, state, owner, dismiss.
export const CARD_GRID = "grid grid-cols-[10px_minmax(0,1fr)_150px_88px_128px_64px_72px_150px_24px] items-center gap-x-2.5 min-[1280px]:grid-cols-[10px_minmax(0,1fr)_200px_88px_128px_64px_72px_170px_24px]";

// Four steps from launch to ready. Hidden with its column on narrow screens; the stage label says the same.
export function StageSteps({ view }: { view: PkgView }) {
  const position = STEPS.indexOf(view.stage);
  return (
    <span aria-hidden className="hidden gap-0.5 min-[1280px]:flex">
      {STEPS.map((step, index) => (
        <span key={step} className={`h-1 w-2.5 rounded-full ${index < position ? "bg-dim" : index === position ? (view.failed ? "bg-fail" : STAGE[step].bar) : "bg-line"}`} />
      ))}
    </span>
  );
}

// A worker that finished without opening a PR leaves its package implementing with nobody on it.
export function StageLabel({ view }: { view: PkgView }) {
  if (view.pkg.exited && view.stage === "implementing") return <span className="truncate whitespace-nowrap font-mono text-[11px] font-semibold text-checks" title="The worker finished without opening a PR">Exited</span>;
  return <span className={`truncate whitespace-nowrap font-mono text-[11px] font-semibold ${view.failed ? "text-fail" : STAGE[view.stage].text}`}>{STAGE[view.stage].label}</span>;
}

// How long the package has been in its stage, right-aligned with tabular figures so the times line up.
export function StageTime({ at, view }: { at: number; view: PkgView }) {
  return <span className="text-right font-mono text-[11px] tabular-nums text-dim">{view.untimed ? "" : span(at - view.since)}</span>;
}

const CI: Record<Ci, { label: string; tone: string; icon: typeof Check }> = {
  passing: { label: "CI", tone: "text-merge", icon: Check },
  pending: { label: "CI running", tone: "text-checks", icon: CircleDashed },
  failing: { label: "CI failing", tone: "text-fail", icon: X },
};

// The mode, then the state. A card's review has no known mode, so it shows the state alone.
function reviewLabel(review: Review): { text: string; tone: string } {
  if (review.mode === "none") return { text: "none", tone: "text-faint" };
  const words = (state: string) => (review.mode ? `${review.mode} · ${state}` : state);
  // A running first round says so; a later one says which round, which implies it is running.
  if (review.state === "running") return { text: words(review.round > 1 ? `round ${review.round}` : "running"), tone: "text-review" };
  if (review.state === "findings") return { text: words("findings"), tone: "text-checks" };
  if (review.state === "done") return { text: words("done"), tone: "text-merge/80" };
  if (review.state === "unknown") return { text: words("unknown"), tone: "text-faint" };
  return { text: review.mode ?? "pending", tone: "text-faint" };
}

// The PR's checks. An empty cell keeps its column. When GitHub could not be read, the last result is not shown as current.
export function CiCell({ ci, stale = false }: { ci: Ci | null; stale?: boolean }) {
  if (stale) {
    return (
      <span className="flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] text-faint" title="GitHub could not be read on the last look">
        <CircleDashed aria-hidden className="size-3 shrink-0" />
        <span className="truncate">CI unknown</span>
      </span>
    );
  }
  if (!ci) return <span />;
  const check = CI[ci];
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${check.tone}`}>
      <check.icon aria-hidden className="size-3 shrink-0" />
      <span className="truncate">{check.label}</span>
    </span>
  );
}

// The Review Suite mode and state for the PR's current head. An empty cell keeps its column.
export function ReviewCell({ review }: { review: Review | null }) {
  if (!review) return <span />;
  const words = reviewLabel(review);
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${words.tone}`} title={`Review: ${words.text}`}>
      <ScanSearch aria-hidden className="size-3 shrink-0" />
      <span className="sr-only">Review </span>
      <span className="truncate">{words.text}</span>
    </span>
  );
}

// A PR in the goal's own repository is its number; one elsewhere also names where it waits.
export function PrLink({ pr, repo }: { pr: Pr | null; repo: string }) {
  if (!pr) return <span />;
  const name = pr.repo && pr.repo !== repo ? `${pr.repo}#${pr.number}` : `#${pr.number}`;
  return (
    <a className="truncate font-mono text-[11px] text-dim underline decoration-dotted underline-offset-2 hover:text-ink" href={pr.url} rel="noreferrer" target="_blank" title={`Open PR ${pr.repo}#${pr.number}`}>
      {name}
    </a>
  );
}

// Goals that ask for nothing stay out of the way: one line, opened on demand.
function shelfCount(view: GoalView) {
  const total = view.done.length + view.queued.length + view.live.length;
  return total === 0 ? "not sliced" : `${view.done.length}/${total} done`;
}

// `age` says what the time on each row means, for example "idle" or "done".
export function Shelf({ age, at, cleanup, hint, label, views }: { age: string; at: number; cleanup?: boolean; hint?: string; label: string; views: GoalView[] }) {
  if (views.length === 0) return null;

  return (
    <details className="mt-8 text-sm text-dim">
      <summary className="cursor-pointer text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">
        {label} · {views.length}
        {hint ? <span className="ml-2 font-normal normal-case tracking-normal">{hint}</span> : null}
      </summary>
      {cleanup ? (
        <div className="mt-2 flex max-w-[900px] justify-end">
          <ShelfCleanup at={at} views={views} />
        </div>
      ) : null}
      <ul className="mt-2 max-w-[900px] space-y-1">
        {views.map((view) => (
          <li key={view.goal.id} className="flex items-center justify-between gap-4" data-goal={view.goal.id}>
            <span className="min-w-0 truncate">{view.goal.title}</span>
            <span className="shrink-0 text-[11px] uppercase tracking-[0.12em] text-faint" title={view.goal.repo}>{areaLabel(view.goal.area)}</span>
            <span className="min-w-0 flex-1 truncate text-faint">{view.goal.report?.parked?.text}</span>
            <span className="shrink-0 font-mono text-xs text-faint">
              {shelfCount(view)} · {age} {span(at - (view.goal.archivedAt ?? view.goal.report?.parked?.at ?? view.lastMoveAt))}
            </span>
            <GoalActions phase={view.phase} goal={view.goal} moving={view.live.length} />
          </li>
        ))}
      </ul>
    </details>
  );
}

// A package's dot pops when its stage changes, so a glance catches what just moved.
export function Pip({ stage, failed }: { stage: Stage; failed?: boolean }) {
  const ref = useFlash<HTMLSpanElement>(`${stage}${failed ? ":failed" : ""}`, POP, 700);
  return <span ref={ref} className={`inline-block size-2 shrink-0 rounded-[2px] ${failed ? "bg-fail" : STAGE[stage].pip}`} title={STAGE[stage].label} />;
}

const DEPLOY_MARK: Record<DeployStep["state"], { mark: string; tone: string }> = {
  ok: { mark: "✓", tone: "text-merge" },
  failed: { mark: "✗ failed", tone: "text-fail" },
  pending: { mark: "…", tone: "text-checks" },
  waiting: { mark: "", tone: "" },
};

export function deployLabel(step: DeployStep) {
  return { text: `${step.env} ${DEPLOY_MARK[step.state].mark}`.trim(), tone: DEPLOY_MARK[step.state].tone };
}

// After the last merge: where the result is running. Shown only for goals whose repository has its
// deploy workflows tagged, and faint until a deploy has reported.
export function Deploy({ at, goal }: { at: number; goal: Goal }) {
  const steps = deployAt(goal, at);
  if (steps.length === 0) return null;

  return (
    <span className="shrink-0 font-mono text-xs text-faint">
      {steps.map((step) => {
        const label = deployLabel(step);
        return (
          <span key={step.env}>
            {" ┄ "}
            <span className={label.tone}>{label.text}</span>
          </span>
        );
      })}
    </span>
  );
}
