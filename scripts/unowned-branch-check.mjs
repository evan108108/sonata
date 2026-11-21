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
 *
 * SECOND LEG: STALLED PRs. A PR that is approved, green and ready can still
 * sit unmerged because nobody holds the merge. lead-discovery #40 sat 48h on
 * 11/18–20 while Scout and Sona each left it to the other (reflection
 * 10a94c60). The branch leg can't see that, because an open PR's branch is
 * "someone's" by definition. This leg lists the open PRs in every GitHub
 * remote of REPOS plus PR_EXTRA_SLUGS and flags one when ALL of these hold:
 *   1. not a draft,
 *   2. APPROVED: reviewDecision === "APPROVED", or the LAST "## Sona Review —
 *      <verdict>" review (prStar posts these as COMMENTED on self-authored
 *      PRs, so reviewDecision stays "") has verdict approve/approve_with_notes
 *      AND was posted on the current head (a push after approval re-opens it),
 *   3. GREEN: at least one check registered, every CheckRun COMPLETED with
 *      SUCCESS, SKIPPED or NEUTRAL, every StatusContext SUCCESS, and at least
 *      one SUCCESS. No checks registered is NOT green: CI may simply not have
 *      registered yet (learning e14c3b8e, `gh pr checks` on an unregistered PR).
 *      SKIPPED passes because adaptengine's CI always skips some jobs (#867:
 *      16 SUCCESS + 3 SKIPPED), so "every check SUCCESS" would never fire there.
 *   4. updatedAt older than PR_STALE_AFTER_HOURS.
 * Likely merger: every agent PR is authored by the shared evan108108 login,
 * so the login can't name the agent. The head branch can: scout… → Scout,
 * sona/… → Sona. Otherwise a bot author is named, and anything else is Evan.
 * KNOWN BLIND SPOT: #40 itself had no GitHub review (it was approved by email)
 * and lead-discovery has no CI, so this leg would not have flagged it. An
 * approval only counts here if it is posted on the PR.
 *
 * SELF-TEST: every run first evaluates the recorded fixtures in
 * fixtures/stalled-pr-fixtures.json (#867 aged 30h must flag; at 24h−1m must
 * not; no-checks, a failed check, a draft, an approve on an older head must
 * not). If any case fails, the PR leg is skipped and the run exits 2, so a
 * "0 stalled PR(s)" line always comes from a filter that just matched a known
 * PR. `--pr-self-test` runs only that.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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

// --- stalled-PR leg constants ------------------------------------------
// Repos without a local checkout in REPOS, scanned by GitHub slug.
const PR_EXTRA_SLUGS = ["enginable/lead-discovery", "enginable/adaptengine-monorepo"];
const PR_STALE_AFTER_HOURS = 24;
// gh pr list returns at most this many; a full page is a sample, so it errors.
const PR_LIST_LIMIT = 100;
const PR_FIELDS =
  "number,title,author,reviewDecision,statusCheckRollup,isDraft,updatedAt,url,headRefName,headRefOid,reviews";
const GH = existsSync("/opt/homebrew/bin/gh") ? "/opt/homebrew/bin/gh" : "gh";
const GH_TIMEOUT_MS = 60_000;
const PASSING_CONCLUSIONS = new Set(["SUCCESS", "SKIPPED", "NEUTRAL"]);
const PRSTAR_APPROVE_VERDICTS = new Set(["approve", "approve_with_notes"]);
const PRSTAR_VERDICT_RE = /^##\s*Sona Review\s*[—–-]\s*([a-z_]+)/;
const GITHUB_REMOTE_RE = /github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/;
// Head-branch prefix → the agent who holds the merge (all agent PRs share one login).
const AGENT_BRANCH = [
  [/^scout[/-]/, "Scout"],
  [/^sona\//, "Sona (a worker via pending mem_task)"],
];
const FIXTURES_PATH = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "stalled-pr-fixtures.json");

const API = process.env.SONATA_API || "http://localhost:3211";
const DISMISS_PATH =
  process.env.UNOWNED_BRANCH_DISMISSED || join(homedir(), ".sonata", "unowned-branch-dismissed.json");
const repos = process.env.UNOWNED_BRANCH_REPOS
  ? process.env.UNOWNED_BRANCH_REPOS.split(":").filter(Boolean)
  : REPOS;
// Tests set UNOWNED_BRANCH_PR_SLUGS (colon-separated; "" = scan no PRs) so a
// control run never queries real GitHub.
const prSlugOverride =
  process.env.UNOWNED_BRANCH_PR_SLUGS === undefined
    ? null
    : process.env.UNOWNED_BRANCH_PR_SLUGS.split(":").filter(Boolean);

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

// --- stalled-PR leg ----------------------------------------------------
function ghSlug(repo) {
  try {
    const url = git(repo, ["remote", "get-url", "origin"]).trim();
    return url.match(GITHUB_REMOTE_RE)?.[1] ?? null;
  } catch {
    return null;
  }
}

function prSlugs() {
  if (prSlugOverride) return prSlugOverride;
  const slugs = repos.filter((r) => existsSync(join(r, ".git"))).map(ghSlug).filter(Boolean);
  return [...new Set([...slugs, ...PR_EXTRA_SLUGS])];
}

function listOpenPRs(slug) {
  const out = execFileSync(
    GH,
    ["pr", "list", "-R", slug, "--state", "open", "--limit", String(PR_LIST_LIMIT), "--json", PR_FIELDS],
    { encoding: "utf8", timeout: GH_TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"] },
  );
  const prs = JSON.parse(out);
  if (!Array.isArray(prs)) throw new Error(`gh pr list ${slug}: expected an array`);
  if (prs.length >= PR_LIST_LIMIT) {
    throw new Error(`gh pr list ${slug} returned ${prs.length} (= limit ${PR_LIST_LIMIT}); can't prove absence`);
  }
  return prs;
}

function isGreen(rollup) {
  if (!Array.isArray(rollup) || rollup.length === 0) return { green: false, why: "no checks registered" };
  let successes = 0;
  for (const c of rollup) {
    if (c.__typename === "StatusContext") {
      if (c.state !== "SUCCESS") return { green: false, why: `status ${c.context ?? "?"} is ${c.state}` };
      successes++;
      continue;
    }
    if (c.status !== "COMPLETED") return { green: false, why: `check ${c.name ?? "?"} is ${c.status}` };
    if (!PASSING_CONCLUSIONS.has(c.conclusion)) return { green: false, why: `check ${c.name ?? "?"} is ${c.conclusion}` };
    if (c.conclusion === "SUCCESS") successes++;
  }
  if (successes === 0) return { green: false, why: "no check succeeded (all skipped/neutral)" };
  return { green: true, why: `${successes}/${rollup.length} SUCCESS` };
}

function approval(pr) {
  if (pr.reviewDecision === "APPROVED") return { approved: true, via: "reviewDecision APPROVED" };
  const verdicts = (pr.reviews || [])
    .map((r) => ({ verdict: (r.body || "").match(PRSTAR_VERDICT_RE)?.[1], oid: r.commit?.oid, at: r.submittedAt }))
    .filter((r) => r.verdict);
  const last = verdicts[verdicts.length - 1];
  if (!last) return { approved: false, why: "no approval (reviewDecision empty, no prStar verdict)" };
  if (!PRSTAR_APPROVE_VERDICTS.has(last.verdict)) return { approved: false, why: `last prStar verdict is ${last.verdict}` };
  if (last.oid && pr.headRefOid && last.oid !== pr.headRefOid) {
    return { approved: false, why: `prStar ${last.verdict} was on ${last.oid.slice(0, 8)}, head is ${pr.headRefOid.slice(0, 8)}` };
  }
  return { approved: true, via: `prStar ${last.verdict}` };
}

function mergerFor(pr) {
  for (const [re, who] of AGENT_BRANCH) if (re.test(pr.headRefName || "")) return who;
  if (pr.author?.is_bot) return pr.author.login;
  return "Evan";
}

// → { stalled, stage, why, ageMs, merger }. stage names the first gate that
// failed (draft | approval | checks | fresh), or "stalled". Pure: depends only
// on the record and now.
function evaluatePR(pr, now) {
  const ageMs = now - Date.parse(pr.updatedAt);
  const base = { ageMs, merger: mergerFor(pr), stalled: false };
  if (pr.isDraft) return { ...base, stage: "draft", why: "draft" };
  const a = approval(pr);
  if (!a.approved) return { ...base, stage: "approval", why: a.why };
  const g = isGreen(pr.statusCheckRollup);
  if (!g.green) return { ...base, stage: "checks", why: g.why };
  if (!(ageMs > PR_STALE_AFTER_HOURS * MS_PER_HOUR)) return { ...base, stage: "fresh", why: `updated ${formatAge(ageMs)} ago` };
  return { ...base, stalled: true, stage: "stalled", why: `${a.via}; ${g.why}` };
}

// Runs the recorded fixtures through evaluatePR. Returns failure strings.
function prSelfTest() {
  const fx = JSON.parse(readFileSync(FIXTURES_PATH, "utf8"));
  const failures = [];
  let matched = 0;
  for (const c of fx.cases) {
    const pr = { ...fx.base, ...c.override };
    const r = evaluatePR(pr, Date.parse(pr.updatedAt) + c.ageMs);
    if (r.stalled !== c.expectStalled) failures.push(`${c.name}: expected stalled=${c.expectStalled}, got ${r.stalled} (${r.why})`);
    if (c.expectMerger && r.merger !== c.expectMerger) failures.push(`${c.name}: expected merger ${c.expectMerger}, got ${r.merger}`);
    if (r.stalled) matched++;
  }
  // The filter must have flagged something, or an all-false fixture set would pass vacuously.
  if (matched === 0) failures.push("no fixture case was flagged as stalled");
  return { failures, cases: fx.cases.length, matched };
}

function scanPRs(now, errors) {
  const st = prSelfTest();
  if (st.failures.length) {
    for (const f of st.failures) errors.push(`pr-filter self-test: ${f}`);
    return { ran: false, selfTest: st, stalled: [], open: 0, slugs: 0, notReady: {} };
  }
  const stalled = [];
  const notReady = {};
  let open = 0;
  let slugs = 0;
  for (const slug of prSlugs()) {
    let prs;
    try {
      prs = listOpenPRs(slug);
    } catch (e) {
      errors.push(`${slug} PRs: ${(e.stderr || e.message || String(e)).toString().trim().slice(0, 300)}`);
      continue;
    }
    slugs++;
    open += prs.length;
    for (const pr of prs) {
      const r = evaluatePR(pr, now);
      if (r.stalled) stalled.push({ slug, pr, ...r });
      else notReady[r.stage] = (notReady[r.stage] || 0) + 1;
    }
  }
  return { ran: true, selfTest: st, stalled, open, slugs, notReady };
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

  if (args.includes("--pr-self-test")) {
    const st = prSelfTest();
    for (const f of st.failures) console.log(`FAIL ${f}`);
    console.log(
      `pr-filter self-test: ${st.cases - st.failures.length}/${st.cases} cases passed (${st.matched} flagged as stalled)`,
    );
    process.exit(st.failures.length ? 1 : 0);
  }

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

  // --- stalled PRs ---
  const pl = scanPRs(now, errors);
  const prLines = pl.stalled.map((s) =>
    [s.slug, `#${s.pr.number}`, formatAge(s.ageMs), s.pr.title, `merger: ${s.merger}`, s.pr.url].join("\t"),
  );
  for (const l of prLines) console.log(l);
  if (pl.ran) {
    const nr = Object.entries(pl.notReady)
      .map(([k, v]) => `${v} ${k}`)
      .join(", ");
    console.log(
      `${pl.stalled.length} stalled PR(s) (approved + green + not draft + idle >${PR_STALE_AFTER_HOURS}h; ` +
        `${pl.open} open across ${pl.slugs} GitHub repo(s)${nr ? `; not ready: ${nr}` : ""}; ` +
        `pr-filter self-test ${pl.selfTest.cases}/${pl.selfTest.cases})`,
    );
  } else {
    console.log("stalled PRs: NOT SCANNED, the pr-filter self-test failed (see ERROR lines)");
  }
  for (const e of errors) console.log(`ERROR ${e}`);

  if (args.includes("--email") && (unowned.length > 0 || pl.stalled.length > 0)) {
    const branchPart = unowned.length
      ? [
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
          "",
        ]
      : [];
    const prPart = pl.stalled.length
      ? [
          `${pl.stalled.length} open PR(s) are approved, green, not drafts, and untouched for over ${PR_STALE_AFTER_HOURS}h. Each needs one named hand to merge it:`,
          "",
          ...pl.stalled.map(
            (s) => `• ${s.slug} #${s.pr.number} (${formatAge(s.ageMs)} idle) "${s.pr.title}"\n  likely merger: ${s.merger}; ${s.why}\n  ${s.pr.url}`,
          ),
          "",
        ]
      : [];
    const text = [
      ...branchPart,
      ...prPart,
      ...(errors.length ? ["Also, the scan hit errors:", ...errors.map((e) => `  ${e}`), ""] : []),
      "— Sona (unowned-branch-check, daily)",
    ].join("\n");
    const subject = [
      unowned.length ? `Unowned branches: ${unowned.length}` : null,
      pl.stalled.length ? `Stalled PRs: ${pl.stalled.length}` : null,
    ]
      .filter(Boolean)
      .join(", ");
    await sendEmail(subject, text);
    console.log(`emailed ${ALERT_TO}`);
  }

  if (errors.length) process.exit(2);
}

main().catch((e) => {
  console.log(`ERROR ${e.stack || e}`);
  process.exit(2);
});
