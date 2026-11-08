import { X } from "lucide-react";
import { useState } from "react";

import { ActButton } from "./actions";
import { readOnly } from "./api";
import { span, type Card, type CardState } from "./model";
import { useAct } from "./operator";
import { Owner } from "./owner";
import { Gates, PrLink } from "./parts";

const DAY = 24 * 3600e3;
const ORDER: Record<CardState, number> = { review_ci: 0, working: 1, merged: 2, done: 3 };
const STATE: Record<CardState, { label: string; tone: string; pip: string }> = {
  working: { label: "Working", tone: "text-build", pip: "bg-build" },
  review_ci: { label: "Review/CI", tone: "text-review", pip: "bg-review" },
  merged: { label: "Merged", tone: "text-merge/80", pip: "bg-merge/40" },
  done: { label: "Done", tone: "text-dim", pip: "bg-faint" },
};
const ROW = "grid grid-cols-[10px_minmax(0,1fr)_minmax(0,200px)_220px_70px_70px_190px_24px] items-center gap-3 rounded px-2 py-1 odd:bg-white/[0.035]";

// Ended cards drop off a day after they merged or their terminal finished; dismissed ones right away.
export function visibleCards(cards: Card[], at: number) {
  return cards.filter((card) => !card.dismissed && (card.state === "working" || card.state === "review_ci" || at - card.since < DAY));
}

// Small work a chief handed to a child terminal, with no WorkRequest behind it.
export function Cards({ at, cards }: { at: number; cards: Card[] }) {
  if (cards.length === 0) return null;
  const merged = cards.filter((card) => card.state === "merged");

  return (
    <section className="mt-8">
      <div className="mb-1 flex items-baseline gap-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">Small work · {cards.length}</h2>
        {merged.length > 0 ? <ActButton action={{ kind: "dismiss", cardIds: merged.map((card) => card.id) }} className="ml-auto" label={`Hide merged (${merged.length})`} tone="text-faint" /> : null}
      </div>
      <div className="border-y border-line py-1">
        {[...cards].sort((left, right) => ORDER[left.state] - ORDER[right.state] || right.since - left.since).map((card) => (
          <CardRow key={card.id} at={at} card={card} />
        ))}
      </div>
    </section>
  );
}

function CardRow({ at, card }: { at: number; card: Card }) {
  const meta = STATE[card.state];
  const ended = card.state === "merged" || card.state === "done";

  return (
    <div className={ROW}>
      <span aria-hidden className={`size-2 rounded-[2px] ${meta.pip}`} />
      <span className={`truncate text-sm ${ended ? "text-dim" : "text-ink"}`}>{card.task}</span>
      <span className="truncate font-mono text-[11px] text-faint" title={`${card.repo} · ${card.branch}`}>
        {card.repo.split("/").pop()} · {card.branch}
      </span>
      <Gates ci={card.ci} review={card.review} />
      <PrLink pr={card.pr} repo={card.repo} />
      <span className={`whitespace-nowrap font-mono text-[11px] font-semibold ${meta.tone}`} title={`${meta.label} for ${span(at - card.since)}`}>
        {meta.label}
      </span>
      <Owner owner={card.by} subject={{ cardId: card.id }} />
      <Dismiss card={card} />
    </div>
  );
}

function Dismiss({ card }: { card: Card }) {
  const act = useAct();
  const [failure, setFailure] = useState<string | null>(null);
  if (readOnly) return <span />;
  const dismiss = () => act({ kind: "dismiss", cardIds: [card.id] }).catch((caught: unknown) => setFailure(caught instanceof Error ? caught.message : "The backend refused this."));
  return (
    <button aria-label={`Dismiss ${card.task}`} className={`flex size-6 items-center justify-center rounded hover:bg-line hover:text-ink ${failure ? "text-fail" : "text-faint"}`} title={failure ?? "Dismiss"} type="button" onClick={() => void dismiss()}>
      <X className="size-3.5" />
    </button>
  );
}
