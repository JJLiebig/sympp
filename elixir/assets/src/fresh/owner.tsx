import { ActButton } from "./actions";
import type { Liveness, Role, Terminal } from "./model";
import { Glyph } from "./parts";

const ROLE: Record<Role, string> = { chief: "chief", architect: "architect", worker: "worker", card: "agent" };
const LIVENESS: Record<Liveness, string> = { live: "live", unknown: "not answering", finished: "finished" };
// Shape carries the state as well as colour: filled while live, a ring while unknown, a dash once finished.
const DOT: Record<Liveness, string> = { live: "size-1.5 rounded-full bg-merge", unknown: "size-2 rounded-full border border-checks", finished: "h-px w-2 bg-faint" };

// The terminal working on something. A goal's owner whose machine stopped answering can be released so another terminal can take over.
export function Owner({ className = "", goalId, owner }: { className?: string; goalId?: string; owner: Terminal | null }) {
  if (!owner) return <span className={className} />;
  const liveness = owner.liveness;
  const about = [owner.topic, owner.role ? ROLE[owner.role] : null].filter(Boolean).join(" ");
  const title = [about, liveness ? LIVENESS[liveness] : null].filter(Boolean).join(" · ");

  return (
    <span className={`flex min-w-0 items-center gap-2 ${className}`}>
      <span className={`flex min-w-0 items-center gap-1.5 font-mono text-[11px] ${liveness === "finished" ? "text-faint" : "text-dim"}`} title={title || undefined}>
        {liveness ? (
          <Glyph>
            <span aria-hidden className={DOT[liveness]} />
          </Glyph>
        ) : null}
        <span className="truncate">{owner.address}</span>
        {liveness ? <span className="sr-only">, {LIVENESS[liveness]}</span> : null}
      </span>
      {goalId && liveness === "unknown" ? <ActButton action={{ kind: "release", goalId }} confirm="Release?" label="Release" tone="text-checks" /> : null}
    </span>
  );
}
