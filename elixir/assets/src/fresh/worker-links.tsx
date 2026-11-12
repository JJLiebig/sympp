import type { ReactNode } from "react";
import type { Terminal } from "./model";

// The standalone board cannot focus a native Herdr window. Offer its attach target.
export function WorkerTarget({ terminal, children }: { terminal: Terminal; children: ReactNode }) {
  if (terminal.role !== "worker") return children;
  const command = `hc attach ${terminal.address}`;
  return (
    <details className="relative min-w-0">
      <summary className="cursor-pointer list-none truncate hover:text-ink" title={command}>{children}</summary>
      <input aria-label={`Attach to ${terminal.address}`} className="block min-[1000px]:absolute min-[1000px]:right-0 min-[1000px]:top-full z-20 mt-1 w-64 max-w-full min-[1000px]:max-w-none rounded border border-line bg-surface p-2 font-mono text-xs text-ink shadow-md" readOnly value={command} onFocus={(event) => event.currentTarget.select()} />
    </details>
  );
}

export function PreviewLink({ terminal }: { terminal: Terminal }) {
  if (terminal.liveness !== "live" || !terminal.previewUrl) return null;
  return (
    <a className="inline-flex shrink-0 items-center gap-1 rounded border border-build/40 px-1.5 py-0.5 text-[11px] font-medium leading-none text-build transition-colors hover:border-build hover:bg-build/10" href={terminal.previewUrl} target="_blank" rel="noopener noreferrer">
      Preview
      <svg aria-hidden className="size-2.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} viewBox="0 0 12 12">
        <path d="M4 2h6v6M10 2 3 9" />
      </svg>
    </a>
  );
}
