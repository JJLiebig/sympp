import { Component, type ReactNode } from "react";

import { Presence, useRoll } from "./motion";

const SHOWN = ["shown"];
const HIDDEN: string[] = [];
const same = (key: string) => key;

// A section that opens and closes by animating its height. While it closes it keeps showing what it showed last.
export class Reveal extends Component<{ children: ReactNode; className?: string; show: boolean }> {
  private kept: ReactNode = null;

  render() {
    if (this.props.show) this.kept = this.props.children;
    return (
      <Presence items={this.props.show ? SHOWN : HIDDEN} keyOf={same}>
        {(entry) => (
          <div key={entry.key} ref={entry.ref} className={this.props.className}>
            {this.kept}
          </div>
        )}
      </Presence>
    );
  }
}

// A count that rolls to its new value.
export function Roll({ value }: { value: number }) {
  const ref = useRoll(value);
  return <span ref={ref} className="inline-block h-[1.25em] overflow-hidden align-bottom leading-[1.25em] tabular-nums" />;
}
