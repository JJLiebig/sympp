// What the operator entered, and a send still under way or refused, kept outside the components that show it.
// A form unmounts when the operator changes tab or screen, or when the screen crosses the phone width and the
// board changes layout; what it held is there when it comes back.
import { useSyncExternalStore } from "react";

const kept = new Map<string, unknown>();
const listeners = new Set<() => void>();

// `blank` must be the same object on every call.
export function useKept<T>(key: string, blank: T): [T, (change: (was: T) => T) => void] {
  const value = useSyncExternalStore(
    (listen) => {
      listeners.add(listen);
      return () => listeners.delete(listen);
    },
    () => (kept.get(key) as T | undefined) ?? blank,
  );
  const update = (change: (was: T) => T) => {
    kept.set(key, change((kept.get(key) as T | undefined) ?? blank));
    listeners.forEach((listen) => listen());
  };
  return [value, update];
}
