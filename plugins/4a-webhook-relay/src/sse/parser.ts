// Wrap eventsource-parser as an async iterator over a fetch response body.
//
// Each yielded event has its `data` field already JSON-parsed (the gateway
// emits one JSON object per `data:` line per §2.4). Comments and parse
// errors are silently dropped — the client treats the stream as best-effort
// and reconnects on close.

import { createParser, type EventSourceMessage } from "eventsource-parser";

export interface ParsedSSEEvent {
  event: string;
  data: unknown;
  id?: string;
}

export async function* parseSSEStream(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<ParsedSSEEvent, void, void> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const queue: ParsedSSEEvent[] = [];

  const parser = createParser({
    onEvent: (msg: EventSourceMessage): void => {
      const eventName = msg.event ?? "message";
      let data: unknown = null;
      if (msg.data && msg.data.length > 0) {
        try {
          data = JSON.parse(msg.data);
        } catch {
          data = msg.data;
        }
      }
      queue.push({ event: eventName, data, id: msg.id });
    },
  });

  try {
    while (true) {
      while (queue.length > 0) {
        yield queue.shift()!;
      }
      const { value, done } = await reader.read();
      if (done) break;
      parser.feed(decoder.decode(value, { stream: true }));
    }
    while (queue.length > 0) {
      yield queue.shift()!;
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // already released
    }
  }
}
