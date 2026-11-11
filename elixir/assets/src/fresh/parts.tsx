import { Check, ChevronRight, CircleDashed, Hourglass, ScanSearch, X } from "lucide-react";
import { useState, type ReactNode } from "react";

import { GoalActions, GoalRefusal, ShelfCleanup } from "./actions";
import { areaLabel } from "./areas";
import { deployAt, inRepos, span, type Ci, type DeployStep, type Goal, type GoalView, type Outcome, type Pr, type PkgView, type Review, type Stage } from "./model";
import { POP, Presence, useFlash } from "./motion";
import { Reveal } from "./reveal";

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

// Package and card rows are fixed column grids, so every column starts at the same x on every row,
// whatever is in it. Below 1280px the lifecycle shows only its current stage and the PR and owner columns narrow.
// Package: pip, title, lifecycle, status, PR with its CI, owner, action. Below 1000px only the pip, the title
// and the action share a line (see NARROW_HIDDEN), the title wraps instead of clipping, and the PR with its CI
// takes the line under the title (NARROW_UNDER), with an exited worker or the review state under it (NARROW_STATUS).
export const PKG_GRID = "grid grid-cols-[10px_minmax(0,1fr)_auto] items-center gap-x-2.5 min-[1000px]:grid-cols-[10px_minmax(0,1fr)_48px_124px_200px_150px_52px] min-[1280px]:grid-cols-[10px_minmax(0,1fr)_240px_124px_240px_170px_52px]";
// A package row cell that only fits from 1000px up.
export const NARROW_HIDDEN = "hidden min-[1000px]:grid";
// A package title: wrapped while narrow, clipped to its column once the row has every column.
export const PKG_TITLE = "text-sm wrap-break-word min-[1000px]:truncate";
// Narrow, the line under the package title, and the line under that for an exited worker or the review state.
export const NARROW_UNDER = "max-[1000px]:col-span-2 max-[1000px]:col-start-2 max-[1000px]:row-start-2";
export const NARROW_STATUS = "max-[1000px]:col-span-2 max-[1000px]:col-start-2 max-[1000px]:row-start-3";
// Narrow, a PR name wraps rather than clip, so the PR and its CI can take two lines.
export const NARROW_WRAP = "max-[1000px]:overflow-visible max-[1000px]:whitespace-normal max-[1000px]:wrap-anywhere";
// Card: pip, task, repo and branch, CI, review, PR, state, owner, dismiss. Below 1000px the pip, task, state and
// dismiss share a line, CI, review and PR take the line under the task (CARD_UNDER), and the rest drops out.
export const CARD_GRID = "grid grid-cols-[10px_minmax(0,1fr)_auto_auto] items-center gap-x-2.5 min-[1000px]:grid-cols-[10px_minmax(0,1fr)_150px_88px_128px_64px_72px_150px_24px] min-[1280px]:grid-cols-[10px_minmax(0,1fr)_200px_88px_128px_64px_72px_170px_24px]";
export const CARD_UNDER = "flex flex-wrap items-center gap-x-3 col-span-3 col-start-2 row-start-2 min-[1000px]:contents";

// A button that shows only a glyph: a small square that lights up under the pointer and for the keyboard.
export const GLYPH = "flex size-6 shrink-0 items-center justify-center rounded hover:bg-line hover:text-ink focus-visible:bg-line focus-visible:text-ink focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-you/70";
// A text button that reads as a link.
export const LINK = "rounded underline-offset-4 hover:text-ink hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-you/70";

// A glyph beside text, centred on that text's capitals (`.glyph` in fresh.css). It takes the type of the row it sits in.
export function Glyph({ children }: { children: ReactNode }) {
  return <span className="glyph">{children}</span>;
}

// A GitHub owner's avatar, a rounded square the height of the text beside it. Until it loads, and if it can't,
// the tile stays neutral and shows the owner's initial.
export function OrgIcon({ org }: { org: string | null }) {
  const [failed, setFailed] = useState<string | null>(null);
  if (!org) return null;

  return (
    <Glyph>
      <span aria-hidden className="size-[1em] items-center justify-center overflow-hidden rounded-[0.25em] bg-line text-dim" title={org}>
        {failed === org ? (
          <span className="text-[0.6em] font-semibold uppercase leading-none">{org[0]}</span>
        ) : (
          <img alt="" className="size-full" src={`https://github.com/${encodeURIComponent(org)}.png?size=64`} onError={() => setFailed(org)} />
        )}
      </span>
    </Glyph>
  );
}

// The chevron that opens and closes a goal or a question. Callers let its square overhang the row, so the text keeps its place,
// and give it the title's size when that differs from the row's.
export function Fold({ className = "", label, onToggle, open }: { className?: string; label: string; onToggle: () => void; open: boolean }) {
  return (
    <button aria-expanded={open} aria-label={label} className={`${GLYPH} text-faint ${className}`} type="button" onClick={onToggle}>
      <Glyph>
        <ChevronRight className={`size-4 transition-transform motion-reduce:transition-none ${open ? "rotate-90" : ""}`} />
      </Glyph>
    </button>
  );
}

// A live package's way from build to merge, one fixed slot per stage.
export const LIFECYCLE = [
  { label: "Build", tone: "text-build" },
  { label: "PR", tone: "text-build" },
  { label: "Checks", tone: "text-checks" },
  { label: "Review", tone: "text-review" },
  { label: "Merge", tone: "text-merge" },
];
const REVIEW_SLOT = 3;
// Normal is the default review mode, so only the others are named.
const MODE_WORD: Partial<Record<NonNullable<Review["mode"]>, string>> = { deep: "deep ", fast: "fast " };

const reviewing = (review: Review | null) => Boolean(review?.mode && review.mode !== "none" && review.state);

// Build until a PR opens; Review/CI is Review once a review runs and Checks before; ready is Merge.
export function slotOf(view: PkgView) {
  if (view.stage === "ready") return 4;
  if (view.stage === "review_ci") return reviewing(view.pkg.review) ? REVIEW_SLOT : 2;
  return view.pkg.pr ? 1 : 0;
}

// Stages behind are plain, the current one in its colour (red while its checks fail), the ones ahead faint.
// Below 1280px only the current stage shows, in the same place on every row. Screen readers hear only the current stage.
export function Lifecycle({ view }: { view: PkgView }) {
  const now = slotOf(view);
  const mode = view.pkg.review?.mode;
  return (
    <span className="flex whitespace-nowrap font-mono text-[11px]">
      <span className="sr-only">Stage: {LIFECYCLE[now].label}</span>
      {LIFECYCLE.map((slot, index) => {
        const tone = index < now ? "text-dim" : index === now ? `font-semibold ${view.failed ? "text-fail" : slot.tone}` : "text-faint";
        const title = index === REVIEW_SLOT && mode && mode !== "none" ? `${mode} review` : undefined;
        return (
          <span key={slot.label} aria-hidden className={`w-12 shrink-0 ${tone} ${index === now ? "" : "hidden min-[1280px]:inline"}`} title={title}>
            {slot.label}
          </span>
        );
      })}
    </span>
  );
}

// How long the package has been in its stage; under review, the round and how long it has run, or
// once the round has ended, how it ended.
// Right-aligned with tabular figures so the times line up.
export function StageStatus({ at, view }: { at: number; view: PkgView }) {
  const { pkg } = view;
  const cell = "truncate whitespace-nowrap text-right font-mono text-[11px] tabular-nums";
  // A worker that finished without opening a PR leaves its package implementing with nobody on it.
  if (pkg.exited && view.stage === "implementing") return <span className={`${cell} font-semibold text-checks`} title="The worker finished without opening a PR">Exited</span>;
  const review = pkg.review;
  if (slotOf(view) === REVIEW_SLOT && review) {
    const from = review.at ?? (view.untimed ? null : view.since);
    const words = reviewLabel(review);
    return (
      <span className={`${cell} ${words.tone}`} title={`Review: ${words.text}`}>
        {MODE_WORD[review.mode!] ?? ""}r{Math.max(1, review.round)}
        {review.state !== "running" ? ` · ${review.state}` : from === null ? "" : ` · ${span(at - from)}`}
      </span>
    );
  }
  // Narrow, the plain time in stage drops out; the exceptions above stay.
  return <span className={`${cell} text-dim max-[1000px]:hidden`}>{view.untimed ? "" : span(at - view.since)}</span>;
}

// Failing CI reads "CI" beside its ✗ like passing CI beside its ✓; hover and screen readers still get the state in words.
const CI: Record<Ci, { label: string; spoken?: string; tone: string; icon: typeof Check }> = {
  passing: { label: "CI", tone: "text-merge", icon: Check },
  pending: { label: "CI running", tone: "text-checks", icon: CircleDashed },
  failing: { label: "CI", spoken: "CI failing", tone: "text-fail", icon: X },
};

// The mode, then the state. A card's review has no known mode, so it shows the state alone.
export function reviewLabel(review: Review): { text: string; tone: string } {
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
        <Glyph>
          <CircleDashed aria-hidden className="size-3" />
        </Glyph>
        <span className="truncate">CI unknown</span>
      </span>
    );
  }
  if (!ci) return <span />;
  const check = CI[ci];
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${check.tone}`} title={check.spoken}>
      <Glyph>
        <check.icon aria-hidden className="size-3" />
      </Glyph>
      <span aria-hidden={check.spoken ? true : undefined} className="truncate">
        {check.label}
      </span>
      {check.spoken ? <span className="sr-only">{check.spoken}</span> : null}
    </span>
  );
}

// The Review Suite mode and state for the PR's current head. An empty cell keeps its column.
export function ReviewCell({ review }: { review: Review | null }) {
  if (!review) return <span />;
  const words = reviewLabel(review);
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${words.tone}`} title={`Review: ${words.text}`}>
      <Glyph>
        <ScanSearch aria-hidden className="size-3" />
      </Glyph>
      <span className="sr-only">Review </span>
      <span className="truncate">{words.text}</span>
    </span>
  );
}

// A PR in the goal's own repository is its number; one elsewhere also names its repository, without the owner.
// One that `waits` on that repository's maintainers carries an hourglass and says so on hover.
export function PrLink({ className = "", pr, repos, waits = false }: { className?: string; pr: Pr | null; repos: string[]; waits?: boolean }) {
  if (!pr) return <span />;
  const name = inRepos(pr.repo, repos) ? `#${pr.number}` : `${pr.repo.split("/").at(-1)}#${pr.number}`;
  return (
    <a className={`truncate ${className} font-mono text-[11px] text-dim underline decoration-dotted underline-offset-2 hover:text-ink`} href={pr.url} rel="noreferrer" target="_blank" title={waits ? `Waiting for ${pr.repo} to merge this` : `Open PR ${pr.repo}#${pr.number}`}>
      {waits ? (
        <span className="mr-1 text-checks">
          <Glyph>
            <Hourglass aria-hidden className="size-3" />
          </Glyph>
        </span>
      ) : null}
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
  return (
    <Reveal className="mt-8" holds={views.map((view) => view.goal.id)} show={views.length > 0}>
      <details className="text-sm text-dim">
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
          <Presence items={views} keyOf={(view) => view.goal.id}>
            {({ item: view, key, ref }) => (
            <li key={key} ref={ref} className="flex flex-wrap items-center justify-between gap-x-4" data-goal={view.goal.id}>
              <span className="min-w-0 truncate">{view.goal.title}</span>
              <span className="shrink-0 text-[11px] uppercase tracking-[0.12em] text-faint" title={view.goal.repo}>{areaLabel(view.goal.area)}</span>
              <span className="min-w-0 flex-1 truncate text-faint">{view.goal.report?.parked?.text}</span>
              <span className="shrink-0 font-mono text-xs text-faint">
                {shelfCount(view)} · {age} {span(at - (view.goal.archivedAt ?? view.goal.report?.parked?.at ?? view.lastMoveAt))}
              </span>
              <GoalActions phase={view.phase} goal={view.goal} />
              <GoalRefusal className="basis-full" goalId={view.goal.id} />
            </li>
            )}
          </Presence>
        </ul>
      </details>
    </Reveal>
  );
}

// A package's dot pops when its stage changes, so a glance catches what just moved.
export function Pip({ stage, failed }: { stage: Stage; failed?: boolean }) {
  const ref = useFlash(`${stage}${failed ? ":failed" : ""}`, POP, 700);
  return <span ref={ref} data-pip className={`inline-block size-2 shrink-0 rounded-[2px] ${failed ? "bg-fail" : STAGE[stage].pip}`} title={STAGE[stage].label} />;
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
