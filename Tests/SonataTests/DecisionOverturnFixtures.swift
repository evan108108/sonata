// Fixtures for DecisionOverturnTests, shaped on the 2026-11-12 incident.
//
// Decision c9e931e1 (importance 7) said NOT to rotate the credentials the
// AE-193 sandbox-exec hole exposed. It was stored ~18 minutes after runbook
// a564073f (importance 8), which still said to rotate them after the merge.
// Nothing flagged the pair; an inner-life pass caught it the next day
// (learning 150f95a2).
//
// `noRotationDecision` is c9e931e1's body verbatim.
//
// `sandboxExecRunbook` is a564073f's body as of 2026-11-13, with the paragraph
// the 11/13 patch added (which now quotes the decision) REMOVED, and only the
// pre-patch instruction the patch itself quotes put back: "rotate on a schedule
// post-merge". The original wording is not recoverable (no revision history),
// so this is the conservative reconstruction: any richer original shares at
// least these terms. The status-gate, docs and test paragraphs (rewritten on
// 11/13) are dropped, as are hostnames and store ids. Replaying the LIVE runbook
// instead would overstate the match, because the patch copied the decision's
// own vocabulary into it ("rotation", "regenerate", "taken").
//
// `fridayOffDecision` is the 11/11 holiday decision 0bf96f3b, with names
// replaced by pseudonyms, used as the control. createdAt values are the real ones.

enum DecisionOverturnFixtures {
    struct Fixture {
        let content: String
        let createdAt: Int64
    }

    static let sandboxExecRunbook = Fixture(
        content: """
        HOW TO RUN A COMMAND INSIDE AN ADAPTENGINE SANDBOX CONTAINER (ops /exec), after PR #842 / AE-193 (written 2026-11-12).

        WHAT CHANGED: the TENANT-WORKER exec route POST /api/v1/org-sandbox/exec used to accept any `Cf-Access-Jwt-Assertion` or `Cf-Access-Client-Id` header as proof of auth. It then injected the fleet AE_CORE_KEY without checking the signature (the ADA-292 "ops-debug bridge"). That made it an unauthenticated shell into tenant sandboxes on hosts not behind CF Access. #842 deletes the bypass. Sending CF Access headers alone now returns 401. NEVER re-add a header-presence auth shortcut. If edge auth is ever wanted, verify the Access JWT (JWKS signature + aud + exp).

        1) TENANT WORKER (org_sandbox_jobs: strategic-score, lead-analysis, etc.)
        curl -sS -X POST https://<tenant>/api/v1/org-sandbox/exec \\
          -H "X-API-Key: $SANDBOX_ADMIN_KEY" \\
          -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \\
          -H 'Content-Type: application/json' \\
          -d '{"slotId":"slot-auto-1","cmd":"tail -200 /workspace/log/supervisor.log"}'
        - X-API-Key is the ONLY credential the app checks. The worker DO's handleExec accepts SANDBOX_ADMIN_KEY (preferred) or AE_CORE_KEY (legacy; slated for removal on /exec).
        - The CF Access headers are harmless on hosts with no Access and required on hosts behind Access. Send them anyway.

        2) CORE (deep-enrichment fleet, engage-nucleus)
        POST /api/sandbox-manager/exec, with X-API-Key: $AE_CORE_KEY plus the CF Access service-token headers (core is behind Access).
        - Core's handleExec still accepts ONLY AE_CORE_KEY. SANDBOX_ADMIN_KEY does NOT work on core /exec.
        - On core, SANDBOX_ADMIN_KEY is for the /api/sandbox-manager admin endpoints (status/logs/processes/trigger-alarm).

        BODY MODES (both DOs; precedence scheduleJobs > destroy > startCmd > listProcesses > processId > cmd):
        - {slotId, cmd, timeoutMs?} runs a command (timeout clamped to 30s)
        - {slotId, processId} returns retained logs
        - {slotId, listProcesses:true}
        - {slotId, startCmd, env?} starts a background process
        - {slotId, destroy:true} gives a fresh container on the next boot
        - {scheduleJobs:true}
        Field is `slotId`, NOT `slot`. slotId is whitelisted against known slots.

        KEY FACTS:
        - AE_CORE_KEY is handed into every sandbox container (claim/callback traffic), so treat it as container-reachable.
        - SANDBOX_ADMIN_KEY is ops-only, never given to a container. Prefer it wherever accepted.
        - The supervisor never calls /exec; it uses /claim and /callback with AE_CORE_KEY.
        - Rotate on a schedule post-merge.
        """,
        createdAt: 1_794_507_325_033
    )

    static let noRotationDecision = Fixture(
        content: """
        DECISION (Evan, 2026-11-12): do NOT rotate the five credentials that PR #842 (AE-193) listed as exposed: CLAUDE_CODE_OAUTH_TOKEN (+_2, _3), AE_CORE_KEY, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET and OPENROUTER_API_KEY.
        They were reachable through the unverified Cf-Access-* fallback on the worker's /api/v1/org-sandbox/exec from 2026-09-01 until #842.
        Evan's reasoning: he doesn't think they were taken, rotation is overly cautious, and they aren't easy to regenerate.
        The fix that matters is closing the hole (#842).
        Future reviews and audits should not re-raise rotation of these as an open action item or a merge condition. The PR body's "rotate on schedule" section is superseded by this decision.
        """,
        createdAt: 1_794_508_384_415
    )

    static let fridayOffDecision = Fixture(
        content: """
        DECISION: The team takes Friday 11/13 off in place of Veterans Day (11/11), since the holiday hadn't been flagged ahead of time. Robin pointed out the date. Casey proposed it ("maybe the way to get ahead of that is just take Friday off"), and Evan agreed. Note: at the 11/10 stand-up, a new customer's white-glove onboarding was planned for "Friday", and this meeting didn't say whether it moves.
        """,
        createdAt: 1_794_508_384_415
    )
}
