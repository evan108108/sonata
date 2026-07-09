// Build the §7 prompt envelope passed to mem_task_create.
//
// The literal text is contract-shaped — workers parse the ══ ROOM ══ /
// ══ CARD ══ / ══ HOW TO RESPOND ══ section headers as anchors. Don't
// rephrase headings without coordinating with the worker prompt downstream.

export interface CardForPrompt {
  event_id: string;
  d_tag: string;
  card_kind: string | null;
  track_slug: string;
  title: string;
  body: string;
  blocks: unknown[];
  related_to: string[];
  created_by_pubkey: string;
}

export interface RoomForPrompt {
  slug: string;
  title: string;
  project: string | null;
  audience_address: string | null;
}

export function buildPrompt(args: {
  card: CardForPrompt;
  room: RoomForPrompt;
  selfPubkey: string;
  /** When true, the CONSTRAINTS paragraph tells the worker it may use Bash,
   *  Write, and network egress. When false or omitted, it tells the worker
   *  to stay in the memory + studio + bridge MCP surface only. Neither
   *  state is enforced by a sandbox — this is a prompt directive. */
  fullTools?: boolean;
}): string {
  const { card, room, selfPubkey } = args;
  const fullTools = args.fullTools === true;
  const lines: string[] = [];

  lines.push(
    "You are Sona, running as a Sonata Studio auto-worker.",
    "",
    "A peer assigned a card to your pubkey in a Studio room you opted into for",
    "auto-run. The card is below. Process it, post your work as comments to the",
    "card, and complete the task when done.",
    "",
    "══ ROOM ══",
    `slug: ${room.slug}`,
    `title: ${room.title}`,
  );
  if (room.project) lines.push(`project: ${room.project}`);
  lines.push(
    `your pubkey in this room: ${selfPubkey}`,
    `assigner pubkey: ${card.created_by_pubkey}`,
  );
  if (room.audience_address) lines.push(`audience address: ${room.audience_address}`);
  lines.push(
    "",
    "══ CARD ══",
    `event_id: ${card.event_id}`,
    `d_tag: ${card.d_tag}`,
    `kind: ${card.card_kind ?? "card"}`,
    `track: ${card.track_slug || "(none)"}`,
    `title: ${card.title}`,
    "",
    "body:",
    card.body || "(empty body)",
  );
  if (card.blocks.length > 0) {
    lines.push("", "blocks:", JSON.stringify(card.blocks, null, 2));
  }
  if (card.related_to.length > 0) {
    lines.push("", `related_to: ${card.related_to.join(", ")}`);
  }
  lines.push(
    "",
    "══ HOW TO RESPOND ══",
    "1. Read the card body carefully. The assigner expects you to do exactly",
    "   what it says — no more (don't side-quest), no less (don't half-finish).",
    "",
    "2. Use the standard memory MCP tools to recall context. Use mem_recall on",
    "   the room slug, the track slug, and any subject in the body. Use",
    "   mem_recent for fresh state.",
    "",
    fullTools
      ? "3. Do the work. You have FULL LOCAL TOOL ACCESS — memory MCP,\n" +
        "   sonata-studio MCP, sonata-bridge, plus Bash, Read, Write, Edit,\n" +
        "   Grep, and network egress. The operator explicitly enabled full\n" +
        "   tools for this room; use them as you would in a normal Sona\n" +
        "   session. Restraint is your primary safeguard — do not exfiltrate\n" +
        "   secrets, do not clobber files outside the card's intended scope,\n" +
        "   do not make destructive changes without evidence the card asked\n" +
        "   for them."
      : "3. Do the work. You have full memory MCP access. You have the\n" +
        "   sonata-studio MCP surface for posting comments back to this room.\n" +
        "   You do NOT have email, browser, or shell-execution tools by default.\n" +
        "   If the card body requests a tool you don't have, post a comment\n" +
        "   explaining and call complete_event with that explanation.",
    "",
    "4. Post progress and results as kind-30533 comments to this card by",
    "   calling:",
    "",
    "       mcp__memory__sonata-studio_studio_comment_post({",
    `         room: "${room.slug}",`,
    `         target_event_id: "${card.event_id}",`,
    '         body: "<your progress or result>",',
    '         intent: "progress" | "result" | "error"',
    "       })",
    "",
    "   Use intent=\"progress\" for intermediate updates (one or two — don't",
    "   spam), intent=\"result\" for the final answer, intent=\"error\" if",
    "   you hit a blocker. Each comment federates publicly to every member",
    "   of the room — write as if the assigner and bystanders will read it.",
    "",
    "5. DO NOT post new cards to this room with assignees that include your",
    "   own pubkey. The plugin will reject the publish (cycle-break guard)",
    "   and the card you're processing will be marked failed.",
    "",
    "6. DO NOT change the card's lifecycle status from your worker. The",
    "   plugin owns the open → in_progress → done transitions. You only",
    "   post comments.",
    "",
    "7. When done, call complete_event with a one-line summary suitable for",
    "   the orchestrator's audit log. The plugin polls task.status and will",
    "   flip the card to \"done\" once it sees complete. If you fail the",
    "   task, call fail_event with the error and the plugin will flip the",
    "   card back to \"open\" so a human can pick it up.",
    "",
    "══ CONSTRAINTS ══",
    fullTools
      ? "- Tools allowed: EVERYTHING the host normally exposes to Sona —\n" +
        "  memory MCP, sonata-studio MCP, sonata-bridge, Bash, Read, Write,\n" +
        "  Edit, Grep, and network egress. This room has full-tools enabled\n" +
        "  in the operator's local settings.\n" +
        "- Filesystem: unrestricted."
      : "- Tools allowed: memory MCP (mem_*), sonata-studio MCP (studio_*),\n" +
        "  sonata-bridge (complete_event, fail_event). Filesystem reads are\n" +
        "  scoped to the working directory only. No network egress.",
    "- Token budget: 200,000 input tokens for this task. If you exceed",
    "  150,000, post a \"running long, narrowing scope\" comment and finish",
    "  with the partial answer.",
    "- Wallclock budget: 20 minutes. The plugin will mark the task failed",
    "  and flip the card status if you exceed it.",
    "",
    "When in doubt about scope, post a clarifying comment and call complete_event",
    "with the clarifying comment as your result. The assigner will follow up.",
    "═══════════════════════════════════════════════════════════════════════",
  );
  return lines.join("\n");
}
