import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { quarantineControllerLock, windowsDrivePath } from "./controller";

describe("controller lock recovery", () => {
  it("does not remove a replacement after another controller fences the stale owner", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-herdr-lock-"));
    const lockPath = path.join(directory, "controller.lock");
    try {
      fs.writeFileSync(lockPath, "stale-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      fs.writeFileSync(lockPath, "replacement-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      expect(fs.readFileSync(lockPath, "utf8")).toBe("replacement-owner");
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });

  it("does not remove a replacement through a stale owner observation", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-herdr-lock-"));
    const lockPath = path.join(directory, "controller.lock");
    try {
      fs.writeFileSync(lockPath, "replacement-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      expect(fs.readFileSync(lockPath, "utf8")).toBe("replacement-owner");
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
});

describe("plugin pane path", () => {
  it("gives the Windows pane launcher a drive path", () => {
    expect(windowsDrivePath("\\\\?\\C:\\Code\\symphony-plus-plus")).toBe("C:\\Code\\symphony-plus-plus");
    expect(windowsDrivePath("/code/symphony-plus-plus")).toBe("/code/symphony-plus-plus");
  });
});
