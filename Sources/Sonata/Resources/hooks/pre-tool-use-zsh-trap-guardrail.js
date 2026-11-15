#!/usr/bin/env node
/**
 * PreToolUse Hook: zsh-trap guardrail for the Bash tool (2026-11-15, task e57af007)
 *
 * Worker shells are zsh. Two zsh behaviours have handed workers a wrong
 * answer or an abort that a bash habit doesn't expect (worker CLAUDE.md,
 * "Your shell is zsh, not bash"):
 *
 *   (a) UNBRACED PARAMETER BEFORE A COLON. After an unbraced `$VAR:`, zsh
 *       reads the next letter as a history modifier. `"$SHA:tests/a"` takes
 *       `:t` (tail) and becomes `abc123ests/a`, at exit 0. `$REF:scout/x`
 *       takes `:s` and aborts with "bad substitution". Fix: `"${SHA}:tests/a"`.
 *   (b) A WORD STARTING WITH `=` PASSED TO echo/printf, unquoted. zsh's
 *       EQUALS option expands `=word` to the path of command `word`, so
 *       `echo ====` aborts with "=== not found". Fix: quote it (`echo '===='`).
 *
 * The hook BLOCKS and names the trap and the fix. It never rewrites the command.
 *
 * WHAT IS SCANNED. A small quote scanner runs first:
 *   - single-quoted text, backslash-escaped characters and the bodies of
 *     QUOTED heredocs (<<'EOF', <<"EOF") are blanked for (a), because no
 *     parameter expansion happens there;
 *   - for (b), every quoted character and every heredoc body is blanked,
 *     so `echo "a =b"` and `cat <<EOF` data never match.
 *   `${…}` forms never match (a) because the regex needs a letter right after `$`.
 *
 * SCOPE. Workers only (SONA_WORKER=1), and only when $SHELL is zsh. Interactive
 * sessions pass silently, as the spec for task e57af007 asked.
 *
 * ESCAPE HATCHES
 *   CLAUDE_ALLOW_ZSH_TRAP=1        per-session bypass (logged to stderr)
 *   `# zsh-trap-ok: <reason>`      per-call override anywhere in the command,
 *                                  e.g. for a deliberate `$f:t` modifier.
 *
 * Fails open on any internal error, like the other guardrails: a hook that
 * wedges every Bash call is worse than the trap it guards.
 */

"use strict";

const OVERRIDE_RE = /#\s*zsh-trap-ok:\s*(.+)$/m;
const UNBRACED_COLON_RE = /\$[A-Za-z_][A-Za-z0-9_]*:[A-Za-z]/;
const ECHO_EQUALS_RE = /(?:^|[\s;&|(`])(?:echo|printf)(?:[ \t]+[^\s;&|)`]+)*?[ \t]+(=[^\s;&|)`]+)/;
const HEREDOC_RE = /<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g;

/**
 * Returns { expand, bare }, each the same length as `cmd`:
 *   expand: text where parameter expansion can happen (single quotes, escapes
 *           and quoted-heredoc bodies blanked to spaces)
 *   bare:   unquoted shell text only (all quoted text -> 'Q', all heredoc
 *           bodies -> spaces)
 */
function scan(cmd) {
  const lines = cmd.split("\n");
  let expand = "";
  let bare = "";
  let state = "none"; // none | single | double
  const pending = []; // heredocs opened on the current line: { delim, quoted, dash }

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];

    // Heredoc bodies opened on an earlier line.
    if (pending.length && state === "none") {
      const hd = pending[0];
      const probe = hd.dash ? line.replace(/^\t+/, "") : line;
      const blank = " ".repeat(line.length);
      if (probe === hd.delim) {
        pending.shift();
        expand += blank;
        bare += blank;
      } else {
        expand += hd.quoted ? blank : line;
        bare += blank;
      }
      if (li < lines.length - 1) { expand += "\n"; bare += "\n"; }
      continue;
    }

    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (state === "single") {
        if (c === "'") state = "none";
        expand += " ";
        bare += "Q";
      } else if (state === "double") {
        if (c === "\\" && i + 1 < line.length) {
          expand += "  ";
          bare += "QQ";
          i++;
        } else if (c === '"') {
          state = "none";
          expand += c;
          bare += "Q";
        } else {
          expand += c;
          bare += "Q";
        }
      } else {
        if (c === "\\" && i + 1 < line.length) {
          expand += "  ";
          bare += "  ";
          i++;
        } else if (c === "'") {
          state = "single";
          expand += " ";
          bare += "Q";
        } else if (c === '"') {
          state = "double";
          expand += c;
          bare += "Q";
        } else {
          expand += c;
          bare += c;
        }
      }
    }

    // Heredoc operators on this line (only meaningful outside quotes).
    if (state === "none") {
      HEREDOC_RE.lastIndex = 0;
      let m;
      while ((m = HEREDOC_RE.exec(line)) !== null) {
        pending.push({ dash: m[1] === "-", quoted: m[2] !== "", delim: m[3] });
      }
    }
    if (li < lines.length - 1) {
      expand += state === "single" ? " " : "\n";
      bare += state === "none" ? "\n" : "Q";
    }
  }
  return { expand, bare };
}

/** Returns a list of { trap, match } findings for a command string. */
function detect(cmd) {
  if (typeof cmd !== "string" || !cmd) return [];
  const { expand, bare } = scan(cmd);
  const findings = [];
  const a = expand.match(UNBRACED_COLON_RE);
  if (a) findings.push({ trap: "unbraced-colon", match: a[0] });
  const b = bare.match(ECHO_EQUALS_RE);
  if (b) findings.push({ trap: "echo-equals", match: b[1] });
  return findings;
}

function reasonFor(findings) {
  const out = ["Bash blocked: zsh trap in this command (worker shells are zsh, not bash)."];
  for (const f of findings) {
    if (f.trap === "unbraced-colon") {
      const name = f.match.slice(1, f.match.indexOf(":"));
      const letter = f.match.slice(-1);
      out.push(
        "",
        `• \`${f.match}…\`: after an unbraced \`$${name}:\`, zsh reads \`:${letter}\` as a`,
        "  history modifier. `:t`/`:h`/`:r`/`:e`/`:l`/`:u` silently mangle the value at",
        "  exit 0; `:s` aborts with \"bad substitution\".",
        `  Fix: brace the name: \`"\${${name}}:…"\`.`,
      );
    } else {
      out.push(
        "",
        `• \`${f.match}\` passed to echo/printf unquoted: zsh expands a word starting with`,
        "  `=` to a command path (`echo ====` aborts with \"=== not found\").",
        `  Fix: quote it: \`'${f.match}'\`.`,
      );
    }
  }
  out.push(
    "",
    "Re-run the corrected command. If the zsh behaviour is what you want (e.g. a",
    "deliberate `$f:t`), append `# zsh-trap-ok: <reason>` to the command.",
  );
  return out.join("\n");
}

function pass() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(
    JSON.stringify({
      decision: "block",
      reason,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
}

function main(raw) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return pass();
  }
  if (payload.tool_name !== "Bash") return pass();
  if (process.env.SONA_WORKER !== "1") return pass();
  if (!/zsh$/.test(process.env.SHELL || "")) return pass();

  const cmd = payload.tool_input && payload.tool_input.command;
  if (typeof cmd !== "string") return pass();

  if (process.env.CLAUDE_ALLOW_ZSH_TRAP === "1") {
    process.stderr.write("[zsh-trap-guardrail] CLAUDE_ALLOW_ZSH_TRAP=1, allowing Bash.\n");
    return pass();
  }
  const override = cmd.match(OVERRIDE_RE);
  if (override) {
    process.stderr.write(`[zsh-trap-guardrail] OVERRIDE, reason: ${override[1].trim()}\n`);
    return pass();
  }

  const findings = detect(cmd);
  if (!findings.length) return pass();
  return block(reasonFor(findings));
}

module.exports = { detect, scan };

if (require.main === module) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (raw += c));
  process.stdin.on("end", () => {
    try {
      main(raw);
    } catch (err) {
      process.stderr.write(
        `[zsh-trap-guardrail] internal error, passing tool call through: ${
          err && err.message ? err.message : String(err)
        }\n`,
      );
      process.exit(0);
    }
  });
}
