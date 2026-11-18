#!/usr/bin/env node
/**
 * unowned-branch-check — finds fixes left on a branch with nobody to land them.
 *
 * QUESTION IT ANSWERS: is there a pushed branch, unmerged into main and older
 * than a day, that no pending/active mem_task and no upcoming calendar
 * trigger points at?
 *
 * WHY IT EXISTS: closing a task is the last moment anything points at its
 * branch. On 11/09 task f79a8edb closed "completed" with the peer-DM echo
 * fixes on local branches, and nothing owned the landing until a daily
 * learnings run noticed on 11/10. On 11/17 the HealthMonitor watchdog
 * (3da3f20) was pushed but unmerged, again ownerless until daily learnings
 * filed a5fbbcc2 (memory e64c0ba0). The worker CLAUDE.md rule "A fix left on
 * a branch is not a closed task" said what to do. This makes it mechanical.
 *
 * WHAT COUNTS AS UNOWNED, per remote branch on origin:
 *   1. its tip is not an ancestor of the base (origin/HEAD, else origin/main),
 *   2. AND `git cherry` finds at least one commit with no patch-equivalent in
 *      the base (so a rebased or cherry-picked landing counts as merged),
 *   3. AND its tip commit is older than STALE_AFTER_HOURS (a fresh push is
 *      still in someone's hands),
 *   4. AND no pending/active task and no upcoming enabled calendar event has
 *      the tip's short sha or the branch name in its title, description or
 *      prompt,
 *   5. AND it was not dismissed for that exact tip sha (--dismiss).
 * A squash-merge of a multi-commit branch has no patch-equivalent commit, so
 * it still reports. Delete the remote branch or dismiss it.
 *
 * OUTPUT: one tab-separated line per unowned branch
 *   repo  branch  sha7  age  subject  owner: <suggested owner>
 * then a summary line that starts with "<N> unowned". With none, the summary
 * is "0 unowned ...". The counts in it (stale unmerged, owned, dismissed)
 * show that a 0 came from a scan that saw branches, not from an empty read.
 *
 * EXIT: 0 when the scan completed, whatever the count. 2 when a repo could
 * not be fetched or read, or the task/calendar API failed. A 0 from an owner
 * lookup that never ran would look like "everything is owned", so any API
 * failure aborts before reporting. lastExitCode on the scheduler job means
 * "the watcher is broken", never "there are unowned branches".
 *
 * USAGE
 *   node unowned-branch-check.mjs                  report only
 *   node unowned-branch-check.mjs --email          also email Evan when N > 0
 *   node unowned-branch-check.mjs --dismiss <repo-path> <branch> --why '...'
 *        silence one branch AT ITS CURRENT TIP. A new push re-arms it.
 *
 * ENV (tests only)
 *   UNOWNED_BRANCH_REPOS      colon-separated repo paths, replaces REPOS
 *   UNOWNED_BRANCH_DISMISSED  dismiss-file path
 *   SONATA_API                default http://localhost:3211
 *
 * SCHEDULER: job unowned-branch-check-daily runs this with --email and NO
 * `| tail -c`. Subjects carry multibyte characters (— ⊥), and a byte-count
 * tail can start mid-character; Sonata then decodes the whole output as
 * invalid UTF-8 and stores lastResult = "" with exit 0 (seen 11/18, while the
 * email still went out). Output is one line per branch, so it is bounded.
 *
 * Owner lookup goes through Sonata's HTTP API (the same routes the `mem` CLI
 * and the mem_task_list / calendar_upcoming MCP tools use), never sqlite3.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

// --- constants ---------------------------------------------------------
const REPOS = [
  "/Users/evan/memory/Sonata",
  "/Users/evan/enginable/prstar",
  "/Users/evan/sonar",
];
const STALE_AFTER_HOURS = 24;
const SHORT_SHA_LEN = 7;
// Past this age the branch is more likely abandoned than waiting to land, so
// the suggestion is a keep/delete decision instead of a landing task.
const DECIDE_ABANDON_AFTER_DAYS = 30;
const DEFAULT_BASE = "origin/main";
const OWNER_STATUSES = ["pending", "active"];
const TASK_PAGE = 500;
const CALENDAR_LIMIT = 1000;
const HTTP_TIMEOUT_MS = 30_000;
const GIT_TIMEOUT_MS = 120_000;
const ALERT_TO = "evan108108@gmail.com";
const MS_PER_HOUR = 3_600_000;

// Who should land a branch, by repo directory name.
const LANDING_OWNER = {
  Sonata: "Sonata worker via pending mem_task (project sonata): merge to main, then /deploy-local",
  prstar: "prStar worker via pending mem_task (project prstar): merge, then deploy-plugin-local.sh prstar",
  sonar: "Sonar worker via pending mem_task (project sonar): merge, then reinstall the sonar plugin",
};
const ABANDON_OWNER = `Evan: keep or delete (older than ${DECIDE_ABANDON_AFTER_DAYS}d, likely abandoned)`;

const API = process.env.SONATA_API || "http://localhost:3211";
const DISMISS_PATH =
  process.env.UNOWNED_BRANCH_DISMISSED || join(homedir(), ".sonata", "unowned-branch-dismissed.json");
const repos = process.env.UNOWNED_BRANCH_REPOS
  ? process.env.UNOWNED_BRANCH_REPOS.split(":").filter(Boolean)
  : REPOS;

// --- helpers -----------------------------------------------------------
const git = (repo, args) =>
  execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    stdio: ["ignore", "pipe", "pipe"],
  });

function isAncestor(repo, sha, base) {
  try {
    git(repo, ["merge-base", "--is-ancestor", sha, base]);
    return true;
  } catch (e) {
    if (e.status === 1) return false;
    throw e;
  }
}

async function getJSON(path) {
  const res = await fetch(`${API}${path}`, { signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`GET ${path} → HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = await res.json();
  if (!Array.isArray(body)) throw new Error(`GET ${path} → expected an array, got ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

// Every pending/active task, paged until a short page (a full page is a
// sample, not the set), plus every upcoming enabled calendar event.
async function loadOwners() {
  const owners = [];
  for (const status of OWNER_STATUSES) {
    for (let offset = 0; ; offset += TASK_PAGE) {
      const page = await getJSON(`/api/task/list?status=${status}&limit=${TASK_PAGE}&offset=${offset}`);
      for (const t of page) owners.push({ kind: `task:${status}`, id: t._id, title: t.title, text: haystack(t) });
      if (page.length < TASK_PAGE) break;
    }
  }
  const events = await getJSON(`/api/calendar/upcoming?limit=${CALENDAR_LIMIT}`);
  if (events.length >= CALENDAR_LIMIT) {
    throw new Error(`calendar/upcoming returned ${events.length} rows (= limit ${CALENDAR_LIMIT}); can't prove absence`);
  }
  for (const c of events) owners.push({ kind: "calendar", id: c._id, title: c.title, text: haystack(c) });
  return owners;
}

const haystack = (row) => [row.title, row.description, row.prompt].filter(Boolean).join("\n");

function findOwner(owners, sha7, branch) {
  const shaLower = sha7.toLowerCase();
  return owners.find((o) => o.text.toLowerCase().includes(shaLower) || o.text.includes(branch));
}

function formatAge(ms) {
  const h = Math.floor(ms / MS_PER_HOUR);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

const dismissKey = (repo, branch, sha7) => `${resolve(repo)}|${branch}|${sha7}`;

function loadDismissed() {
  if (!existsSync(DISMISS_PATH)) return {};
  return JSON.parse(readFileSync(DISMISS_PATH, "utf8"));
}

function suggestOwner(repo, ageMs) {
  if (ageMs > DECIDE_ABANDON_AFTER_DAYS * 24 * MS_PER_HOUR) return ABANDON_OWNER;
  return LANDING_OWNER[basename(repo)] || "a worker via pending mem_task for this repo: merge and deploy";
}

// --- scan --------------------------------------------------------------
function scanRepo(repo, now) {
  git(repo, ["fetch", "--prune", "--quiet", "origin"]);
  let base = DEFAULT_BASE;
  try {
    base = git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).trim() || DEFAULT_BASE;
  } catch {
    /* no origin/HEAD: keep origin/main */
  }
  git(repo, ["rev-parse", "--verify", "--quiet", base]); // throws if the base is missing
  const refs = git(repo, [
    "for-each-ref",
    "refs/remotes/origin",
    "--format=%(refname:short)%09%(objectname)%09%(committerdate:unix)%09%(subject)",
  ])
    .split("\n")
    .filter(Boolean);

  const found = [];
  for (const line of refs) {
    const [ref, sha, ts, ...subj] = line.split("\t");
    if (ref === base || ref === "origin/HEAD" || ref === "origin") continue;
    if (isAncestor(repo, sha, base)) continue;
    const unlanded = git(repo, ["cherry", base, sha])
      .split("\n")
      .filter((l) => l.startsWith("+")).length;
    if (unlanded === 0) continue; // every commit has a patch-equivalent in base
    const ageMs = now - Number(ts) * 1000;
    if (ageMs < STALE_AFTER_HOURS * MS_PER_HOUR) continue;
    found.push({
      repo,
      branch: ref.replace(/^origin\//, ""),
      sha7: sha.slice(0, SHORT_SHA_LEN),
      ageMs,
      subject: subj.join("\t"),
      unlanded,
    });
  }
  return found;
}

async function sendEmail(subject, text) {
  const res = await fetch(`${API}/api/email/send`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ to: ALERT_TO, subject, text }),
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`email send → HTTP ${res.status}: ${body.slice(0, 300)}`);
  return body;
}

async function main() {
  const args = process.argv.slice(2);

  const di = args.indexOf("--dismiss");
  if (di !== -1) {
    const [repo, branch] = [args[di + 1], args[di + 2]];
    const wi = args.indexOf("--why");
    const why = wi !== -1 ? args[wi + 1] : null;
    if (!repo || !branch || !why) {
      console.error("usage: --dismiss <repo-path> <branch> --why '...'");
      process.exit(2);
    }
    const sha7 = git(repo, ["rev-parse", `refs/remotes/origin/${branch}`]).trim().slice(0, SHORT_SHA_LEN);
    const dismissed = loadDismissed();
    dismissed[dismissKey(repo, branch, sha7)] = { why, at: new Date().toISOString() };
    writeFileSync(DISMISS_PATH, JSON.stringify(dismissed, null, 2) + "\n");
    console.log(`dismissed ${basename(repo)} ${branch} at ${sha7}: ${why}`);
    return;
  }

  const now = Date.now();
  const errors = [];
  const stale = [];
  let scanned = 0;
  for (const repo of repos) {
    if (!existsSync(join(repo, ".git"))) {
      console.log(`skip: ${repo} has no local checkout`);
      continue;
    }
    try {
      stale.push(...scanRepo(repo, now));
      scanned++;
    } catch (e) {
      errors.push(`${repo}: ${(e.stderr || e.message || String(e)).toString().trim().slice(0, 300)}`);
    }
  }

  let owners;
  try {
    owners = await loadOwners();
  } catch (e) {
    console.log(`ERROR owner lookup failed, refusing to report: ${e.message}`);
    process.exit(2);
  }

  const dismissed = loadDismissed();
  const unowned = [];
  let ownedCount = 0;
  let dismissedCount = 0;
  for (const b of stale) {
    if (dismissed[dismissKey(b.repo, b.branch, b.sha7)]) {
      dismissedCount++;
      continue;
    }
    const owner = findOwner(owners, b.sha7, b.branch);
    if (owner) {
      ownedCount++;
      continue;
    }
    unowned.push({ ...b, suggested: suggestOwner(b.repo, b.ageMs) });
  }

  const lines = unowned.map((b) =>
    [basename(b.repo), b.branch, b.sha7, formatAge(b.ageMs), b.subject, `owner: ${b.suggested}`].join("\t"),
  );
  for (const l of lines) console.log(l);
  const summary =
    `${unowned.length} unowned (${stale.length} stale unmerged across ${scanned} repo(s); ` +
    `${ownedCount} owned, ${dismissedCount} dismissed; checked ${owners.length} task/calendar owners)`;
  console.log(summary);
  for (const e of errors) console.log(`ERROR ${e}`);

  if (args.includes("--email") && unowned.length > 0) {
    const text = [
      `${unowned.length} pushed branch(es) are unmerged, older than ${STALE_AFTER_HOURS}h, and no pending/active task or upcoming calendar trigger names their sha or branch:`,
      "",
      ...unowned.map(
        (b) =>
          `• ${basename(b.repo)} ${b.branch} ${b.sha7} (${formatAge(b.ageMs)}) "${b.subject}"\n  suggested owner: ${b.suggested}`,
      ),
      "",
      "To clear one, do any of:",
      "  - file a pending mem_task whose prompt names the sha (it lands it), or",
      "  - delete the remote branch (git push origin --delete <branch>), or",
      `  - node ${process.argv[1]} --dismiss <repo-path> <branch> --why '...' (re-arms on a new push).`,
      ...(errors.length ? ["", "Also, the scan hit errors:", ...errors.map((e) => `  ${e}`)] : []),
      "",
      "— Sona (unowned-branch-check, daily)",
    ].join("\n");
    await sendEmail(`Unowned branches: ${unowned.length}`, text);
    console.log(`emailed ${ALERT_TO}`);
  }

  if (errors.length) process.exit(2);
}

main().catch((e) => {
  console.log(`ERROR ${e.stack || e}`);
  process.exit(2);
});
