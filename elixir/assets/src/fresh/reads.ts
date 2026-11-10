// Change signals queue one catch-up read without invalidating the active read.
// Explicit reads supersede earlier work, so saves, timers and reconnects can
// recover from a stalled fetch and cannot be overwritten by a pre-save response.
export function coalescedRead<T>(load: () => Promise<T>, show: (value: T) => void, fail: (error: unknown) => void) {
  let running = false;
  let pending = false;
  let sequence = 0;
  const read = async () => {
    const turn = ++sequence;
    pending = false;
    running = true;
    try {
      const value = await load();
      if (turn === sequence) show(value);
    } catch (error) {
      if (turn === sequence) fail(error);
    } finally {
      if (turn === sequence) {
        running = false;
        if (pending) void read();
      }
    }
  };
  const changed = () => {
    if (running) pending = true;
    else void read();
  };
  return { read, changed };
}
