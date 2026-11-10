import { X } from "lucide-react";
import { useState } from "react";

import { ActButton } from "./actions";
import { span, type Card, type CardState } from "./model";
import { Presence } from "./motion";
import { useAct } from "./operator";
import { Owner } from "./owner";
import { Reveal } from "./reveal";
import { CARD_GRID, CARD_UNDER, CiCell, NARROW_HIDDEN, NARROW_WRAP, PKG_TITLE, PrLink, ReviewCell } from "./parts";

const DAY = 24 * 3600e3;
type Shown = Exclude<CardState, "dismissed">;
const ORDER: Record<Shown, number> = { review_ci: 0, working: 1, merged: 2, done: 3 };
const STATE: Record<Shown, { label: string; tone: string; pip: string }> = {
  working: { label: "Working", tone: "text-build", pip: "bg-build" },
  review_ci: { label: "Review/CI", tone: "text-review", pip: "bg-review" },
  merged: { label: "Merged", tone: "text-merge/80", pip: "bg-merge/40" },
  done: { label: "Done", tone: "text-dim", pip: "bg-faint" },
};
const ROW = `${CARD_GRID} rounded px-2 py-1 odd:bg-white/[0.035]`;

// Ended cards drop off a day after they merged or their terminal finished; dismissed ones right away.
// A replay shows a card only once it exists, and an ended one only from its ending.
export function visibleCards(cards: Card[], at: number): Array<Card & { state: Shown }> {
  return cards.filter((card): card is Card & { state: Shown } => {
    if (card.from > at) return false;
    if (card.state === "working" || card.state === "review_ci") return true;
    return (card.state === "merged" || card.state === "done") && at >= card.since && at - card.since < DAY;
  });
}

// Small work a chief handed to a child terminal, with no WorkRequest behind it.
export function Cards({ at, cards }: { at: number; cards: Array<Card & { state: Shown }> }) {
  const sorted = [...cards].sort((left, right) => ORDER[left.state] - ORDER[right.state] || right.since - left.since);
  const merged = cards.filter((card) => card.state === "merged");

  return (
    <Reveal className="mt-8" show={cards.length > 0}>
      <section>
        <div className="mb-1 flex items-baseline gap-3">
          <h2 className="text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">Small work · {cards.length}</h2>
          {merged.length > 0 ? <ActButton action={{ kind: "dismiss", cardIds: merged.map((card) => card.id) }} className="ml-auto" label={`Hide merged (${merged.length})`} tone="text-faint" /> : null}
        </div>
        <div className="border-y border-line py-1">
          <Presence items={sorted} keyOf={(card) => card.id}>
            {({ item, key, ref }) => <CardRow key={key} ref={ref} at={at} card={item} />}
          </Presence>
        </div>
      </section>
    </Reveal>
  );
}

function CardRow({ at, card, ref }: { at: number; card: Card & { state: Shown }; ref: (node: HTMLElement | null) => void }) {
  const meta = STATE[card.state];
  const ended = card.state === "merged" || card.state === "done";

  return (
    <div ref={ref} className={ROW}>
      <span aria-hidden className={`size-2 rounded-[2px] ${meta.pip}`} />
      <span className={`${PKG_TITLE} ${ended ? "text-dim" : "text-ink"}`}>{card.task}</span>
      <span className={`truncate font-mono text-[11px] text-faint ${NARROW_HIDDEN}`} title={`${card.repo} · ${card.branch}`}>
        {card.repo.split("/").pop()} · {card.branch}
      </span>
      <span className={CARD_UNDER}>
        <CiCell ci={card.ci} stale={card.stale.includes("github")} />
        <ReviewCell review={card.review} />
        <PrLink className={NARROW_WRAP} pr={card.pr} repos={[card.repo.toLowerCase()]} />
      </span>
      <span className={`whitespace-nowrap font-mono text-[11px] font-semibold ${meta.tone}`} title={`${meta.label} for ${span(at - card.since)}`}>
        {meta.label}
      </span>
      <span className={NARROW_HIDDEN}>
        <Owner owner={card.by} />
      </span>
      <Dismiss card={card} />
    </div>
  );
}

function Dismiss({ card }: { card: Card }) {
  const act = useAct();
  const [failure, setFailure] = useState<string | null>(null);
  const dismiss = () => act({ kind: "dismiss", cardIds: [card.id] }).catch((caught: unknown) => setFailure(caught instanceof Error ? caught.message : "The backend refused this."));
  return (
    <button aria-label={`Dismiss ${card.task}`} className={`flex size-6 items-center justify-center rounded hover:bg-line hover:text-ink ${failure ? "text-fail" : "text-faint"}`} title={failure ?? "Dismiss"} type="button" onClick={() => void dismiss()}>
      <X className="size-3.5" />
    </button>
  );
}
