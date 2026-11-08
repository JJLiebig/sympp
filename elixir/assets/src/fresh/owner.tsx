import { ActButton } from "./actions";
import type { Liveness, Role, Terminal } from "./model";
import type { Subject } from "./operator";

const ROLE: Record<Role, string> = { chief: "Chief", architect: "Architect", worker: "Worker", card: "Agent" };
const LIVENESS: Record<Liveness, string> = { live: "live", unknown: "not answering", finished: "finished" };
// Shape carries the state as well as colour: filled while live, a ring while unknown, a dash once finished.
const DOT: Record<Liveness, string> = { live: "size-1.5 rounded-full bg-merge", unknown: "size-2 rounded-full border border-checks", finished: "h-px w-2 bg-faint" };

// The terminal working on something. Where it owns `subject` and its machine stopped answering, it can be released so others can take over.
export function Owner({ className = "", owner, subject }: { className?: string; owner: Terminal | null; subject?: Subject }) {
  if (!owner) return <span className={className} />;
  const finished = owner.liveness === "finished";

  return (
    <span className={`flex min-w-0 items-center gap-2 ${className}`}>
      <span className={`flex min-w-0 items-center gap-1.5 font-mono text-[11px] ${finished ? "text-faint" : "text-dim"}`} title={`${owner.topic ? `${owner.topic} ` : ""}${ROLE[owner.role].toLowerCase()} · ${LIVENESS[owner.liveness]}`}>
        <span aria-hidden className={`shrink-0 ${DOT[owner.liveness]}`} />
        <span className="truncate">{owner.address}</span>
        <span className="sr-only">, {LIVENESS[owner.liveness]}</span>
      </span>
      {subject && owner.liveness === "unknown" ? <ActButton action={{ kind: "release", subject }} confirm="Release?" label="Release" tone="text-checks" /> : null}
    </span>
  );
}
