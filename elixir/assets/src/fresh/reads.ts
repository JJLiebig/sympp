// Keep one read in flight and remember changes received while it runs. Publishing
// each result prevents a busy ledger from starving the board of fresh data.
export function coalescedRead<T>(load: () => Promise<T>, show: (value: T) => void, fail: (error: unknown) => void) {
  let running = false;
  let pending = false;
  return async () => {
    pending = true;
    if (running) return;
    running = true;
    try {
      do {
        pending = false;
        try {
          show(await load());
        } catch (error) {
          fail(error);
        }
      } while (pending);
    } finally {
      running = false;
    }
  };
}
