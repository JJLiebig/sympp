import { Laptop, Monitor, Server, SquareTerminal, type LucideIcon } from "lucide-react";

import { readOnly } from "./api";
import { type PkgView, type Place } from "./model";

const KIND: Record<string, { kind: string; icon: LucideIcon }> = { desktop: { kind: "Desktop", icon: Monitor }, laptop: { kind: "Laptop", icon: Laptop }, server: { kind: "Server", icon: Server } };
const SAMPLE_MACHINES = [["desktop-1", "desktop"], ["desktop-1", "desktop"], ["desktop-1", "desktop"], ["laptop-1", "laptop"], ["vps-1", "server"]];

// Sketch only: a session from a snapshot's recorded history, or on a sample goal, gets a made-up machine.
function samplePlace(id: string): Place {
  const hash = [...id].reduce((sum, char) => sum + char.charCodeAt(0), 0);
  const [machine, kind] = SAMPLE_MACHINES[hash % SAMPLE_MACHINES.length];
  return { machine, kind, sample: true };
}

// The machine a package's session runs on. It opens on hover and on keyboard focus.
function PlaceCard({ place, thread }: { place: Place; thread?: string | null }) {
  const rows = [
    [KIND[place.kind ?? ""]?.kind ?? "Machine", place.machine],
    ["Thread", thread],
  ].filter((row): row is string[] => Boolean(row[1]));

  return (
    <span className="pointer-events-none absolute right-0 top-full z-30 mt-1 hidden w-72 rounded border border-line bg-bg p-2.5 text-left text-xs font-normal shadow-xl group-hover:block group-focus-visible:block">
      {rows.map(([label, value]) => (
        <span key={label} className="flex justify-between gap-3 py-0.5">
          <span className="shrink-0 text-faint">{label}</span>
          <span className="truncate text-ink">{value}</span>
        </span>
      ))}
    </span>
  );
}

// Where a package's session is: only the machine icon on the line, the details on hover.
export function Session({ view }: { view: PkgView }) {
  const place = view.pkg.location ?? (view.actor ? samplePlace(view.pkg.id) : null);
  if (readOnly || !place) return <span />;
  const Icon = KIND[place.kind ?? ""]?.icon ?? SquareTerminal;

  return (
    <span aria-label={`Session for ${view.pkg.title}`} className="group relative flex size-6 items-center justify-center rounded text-dim hover:bg-line hover:text-ink" role="img" tabIndex={0}>
      <Icon className="size-3.5" />
      <PlaceCard place={place} thread={view.actor} />
    </span>
  );
}
