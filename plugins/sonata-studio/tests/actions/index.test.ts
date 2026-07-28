// Manifest ↔ code sync guard, referenced by the header comment in
// src/actions/index.ts: sonata-studio.plugin.json's `actions` array and the
// exported ACTIONS list must agree field-by-field (name/method/path + every
// param's name/type/required/description), and every action must be routable.
//
// First run of this test caught real drift: the four room-lifecycle actions
// (leave/close/reopen/boot) were in ACTIONS but missing from the manifest.

import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { ACTIONS, ROUTES, type ActionDef, type ActionParam } from "../../src/actions";

const manifest = JSON.parse(
  readFileSync(join(import.meta.dir, "../../sonata-studio.plugin.json"), "utf8"),
) as { actions: ActionDef[] };

const normalizeParam = (p: ActionParam) => ({
  name: p.name,
  type: p.type,
  required: p.required ?? false,
  description: p.description ?? "",
});

const byName = (defs: ActionDef[]) => new Map(defs.map((d) => [d.name, d]));

describe("plugin.json actions ↔ ACTIONS sync", () => {
  const manifestActions = byName(manifest.actions);
  const codeActions = byName(ACTIONS);

  it("has no duplicate action names on either side", () => {
    expect(manifestActions.size).toBe(manifest.actions.length);
    expect(codeActions.size).toBe(ACTIONS.length);
  });

  it("declares every ACTIONS entry in the manifest", () => {
    const missing = ACTIONS.filter((a) => !manifestActions.has(a.name)).map((a) => a.name);
    expect(missing).toEqual([]);
  });

  it("has an ACTIONS entry for every manifest action", () => {
    const missing = manifest.actions.filter((a) => !codeActions.has(a.name)).map((a) => a.name);
    expect(missing).toEqual([]);
  });

  it("matches method, path, description, and params field-by-field", () => {
    for (const action of ACTIONS) {
      const decl = manifestActions.get(action.name);
      if (!decl) continue; // reported by the presence test above
      expect({ name: action.name, method: decl.method, path: decl.path, description: decl.description })
        .toEqual({ name: action.name, method: action.method, path: action.path, description: action.description });
      expect({ name: action.name, params: decl.params.map(normalizeParam) })
        .toEqual({ name: action.name, params: action.params.map(normalizeParam) });
    }
  });
});

describe("ACTIONS ↔ ROUTES sync", () => {
  it("routes every action's path with the declared method and a handler", () => {
    for (const action of ACTIONS) {
      const route = ROUTES[action.path];
      expect({ path: action.path, route: route?.method }).toEqual({ path: action.path, route: action.method });
      expect(typeof route?.handler).toBe("function");
    }
  });

  it("has no orphan routes absent from ACTIONS", () => {
    const actionPaths = new Set(ACTIONS.map((a) => a.path));
    const orphans = Object.keys(ROUTES).filter((path) => !actionPaths.has(path));
    expect(orphans).toEqual([]);
  });
});
