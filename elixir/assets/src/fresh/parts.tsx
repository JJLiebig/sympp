import { Check, ChevronRight, Circle, CircleAlert, CircleDashed, CircleQuestionMark, Hourglass, Minus, X } from "lucide-react";
import { useState, type ReactNode } from "react";

import { GoalActions, GoalRefusal, ShelfCleanup } from "./actions";
import { areaLabel } from "./areas";
import { blockedOn, type BlockedOn, type BlockerTarget } from "./blocked";
import { deployAt, inRepos, span, type Ci, type DeployStep, type Goal, type GoalView, type Outcome, type Pr, type PkgView, type Review, type Stage } from "./model";
import { focusAsk, focusGoal, focusPkg, POP, Presence, useFlash } from "./motion";
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
// Package: pip, title, lifecycle, status, PR, CI, owner, action. Below 1000px only the pip, the title
// and the action share a line (see NARROW_HIDDEN), the title wraps instead of clipping, and the PR with its CI
// takes the line under the title (NARROW_UNDER), with an exited worker or the review state under it (NARROW_STATUS).
export const PKG_GRID = "grid grid-cols-[10px_minmax(0,1fr)_auto] items-center gap-x-2.5 min-[1000px]:grid-cols-[10px_minmax(0,1fr)_48px_124px_120px_40px_150px_52px] min-[1280px]:grid-cols-[10px_minmax(0,1fr)_240px_124px_150px_40px_170px_52px]";
// A package row cell that only fits from 1000px up.
export const NARROW_HIDDEN = "hidden min-[1000px]:grid";
// A package title: wrapped while narrow, clipped to its column once the row has every column.
export const PKG_TITLE = "text-sm wrap-break-word min-[1000px]:truncate";
// Narrow, the line under the package title, and the line under that for an exited worker or the review state.
export const NARROW_UNDER = "max-[1000px]:col-span-2 max-[1000px]:col-start-2 max-[1000px]:row-start-2";
export const NARROW_STATUS = "max-[1000px]:col-span-2 max-[1000px]:col-start-2 max-[1000px]:row-start-3";
// Narrow, the PR and its CI share the line under the title; from 1000px each takes its own column.
export const PR_AND_CI = `flex min-w-0 flex-wrap items-center gap-x-2 min-[1000px]:contents ${NARROW_UNDER}`;
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

// The state of a review or of CI is a coloured icon; hover and screen readers get it in words. Review and CI share shapes:
// dashed while it runs, a tick once it passed, a question mark when it could not be read.
type Mark = { icon: typeof Check; tone: string; spoken: string };

const CI: Record<Ci, Mark> = {
  passing: { icon: Check, tone: "text-merge", spoken: "CI passing" },
  pending: { icon: CircleDashed, tone: "text-checks", spoken: "CI running" },
  failing: { icon: X, tone: "text-fail", spoken: "CI failing" },
};
const CI_UNREAD: Mark = { icon: CircleQuestionMark, tone: "text-faint", spoken: "CI status unavailable" };

// `waiting` is a review with no result for the PR's current head yet; `skipped` one whose mode is none.
type ReviewMark = NonNullable<Review["state"]> | "waiting" | "skipped";
const REVIEW: Record<ReviewMark, Mark> = {
  running: { icon: CircleDashed, tone: "text-review", spoken: "Review: running" },
  findings: { icon: CircleAlert, tone: "text-checks", spoken: "Review: findings" },
  done: { icon: Check, tone: "text-merge/80", spoken: "Review: passed" },
  unknown: { icon: CircleQuestionMark, tone: "text-faint", spoken: "Review: status unavailable" },
  waiting: { icon: Circle, tone: "text-faint", spoken: "Review: none for latest commit" },
  skipped: { icon: Minus, tone: "text-faint", spoken: "Review: skipped" },
};

function reviewMark(review: Review): Mark {
  return REVIEW[review.mode === "none" ? "skipped" : (review.state ?? "waiting")];
}

// The review's mode, unless it is the default, and its round.
const modeAndRound = (review: Review) => `${MODE_WORD[review.mode!] ?? ""}r${Math.max(1, review.round)}`;

// A state icon, centred on the text beside it.
function MarkIcon({ mark }: { mark: Mark }) {
  return (
    <Glyph>
      <mark.icon aria-hidden className="size-3" />
    </Glyph>
  );
}

// How long the package has been in its stage, right-aligned with tabular figures so the times line up. Under review,
// the review's state icon, its mode and round, and while it runs how long the round has run: the icon at the
// column's start and the time at its end, so both line up with the rows above and below. Narrow, the cell sits
// under the title and keeps to its right edge.
export function StageStatus({ at, still = false, view }: { at: number; still?: boolean; view: PkgView }) {
  const { pkg } = view;
  const cell = "truncate whitespace-nowrap text-right font-mono text-[11px] tabular-nums";
  const blocked = blockedOn(pkg);
  if (blocked) return <BlockedLabel blocked={blocked} className={cell} still={still} />;
  // A worker that finished without opening a PR leaves its package implementing with nobody on it.
  if (pkg.exited && view.stage === "implementing") return <span className={`${cell} font-semibold text-checks`} title="The worker finished without opening a PR">Exited</span>;
  const review = pkg.review;
  if (slotOf(view) === REVIEW_SLOT && review) {
    const from = review.at ?? (view.untimed ? null : view.since);
    const mark = reviewMark(review);
    return (
      <span className={`grid grid-flow-col items-center justify-end gap-x-1.5 whitespace-nowrap font-mono text-[11px] tabular-nums min-[1000px]:grid-cols-[auto_minmax(0,1fr)_auto] min-[1000px]:justify-stretch ${mark.tone}`} title={mark.spoken}>
        <MarkIcon mark={mark} />
        <span className="sr-only">{mark.spoken}</span>
        <span className="truncate">{modeAndRound(review)}</span>
        {review.state === "running" && from !== null ? <span className="text-right">{span(at - from)}</span> : null}
      </span>
    );
  }
  // Narrow, the plain time in stage drops out; the exceptions above stay.
  return <span className={`${cell} text-dim max-[1000px]:hidden`}>{view.untimed ? "" : span(at - view.since)}</span>;
}

// A blocked package says so in its status cell. Hover lists what it waits on; a click opens the first of them.
// `still` keeps it plain text where a tap already belongs to the row.
export function BlockedLabel({ blocked, className, still = false }: { blocked: BlockedOn; className: string; still?: boolean }) {
  const label = `${className} font-semibold text-fail`;
  const tip = blocked.lines.join("\n");
  const target = blocked.target;
  if (still || !target) return <span className={label} title={tip}>Blocked</span>;
  return (
    <button
      className={`${label} cursor-pointer underline-offset-2 hover:underline`}
      title={tip}
      type="button"
      onClick={(event) => {
        event.stopPropagation();
        openBlocker(target);
      }}
    >
      Blocked
    </button>
  );
}

function openBlocker(target: BlockerTarget) {
  if (target.kind === "pr") {
    const [repo, number] = target.id.split("#");
    window.open(`https://github.com/${repo}/pull/${number}`, "_blank", "noopener,noreferrer");
  } else if (target.kind === "ask") focusAsk(target.id);
  else if (target.kind === "work_request") focusGoal(target.id);
  else if (target.goalId) focusPkg(target.goalId, target.id);
}

// The mode, then the state, in words, for a phone, which has no hover. A card's review has no known mode, so it shows the state alone.
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

// The icon, then what it is about, the way a passing check reads "✓ CI".
function MarkCell({ label, mark }: { label: string; mark: Mark }) {
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${mark.tone}`} title={mark.spoken}>
      <MarkIcon mark={mark} />
      <span aria-hidden className="truncate">
        {label}
      </span>
      <span className="sr-only">{mark.spoken}</span>
    </span>
  );
}

// The PR's checks. An empty cell keeps its column. When GitHub could not be read, the last result is not shown as current.
export function CiCell({ ci, stale = false }: { ci: Ci | null; stale?: boolean }) {
  if (stale) return <MarkCell label="CI" mark={CI_UNREAD} />;
  if (!ci) return <span />;
  return <MarkCell label="CI" mark={CI[ci]} />;
}

// The Review Suite state for the PR's current head, beside "Review" the way CI's sits beside "CI". `spelled`, for a phone,
// adds the mode and state in words. An empty cell keeps its column.
export function ReviewCell({ review, spelled = false }: { review: Review | null; spelled?: boolean }) {
  if (!review) return <span />;
  const mark = reviewMark(review);
  if (!spelled) return <MarkCell label="Review" mark={mark} />;
  return (
    <span className={`flex min-w-0 items-center gap-1 whitespace-nowrap font-mono text-[11px] ${mark.tone}`} title={mark.spoken}>
      <MarkIcon mark={mark} />
      <span className="sr-only">Review </span>
      <span className="truncate">{reviewLabel(review).text}</span>
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
