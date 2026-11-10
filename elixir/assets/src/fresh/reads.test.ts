import { expect, it, vi } from "vitest";

import { coalescedRead } from "./reads";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

it("publishes answered asks despite continuous invalidations and catches up after a failed read", async () => {
  const first = deferred<string[]>();
  const answered = deferred<string[]>();
  const failed = deferred<string[]>();
  const recovered = deferred<string[]>();
  const load = vi.fn()
    .mockReturnValueOnce(first.promise)
    .mockReturnValueOnce(answered.promise)
    .mockReturnValueOnce(failed.promise)
    .mockReturnValueOnce(recovered.promise);
  const show = vi.fn();
  const fail = vi.fn();
  const { read, changed } = coalescedRead(load, show, fail);
  void read();
  // More changes than the dashboard can read: they must not discard its results
  // or start concurrent reads. The next read contains the committed answer.
  for (let i = 0; i < 20; i++) changed();
  expect(load).toHaveBeenCalledTimes(1);
  first.resolve(["open-ask"]);
  await first.promise;
  expect(show).toHaveBeenLastCalledWith(["open-ask"]);
  expect(load).toHaveBeenCalledTimes(2);
  changed();
  answered.resolve([]);
  await answered.promise;
  expect(show).toHaveBeenLastCalledWith([]);
  expect(load).toHaveBeenCalledTimes(3);
  changed();
  const offline = new Error("offline");
  failed.reject(offline);
  await failed.promise.catch(() => undefined);
  expect(fail).toHaveBeenCalledWith(offline);
  recovered.resolve([]);
  await recovered.promise;
  expect(show).toHaveBeenCalledTimes(3);
  expect(load).toHaveBeenCalledTimes(4);
  // A later timer or reconnect can start another read after the queue drains.
  load.mockResolvedValueOnce(["new-ask"]);
  await read();
  expect(show).toHaveBeenLastCalledWith(["new-ask"]);
});

it("explicit refreshes recover from stalled reads and reject pre-save data and errors", async () => {
  const stalled = deferred<string>();
  const preSave = deferred<string>();
  const load = vi.fn().mockReturnValueOnce(stalled.promise).mockReturnValueOnce(preSave.promise).mockResolvedValue("saved");
  const show = vi.fn();
  const fail = vi.fn();
  const { read, changed } = coalescedRead(load, show, fail);
  const initial = read();
  changed();
  const beforeSave = read();
  changed();
  // The successful save starts its own read despite both earlier fetches hanging.
  await read();
  expect(show).toHaveBeenLastCalledWith("saved");
  preSave.resolve("old settings");
  await beforeSave;
  stalled.reject(new Error("old connection"));
  await initial;
  expect(show).toHaveBeenCalledExactlyOnceWith("saved");
  expect(fail).not.toHaveBeenCalled();
  expect(load).toHaveBeenCalledTimes(3);
});
