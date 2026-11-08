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

// Where a moving package is: four steps from launch to ready, and the current one with how long it has been there.
export function Track({ at, view }: { at: number; view: PkgView }) {
  const position = STEPS.indexOf(view.stage);
  const tone = view.failed ? "text-fail" : STAGE[view.stage].text;

  return (
    <span className="flex items-center gap-2 whitespace-nowrap font-mono text-[11px]">
      <span aria-hidden className="flex gap-0.5">
        {STEPS.map((step, index) => (
          <span key={step} className={`h-1 w-2.5 rounded-full ${index < position ? "bg-dim" : index === position ? (view.failed ? "bg-fail" : STAGE[step].bar) : "bg-line"}`} />
        ))}
      </span>
      <span className={`font-semibold ${tone}`}>
        {STAGE[view.stage].label}
        {view.untimed ? "" : <span className="font-normal text-dim"> · {span(at - view.since)}</span>}
      </span>
    </span>
  );
}

const CI: Record<Ci, { label: string; tone: string; icon: typeof Check }> = {
  passing: { label: "CI", tone: "text-merge", icon: Check },
  pending: { label: "CI running", tone: "text-checks", icon: CircleDashed },
  failing: { label: "CI failing", tone: "text-fail", icon: X },
};

function reviewLabel(review: Review): { text: string; tone: string } {
  if (review.mode === "none") return { text: "none", tone: "text-faint" };
  const round = review.round > 1 ? ` · round ${review.round}` : "";
  if (review.state === "running") return { text: `${review.mode}${round}`, tone: "text-review" };
  if (review.state === "findings") return { text: `${review.mode} · findings`, tone: "text-checks" };
  if (review.state === "done") return { text: `${review.mode} · done`, tone: "text-merge/80" };
  if (review.state === "unknown") return { text: `${review.mode} · unknown`, tone: "text-faint" };
  return { text: review.mode, tone: "text-faint" };
}

// The PR's checks and its Review Suite state, shown once there is something to check.
export function Gates({ ci, review }: { ci: Ci | null; review: Review | null }) {
  if (!ci && !review) return <span />;
  const check = ci ? CI[ci] : null;
  const words = review ? reviewLabel(review) : null;

  return (
    <span className="flex min-w-0 items-center gap-3 whitespace-nowrap font-mono text-[11px]">
      {check ? (
        <span className={`flex items-center gap-1 ${check.tone}`}>
          <check.icon aria-hidden className="size-3" />
          {check.label}
        </span>
      ) : null}
      {words ? (
        <span className={`flex min-w-0 items-center gap-1 ${words.tone}`} title={`Review: ${words.text}`}>
          <ScanSearch aria-hidden className="size-3 shrink-0" />
          <span className="sr-only">Review </span>
          <span className="truncate">{words.text}</span>
        </span>
      ) : null}
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
