// SSEManager — boot scan, idempotent open/close, graceful stop.
//
// Uses a fake clientFactory so we don't drive real SSE streams; manager
// behavior is independent of what each client does on the wire.

import { describe, expect, test } from "bun:test";
import { hexToBytes } from "@noble/hashes/utils.js";
import { GatewayClient } from "../../src/a4-client";
import type { PluginConfig } from "../../src/config";
import { SSEManager, type ManagedSSEClient } from "../../src/sse/manager";
import { FakeSSEMemory } from "./fakes";

const PLUGIN_PRIV = hexToBytes("11".repeat(32));
const PLUGIN_PUB = "ee".repeat(32);

const CFG: PluginConfig = {
  pluginPriv: PLUGIN_PRIV,
  pluginPub: PLUGIN_PUB,
  gatewayBaseUrl: "https://api.4a4.ai",
  sonataHost: "http://127.0.0.1:3211",
  pluginDataDir: "/tmp/sonata-studio-test",
};

function gatewayStub(): GatewayClient {
  // The factory under test never calls the gateway; the constructor takes
  // it for type compatibility only.
  return new GatewayClient(
    { pluginPriv: PLUGIN_PRIV, gatewayBaseUrl: CFG.gatewayBaseUrl },
    {
      fetcher: async () =>
        new Response(null, { status: 500 }),
      retryDelaysMs: [0, 0, 0, 0],
    },
  );
}

interface FakeClient extends ManagedSSEClient {
  slug: string;
  aborted: boolean;
  resolve: () => void;
}

function makeFakeFactory() {
  const created: FakeClient[] = [];
  const factory = (slug: string): ManagedSSEClient => {
    let resolveRun: () => void;
    const runPromise = new Promise<void>((res) => {
      resolveRun = res;
    });
    const fake: FakeClient = {
      slug,
      aborted: false,
      resolve: () => resolveRun(),
      run: () => runPromise,
      abort: () => {
        fake.aborted = true;
        resolveRun();
      },
    };
    created.push(fake);
    return fake;
  };
  return { factory, created };
}

describe("SSEManager — boot scan", () => {
  test("opens a client per studio_room entity on start", async () => {
    const mem = new FakeSSEMemory();
    mem.upsertRoom("alpha", { aud_id_pub_hex: "11".repeat(32) });
    mem.upsertRoom("beta", { aud_id_pub_hex: "22".repeat(32) });
    mem.upsertRoom("gamma", { aud_id_pub_hex: "33".repeat(32) });

    const { factory, created } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.start();
    expect(mgr.activeRooms()).toEqual(["alpha", "beta", "gamma"]);
    expect(created.map((c) => c.slug).sort()).toEqual(["alpha", "beta", "gamma"]);
    await mgr.stop();
  });

  test("includes pending-grant rooms (any state)", async () => {
    const mem = new FakeSSEMemory();
    mem.upsertRoom("active-room", {
      aud_id_pub_hex: "aa".repeat(32),
      state: "active",
    });
    mem.upsertRoom("pending-room", {
      aud_id_pub_hex: "bb".repeat(32),
      state: "pending-grant",
    });
    const { factory } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.start();
    expect(mgr.activeRooms()).toEqual(["active-room", "pending-room"]);
    await mgr.stop();
  });
});

describe("SSEManager — open / close / stop", () => {
  test("open() is idempotent for the same slug", async () => {
    const mem = new FakeSSEMemory();
    const { factory, created } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.open("solo");
    await mgr.open("solo");
    await mgr.open("solo");
    expect(created).toHaveLength(1);
    expect(mgr.activeRooms()).toEqual(["solo"]);
    await mgr.stop();
  });

  test("close() aborts the client and removes it from active rooms", async () => {
    const mem = new FakeSSEMemory();
    const { factory, created } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.open("doomed");
    expect(mgr.activeRooms()).toEqual(["doomed"]);
    await mgr.close("doomed");
    expect(mgr.activeRooms()).toEqual([]);
    expect(created[0]!.aborted).toBe(true);
  });

  test("stop() aborts every active client and clears state", async () => {
    const mem = new FakeSSEMemory();
    mem.upsertRoom("a", { aud_id_pub_hex: "11".repeat(32) });
    mem.upsertRoom("b", { aud_id_pub_hex: "22".repeat(32) });
    const { factory, created } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.start();
    expect(mgr.activeRooms()).toHaveLength(2);
    await mgr.stop();
    expect(mgr.activeRooms()).toEqual([]);
    expect(created.every((c) => c.aborted)).toBe(true);
  });

  test("close() on an unknown slug is a no-op", async () => {
    const mem = new FakeSSEMemory();
    const { factory } = makeFakeFactory();
    const mgr = new SSEManager(CFG, gatewayStub(), mem.asClient(), {
      clientFactory: factory,
    });
    await mgr.close("never-opened");
    expect(mgr.activeRooms()).toEqual([]);
  });
});
