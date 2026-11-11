// Work mode on a Mac, through night-shift.sh: taking an issue by Nick's
// label, refusing what a teammate or an integration labelled or edited,
// setup and the agent's sandbox, finishing into a report, `night-shift
// resume`, landing what gh says merged, _tick, and `safe`.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { ago, type Case, kase, type Logged, NAME, WBRANCH } from "./harness.ts";

const bg = (l: Logged) => l.tool === "claude" && (l.args ?? []).includes("--bg");
const notified = (c: Case, what: string) =>
  c.count((l) => l.tool === "notify" && l.title === "Night shift" && l.body === `TST-1: ${what}`);
const report = (c: Case) => c.read("state/night-shift/TST-1.report.md");
const settings = (c: Case) => JSON.parse(c.read("state/night-shift/TST-1.settings") || "null");

/**
 * Repo demo, an issue from fixtures/work-issue.json, and a config for team
 * TST. Its setup logs itself, so a case can see it ran, and when.
 */
function work(c: Case, change: (i: any) => void = () => {}): void {
  c.repo("demo");
  c.issue("issue-1", change, "work-issue.json");
  writeFileSync(`${c.dir}/config.json`, JSON.stringify({
    label: "agent", startedState: "In Progress",
    repos: {
      TST: {
        dir: c.demo, branch: "feat/{ID}/{slug}", checks: "make check",
        bootstrap: ["touch bootstrapped", `echo '{"tool": "bootstrap"}' >>${c.dir}/log.jsonl`],
        sandbox: { allowedDomains: ["pypi.org"], allowLocalBinding: true, env: { SCRATCH_DIR: "/x", GIT_TERMINAL_PROMPT: "1" } },
      },
    },
  }));
}

function config(c: Case, change: (conf: any) => void): void {
  const conf = JSON.parse(c.read("config.json"));
  change(conf);
  writeFileSync(`${c.dir}/config.json`, JSON.stringify(conf));
}

/** A worktree work mode would have made for TST-1, and the state file of an issue that has reached phase. */
function workAgent(c: Case, phase: string, started = ago()): string {
  const wt = c.agentWorktree(phase, started, WBRANCH, { labelled: "2026-10-02T09:00:00.000Z" });
  writeFileSync(`${c.state}/TST-1.settings`, "{}");
  return wt;
}

const githubOrigin = (c: Case) => c.git("-C", c.demo, "remote", "set-url", "origin", "git@github.com:test/demo.git");

/** The worktree's tip merged as PR #7, as gh lists it, from a GitHub origin. */
function workMerged(c: Case, wt: string): void {
  writeFileSync(`${c.dir}/gh-prs`, JSON.stringify([{ number: 7, url: "https://github.com/test/demo/pull/7", headRefOid: c.git("-C", wt, "rev-parse", "HEAD") }]));
  githubOrigin(c);
}

/** Nick adds the label to issue-1 again, at. */
function relabel(c: Case, at: string): void {
  c.linear("issue-1", (i) => {
    i.updatedAt = at;
    i.history.nodes.push({ createdAt: at, actorId: "user-nick", botActor: null, addedLabelIds: ["label-agent"], updatedDescription: null, fromTitle: null });
  });
}

function noLinearWrites(c: Case): void {
  assert.equal(c.ops("issueUpdate").length, 0, "no issueUpdate");
  assert.equal(c.ops("commentCreate").length, 0, "no comment");
}

/** awake leaves caffeinate running in the background, so its log line may lag the run's own return. */
async function caffeinated(c: Case): Promise<void> {
  for (let n = 0; n < 50 && !c.count((l) => l.tool === "caffeinate"); n++) await new Promise((r) => setTimeout(r, 100));
  assert.equal(c.count((l) => l.tool === "caffeinate" && l.args?.join(" ") === "-s -t 660" && l.lock === false), 1,
    "kept awake on AC until a minute past the next run, without the lock");
}

kase("work_start", "work: set up, sandboxed claude --bg, In Progress, no comment", async (c) => {
  work(c);
  const wt = `${c.demo}/.claude/worktrees/${NAME}`;
  mkdirSync(`${c.dir}/home/.claude`, { recursive: true });
  mkdirSync(`${c.demo}/.claude`, { recursive: true });
  writeFileSync(`${c.dir}/home/.claude/settings.json`, '{"enabledPlugins": {"core@nnorx": true, "mine@x": true}}');
  writeFileSync(`${c.demo}/.claude/settings.local.json`, '{"enabledPlugins": {"lsp@x": true}}');
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.git("-C", wt, "symbolic-ref", "--short", "HEAD"), WBRANCH, "on the branch from the template");
  assert.ok(existsSync(`${wt}/bootstrapped`), "set up by the config's commands");
  assert.deepEqual(c.log().filter((l) => l.tool === "bootstrap" || bg(l)).map((l) => l.tool), ["bootstrap", "claude"], "set up before claude started");
  const start = c.claude("--bg")[0]!;
  assert.equal(start.cwd, wt, "claude --bg in the worktree");
  assert.deepEqual(start.args!.slice(1, 8), ["-n", NAME, "--settings", `${c.state}/TST-1.settings`, "--strict-mcp-config", "--permission-mode", "auto"],
    "with its settings, no MCP servers, in auto mode");
  assert.ok(start.args![8]!.includes("Checks: make check."), "given the task and the checks");
  assert.equal(c.count((l) => l.tool === "systemd-run"), 0, "started directly, not through systemd-run");
  const s = settings(c);
  assert.deepEqual(s.sandbox.network.allowedDomains, ["github.com", "pypi.org"], "the settings add the repo's host");
  assert.equal(s.sandbox.network.allowLocalBinding, true, "and binding to localhost");
  assert.equal(s.env.SCRATCH_DIR, "/x", "and its environment");
  assert.equal(s.env.GIT_TERMINAL_PROMPT, "0", "but not over the base's");
  assert.deepEqual(s.sandbox.filesystem.denyRead, ["~/.ssh", "~/Library/Keychains"], "and keep the base's denials");
  assert.equal(s.disableAllHooks, true, "hooks off");
  assert.deepEqual(s.enabledPlugins, { "core@nnorx": true, "lsp@x": false, "mine@x": false }, "every plugin a scope enables off, but the base's");
  const local = JSON.parse(c.read(`${wt}/.claude/settings.local.json`));
  assert.deepEqual([local.sandbox.enabled, local.permissions.deny, local.disableAllHooks, local.enabledPlugins["lsp@x"]],
    [true, ["Bash(git push:*)"], true, false], "the worktree's own settings sandbox it too");
  assert.equal(c.ops("issueUpdate").length, 1, "moved to In Progress, once");
  assert.equal(c.stateName(), "In Progress");
  assert.equal(c.ops("commentCreate").length, 0, "no comment");
  assert.equal(c.st().phase, "running");
  assert.ok(c.st().setup.includes("?? bootstrapped"), "which records what setup left");
  assert.equal(c.count((l) => l.tool === "notify"), 0, "no notification");
  await caffeinated(c);
  assert.equal(c.count((l) => l.tool === "systemctl"), 0, "never forge's unit");
});

/** Refused by workStart: nothing made, no agent, nothing written to Linear, and said once, in a notification and the report. */
async function workRefused(c: Case, why: string): Promise<void> {
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.ok(!existsSync(`${c.demo}/.claude/worktrees/${NAME}`), "no worktree");
  assert.ok(!c.branchExists(WBRANCH), "no branch");
  assert.equal(c.count(bg), 0, "no claude --bg");
  noLinearWrites(c);
  assert.equal(c.st().phase, "refused");
  assert.ok(report(c).includes(why), report(c));
  assert.equal(notified(c, "Not started"), 1, "a notification");
  await c.nsw(["run"]);
  assert.equal(notified(c, "Not started"), 1, "said once, not every run");
  assert.equal(c.ops("issue").length, 1, "not asked about again, unchanged");
}

kase("work_start_not_labeler", "work: labelled by a teammate: refused, said once", async (c) => {
  work(c, (i) => (i.history.nodes[1].actorId = "user-teammate"));
  await workRefused(c, "the label was last added by someone else or by an integration");
});

kase("work_start_bot", "work: labelled by an integration: refused", async (c) => {
  work(c, (i) => (i.history.nodes[1].botActor = { id: "bot-mcp" }));
  await workRefused(c, "the label was last added by someone else or by an integration");
});

// Linear's filter leaves it out of the queue, so a run passes it over in
// silence; workStart refuses it all the same when handed it.
kase("work_start_not_assignee", "work: assigned to someone else: refused", async (c) => {
  work(c, (i) => (i.assignee.id = "user-teammate"));
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.ops("issue").length, 0, "not in the queue");
  assert.equal(c.count((l) => l.tool === "notify"), 0, "no notification");
  await c.nsw(["_start", "user-nick", "issue-1"]);
  assert.ok(report(c).includes("it is not assigned to you"), "refused when handed it");
  assert.equal(c.count(bg), 0, "no claude --bg");
  noLinearWrites(c);
});

// The label set when the issue was made: no history entry adds it, so the
// creation stands in, and counts as Nick's only if no integration made it.
function createdLabelled(c: Case, change: (i: any) => void = () => {}): void {
  work(c, (i) => {
    i.creator.id = "user-nick";
    i.history.nodes = [i.history.nodes[0]];
    change(i);
  });
}

kase("work_start_created_labelled", "work: labelled when Nick made it: started", async (c) => {
  createdLabelled(c);
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.st().phase, "running", "started");
});

kase("work_start_created_by_bot", "work: labelled when an integration made it as Nick: refused", async (c) => {
  createdLabelled(c, (i) => (i.botActor = { id: "bot-integration" }));
  await workRefused(c, "the label was last added by someone else or by an integration");
});

kase("work_start_edited", "work: text changed by a teammate after the label: refused", async (c) => {
  work(c, (i) => i.history.nodes.push({
    createdAt: "2026-10-03T09:00:00.000Z", actorId: "user-teammate", botActor: null, addedLabelIds: null, updatedDescription: true, fromTitle: null,
  }));
  await workRefused(c, "someone else changed its title or description after you added the label");
});

kase("work_start_relabelled", "work: refused, then labelled again by Nick: started", async (c) => {
  work(c, (i) => (i.history.nodes[1].actorId = "user-teammate"));
  await c.nsw(["run"]);
  assert.equal(c.st().phase, "refused", "refused first");
  relabel(c, "2026-10-04T09:00:00.000Z");
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.claude("--bg").length, 1, "started once Nick added the label again");
  assert.equal(c.st().phase, "running");
});

kase("work_bootstrap_fails", "work: setup fails: refused, worktree removed", async (c) => {
  work(c);
  config(c, (conf) => (conf.repos.TST.bootstrap = ["exit 3"]));
  await workRefused(c, "setting up the worktree failed, and it is removed.");
  assert.ok(c.read("state/night-shift/TST-1.bootstrap.log").includes("$ exit 3"), "the setup log kept");
});

kase("work_overrides", "work: repo settings change the sandbox: refused", async (c) => {
  work(c);
  mkdirSync(`${c.demo}/.claude`, { recursive: true });
  writeFileSync(`${c.demo}/.claude/settings.local.json`, '{"sandbox": {"excludedCommands": ["docker *"]}}');
  await workRefused(c, `these settings would change the agent's sandbox or run a command outside it: ${c.demo}/.claude/settings.local.json`);
});

// A helper command Claude runs itself, outside the sandbox, from the branch's
// own settings: refused. Nick's own, in his user settings, is not.
kase("work_helper", "work: the branch's settings name a helper command: refused", async (c) => {
  work(c);
  const seed = `${c.dir}/tmp/seed-helper`;
  c.git("clone", "-q", `${c.dir}/remote/demo.git`, seed);
  mkdirSync(`${seed}/.claude`);
  writeFileSync(`${seed}/.claude/settings.json`, '{"apiKeyHelper": "./get-key.sh"}');
  c.git("-C", seed, "add", ".claude/settings.json");
  c.git("-C", seed, "commit", "-q", "-m", "a helper");
  c.git("-C", seed, "push", "-q", "origin", "HEAD:main");
  await workRefused(c, `these settings would change the agent's sandbox or run a command outside it: ${c.demo}/.claude/worktrees/${NAME}/.claude/settings.json`);
});

kase("work_helper_user", "work: Nick's own settings name a helper command: started", async (c) => {
  work(c);
  mkdirSync(`${c.dir}/home/.claude`, { recursive: true });
  writeFileSync(`${c.dir}/home/.claude/settings.json`, '{"apiKeyHelper": "/usr/local/bin/get-key"}');
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.st().phase, "running", "started");
});

// A tracked file setup changed is not recorded as setup's: the agent may
// change it too, and land would then remove the worktree with its work.
kase("work_setup_tracked", "work: a tracked file setup changed is not recorded as setup's", async (c) => {
  work(c);
  config(c, (conf) => (conf.repos.TST.bootstrap = ["touch made", "echo more >>README.md"]));
  assert.equal((await c.nsw(["run"])).status, 0);
  const setup: string[] = c.st().setup;
  assert.deepEqual([setup.includes("?? made"), setup.some((l) => l.endsWith("README.md"))], [true, false],
    "the untracked file recorded, not the changed one");
});

kase("work_finish_handoff", "work: handoff: notification and report, nothing in Linear", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  const wt = workAgent(c, "running");
  mkdirSync(`${c.demo}/.git/night-shift`, { recursive: true });
  writeFileSync(`${c.demo}/.git/night-shift/TST-1.md`, "handoff\nFixed the widget; the checks pass.\n");
  assert.equal((await c.nsw(["run"])).status, 0);
  noLinearWrites(c);
  assert.equal(notified(c, "Handoff ready"), 1, "a notification");
  assert.equal(c.count((l) => l.tool === "notify" && !!l.script?.join(" ").includes("TST-1")), 0, "the text never reaches AppleScript's script");
  assert.ok(report(c).includes("Fixed the widget; the checks pass."), "the report has the result");
  assert.ok(report(c).includes(`To publish: \`cd ${wt} && pr-handoff\`.`), "and how to publish");
  assert.equal(c.count((l) => l.tool === "bwrap"), 0, "no preflight");
  assert.equal(c.st().phase, "waiting");
  assert.ok((await c.nsw(["status"])).out.includes("# TST-1: Handoff ready"), "status shows the report");
});

kase("work_finish_blocked", "work: blocked: report says how to answer", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "running");
  mkdirSync(`${c.demo}/.git/night-shift`, { recursive: true });
  writeFileSync(`${c.demo}/.git/night-shift/TST-1.md`, "blocked\n1. Which widget?\n");
  assert.equal((await c.nsw(["run"])).status, 0);
  noLinearWrites(c);
  assert.equal(notified(c, "Needs you"), 1, "a notification");
  assert.ok(report(c).includes('`night-shift resume TST-1 "<answer>"`'), "the report says how to answer");
});

kase("work_resume", "work: night-shift resume: resumed with the answer", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "waiting");
  assert.equal((await c.nsw(["resume", "tst-1", "Use the blue one."])).status, 0);
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.count((l) => l.tool === "claude" && l.args?.join(" ") === "stop job-1"), 1, "the finished session stopped first");
  const resumes = c.claude("--bg");
  assert.equal(resumes.length, 1, "resumed once");
  assert.deepEqual(resumes[0]!.args!.slice(0, 3), ["--bg", "--resume", "session-1"]);
  assert.equal(resumes[0]!.args!.length, 4, "with no new flags");
  assert.ok(resumes[0]!.args![3]!.includes("with this answer:\n\nUse the blue one."), "given the answer");
  assert.ok(!existsSync(`${c.state}/TST-1.answer`), "the answer used up");
  assert.equal(c.st().phase, "running");
  assert.equal(c.ops("issueUpdate").length, 0, "already In Progress, so not moved");
});

// resume starts launchd's run at once, when given its job.
kase("work_resume_now", "work: resume starts launchd's run at once", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "waiting");
  const { status, out } = await c.nsw(["resume", "TST-1", "Use the blue one."], { env: { NIGHT_SHIFT_LAUNCHD_LABEL: "org.example.night-shift" } });
  assert.equal(status, 0);
  assert.ok(existsSync(`${c.state}/TST-1.answer`), "the answer kept for the run");
  assert.equal(c.count((l) => l.tool === "launchctl" && l.args?.join(" ") === `kickstart gui/${process.getuid!()}/org.example.night-shift`), 1, "launchd's job started");
  assert.ok(out.includes("TST-1 resumes in the run starting now"), out);
});

// No job to start, or one launchctl cannot find: the answer waits for the
// next run, as before.
kase("work_resume_no_job", "work: resume with no job, or one launchctl cannot find: next run", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "waiting");
  assert.equal((await c.nsw(["resume", "TST-1", "Use the blue one."])).status, 0);
  assert.equal(c.count((l) => l.tool === "launchctl"), 0, "nothing started without a job");
  writeFileSync(`${c.dir}/launchctl-fail`, "");
  const { status, out } = await c.nsw(["resume", "TST-1", "Use the red one."], { env: { NIGHT_SHIFT_LAUNCHD_LABEL: "org.example.night-shift" } });
  assert.equal(status, 0, "exit 0 when launchctl fails");
  assert.equal(c.read("state/night-shift/TST-1.answer").trim(), "Use the red one.", "the newer answer kept");
  assert.ok(out.includes("TST-1 resumes on the next run"), out);
  assert.ok(!out.includes("run starting now"), "never that a run started");
});

kase("work_resume_relabelled", "work: labelled again while waiting: resumed once", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  relabel(c, "2030-01-01T00:00:00.000Z");
  workAgent(c, "waiting");
  assert.equal((await c.nsw(["run"])).status, 0);
  const resumed = () => c.claude("--bg").filter((l) => l.args![1] === "--resume");
  assert.equal(resumed().length, 1);
  assert.ok(resumed()[0]!.args![3]!.includes("by adding its label again"), "resumed, saying how");
  await c.nsw(["run"]);
  assert.equal(resumed().length, 1, "once");
});

/** Gone, with its branch, session and settings, and nothing said in Linear. */
function landed(c: Case, wt: string): void {
  assert.ok(!existsSync(wt), "the worktree removed");
  assert.ok(!c.branchExists(WBRANCH), "the branch deleted");
  assert.equal(c.count((l) => l.tool === "claude" && l.args?.join(" ") === "rm job-1"), 1, "the session removed");
  assert.ok(!existsSync(`${c.state}/TST-1.settings`), "and the settings it was started with");
  assert.equal(c.st(), undefined, "the issue forgotten");
  noLinearWrites(c);
}

kase("work_land", "work: completed and merged per gh: all removed, nothing in Linear", async (c) => {
  work(c, (i) => (i.state = { name: "Done", type: "completed" }));
  const wt = workAgent(c, "waiting");
  workMerged(c, wt);
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 0);
  assert.equal(c.count((l) => l.tool === "gh" && l.args?.slice(0, 7).join(" ") === `pr list --repo test/demo --head ${WBRANCH} --state`), 1,
    "asked gh for the branch's merged PRs");
  assert.equal(c.count((l) => l.tool === "github"), 0, "never GitHub's API");
  landed(c, wt);
  assert.ok(out.includes("TST-1: Merged in [#7](https://github.com/test/demo/pull/7). Removed its worktree"), out);
});

// Handed off, then asked for more through claude attach: the agent reported
// again, and the PR merged before the next run. Landed as any merged issue,
// not forgotten as one closed while its agent worked.
kase("work_land_reported_again", "work: merged after the agent reported again: landed, not forgotten", async (c) => {
  work(c, (i) => (i.state = { name: "Done", type: "completed" }));
  const wt = workAgent(c, "waiting");
  mkdirSync(`${c.demo}/.git/night-shift`, { recursive: true });
  writeFileSync(`${c.demo}/.git/night-shift/TST-1.md`, "handoff\nTweaked the widget.\n");
  workMerged(c, wt);
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 0);
  assert.ok(!out.includes("closed while running"), "not forgotten as closed while running");
  assert.ok(out.includes("TST-1: Merged in [#7](https://github.com/test/demo/pull/7). Removed its worktree"), out);
  landed(c, wt);
  assert.ok(!existsSync(`${c.demo}/.git/night-shift/TST-1.md`), "its result gone with it");
});

kase("work_start_poisoned_head", "work: origin/HEAD pointed at an agent's branch: made from origin's", async (c) => {
  work(c);
  c.poisonHead();
  assert.equal((await c.nsw(["run"])).status, 0);
  const wt = `${c.demo}/.claude/worktrees/${NAME}`;
  assert.equal(c.git("-C", wt, "rev-parse", "HEAD"), c.git("-C", `${c.dir}/remote/demo.git`, "rev-parse", "main"), "made from origin's main");
  assert.ok(!existsSync(`${wt}/evil.txt`), "set up with nothing of the agent's");
});

kase("work_bg_fails", "work: claude --bg fails: removed, and starts afresh when labelled again", async (c) => {
  work(c);
  writeFileSync(`${c.dir}/claude-fail`, "");
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.ok(report(c).includes("`claude --bg` failed, saying `claude stub: told to fail`, and the worktree is removed"), report(c));
  assert.ok(!existsSync(`${c.demo}/.claude/worktrees/${NAME}`), "the worktree removed");
  assert.ok(!c.branchExists(WBRANCH), "the branch deleted");
  assert.ok(!existsSync(`${c.state}/TST-1.settings`), "its settings removed");
  rmSync(`${c.dir}/claude-fail`);
  relabel(c, "2026-10-04T09:00:00.000Z");
  await c.nsw(["run"]);
  assert.equal(c.st().phase, "running", "labelled again, it starts afresh");
});

// A daemon a setup command starts must not hold the run's lock.
kase("work_bootstrap_lock", "work: setup runs without the run lock's descriptor", async (c) => {
  work(c);
  config(c, (conf) => (conf.repos.TST.bootstrap = ["if { true >&9; } 2>/dev/null; then touch fd9-open; fi"]));
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.st().phase, "running", "started");
  assert.ok(!existsSync(`${c.demo}/.claude/worktrees/${NAME}/fd9-open`), "setup ran without the lock's descriptor");
});

kase("work_land_busy", "work: merged but a session at work: kept, with its settings", async (c) => {
  work(c, (i) => (i.state = { name: "Done", type: "completed" }));
  const wt = workAgent(c, "waiting");
  c.roster((r) => r.push({ id: "job-2", sessionId: "session-2", name: "a copy", cwd: wt, state: "running" }));
  workMerged(c, wt);
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.ok(existsSync(wt), "the worktree kept");
  assert.ok(existsSync(`${c.state}/TST-1.settings`), "and the settings its sessions use");
  assert.equal(notified(c, "merged, worktree kept"), 1, "a notification saying so");
});

// Parked and unchanged in Linear: not asked about at all.
kase("work_waiting_quiet", "work: waiting and unchanged in Linear: not even asked about", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "waiting");
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.ops("issue").length, 0, "not asked about");
  assert.equal(c.count(bg), 0, "not resumed");
});

/** Merged, with what setup left untracked in the worktree, as git-lfs's hooks under a relative hooksPath. */
function mergedWithSetupLeftovers(c: Case): string {
  work(c, (i) => (i.state = { name: "Done", type: "completed" }));
  const wt = workAgent(c, "waiting");
  c.st((s) => (s.setup = ["?? .husky/_/pre-push"]));
  mkdirSync(`${wt}/.husky/_`, { recursive: true });
  writeFileSync(`${wt}/.husky/_/pre-push`, 'git lfs pre-push "$@"\n');
  workMerged(c, wt);
  return wt;
}

kase("work_land_setup_leftovers", "work: merged, only setup's files untracked: all removed", async (c) => {
  const wt = mergedWithSetupLeftovers(c);
  assert.equal((await c.nsw(["run"])).status, 0);
  landed(c, wt);
  assert.equal(c.count((l) => l.tool === "notify"), 0, "no notification");
});

kase("work_land_dirty", "work: merged, the agent's file untracked: kept, and status says so", async (c) => {
  const wt = mergedWithSetupLeftovers(c);
  writeFileSync(`${wt}/notes.txt`, "not committed\n");
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 0);
  assert.ok(existsSync(`${wt}/notes.txt`), "the worktree kept, with the agent's file");
  assert.ok(out.includes("?? notes.txt"), "the log names the agent's file");
  assert.ok(!out.includes("?? .husky/_/pre-push"), "and not setup's");
  assert.equal(notified(c, "merged, worktree kept"), 1, "a notification");
  assert.ok(existsSync(`${c.state}/TST-1.settings`), "the settings kept for the session");
  assert.ok((await c.nsw(["status"])).out.includes("TST-1  merged, but its worktree and session were kept"), "status lists them");
});

// A file the agent adds inside a directory setup made is still the agent's.
kase("work_land_inside_setup_dir", "work: merged, the agent's file in setup's directory: kept", async (c) => {
  const wt = mergedWithSetupLeftovers(c);
  writeFileSync(`${wt}/.husky/_/notes.txt`, "the agent's\n");
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 0);
  assert.ok(existsSync(`${wt}/.husky/_/notes.txt`), "the worktree kept");
  assert.ok(out.includes("?? .husky/_/notes.txt"), "the log names it");
});

kase("work_land_gh_fails", "work: gh fails: all kept", async (c) => {
  work(c, (i) => (i.state = { name: "Done", type: "completed" }));
  const wt = workAgent(c, "waiting");
  writeFileSync(`${c.dir}/gh-fail`, "");
  githubOrigin(c);
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 0);
  assert.ok(existsSync(wt), "the worktree kept");
  assert.ok(c.st(), "the issue kept");
  assert.ok(out.includes("gh could not say whether TST-1 merged"), out);
});

kase("work_canceled", "work: canceled: forgotten, worktree kept", async (c) => {
  work(c, (i) => (i.state = { name: "Canceled", type: "canceled" }));
  const wt = workAgent(c, "waiting");
  assert.equal((await c.nsw(["run"])).status, 0);
  assert.equal(c.st(), undefined, "the issue forgotten");
  assert.ok(existsSync(wt), "the worktree kept, for Nick");
});

// --- _tick --------------------------------------------------------------------------

kase("work_tick", "work: _tick: three failed runs, one notification", async (c) => {
  work(c);
  for (const n of [1, 2, 3]) assert.equal((await c.nsw(["_tick"], { env: { NIGHT_SHIFT_KEY_CMD: "false" } })).status, 0, `tick ${n}`);
  assert.equal(c.read("state/night-shift/failed-runs").trim(), "3", "a failing run counted");
  const pushes = c.log().filter((l) => l.tool === "notify" && l.title === "Night shift is failing");
  assert.equal(pushes.length, 1, "one notification on the third");
  assert.ok(pushes[0]!.body!.includes(`${c.dir}/night-shift.log says why.`), "pointing at the log");
});

kase("work_tick_unconfigured", "work: _tick with no config: nothing, no failure", async (c) => {
  assert.equal((await c.nsw(["_tick"])).status, 0);
  assert.equal(c.count((l) => l.tool === "linear"), 0, "no run");
  assert.ok(!existsSync(`${c.state}/failed-runs`), "nothing counted");
});

kase("work_tick_awake", "work: _tick with an agent at work: the Mac kept awake", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "running");
  assert.equal((await c.nsw(["_tick"], { env: { NIGHT_SHIFT_INTERVAL: "600" } })).status, 0);
  await caffeinated(c);
  assert.equal(c.count((l) => l.tool === "systemctl"), 0, "never forge's unit");
});

kase("work_tick_waiting", "work: _tick with an agent waiting on Nick: left to sleep", async (c) => {
  work(c, (i) => (i.state = { name: "In Progress", type: "started" }));
  workAgent(c, "waiting");
  assert.equal((await c.nsw(["_tick"], { env: { NIGHT_SHIFT_INTERVAL: "600" } })).status, 0);
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(c.count((l) => l.tool === "caffeinate"), 0, "left to sleep");
  assert.equal(c.count((l) => l.tool === "systemctl"), 0, "never forge's unit");
});

// --- safe -----------------------------------------------------------------------------

// claude here, in the agents' sandbox, with the repository's additions from
// the config, and nothing written in the checkout.
kase("work_safe", "work: safe: claude here, sandboxed, the checkout untouched", async (c) => {
  work(c);
  mkdirSync(`${c.demo}/.claude`, { recursive: true });
  writeFileSync(`${c.demo}/.claude/settings.local.json`, '{"enabledPlugins": {"lsp@x": true}}');
  assert.equal((await c.nsw(["safe", "--model", "test"], { cwd: c.demo })).status, 0);
  const call = c.log().find((l) => l.tool === "claude")!;
  const file = call.args![1]!;
  assert.equal(realpathSync(call.cwd!), realpathSync(c.demo), "claude in the checkout");
  assert.deepEqual(call.args!.slice(2), ["--strict-mcp-config", "--model", "test"], "with its settings, no MCP servers, and the arguments given");
  assert.ok(file.startsWith(`${c.state}/safe.`), "the settings under the state directory");
  assert.ok(!existsSync(file), "and gone once the session ended");
  const given = JSON.parse(c.read("settings-given.json"));
  assert.equal(given.disableAllHooks, true, "hooks off");
  assert.equal(given.enabledPlugins["lsp@x"], false, "the checkout's plugin off");
  assert.deepEqual(given.sandbox.network.allowedDomains, ["github.com", "pypi.org"], "the repository's host added");
  assert.equal(c.read(`${c.demo}/.claude/settings.local.json`), '{"enabledPlugins": {"lsp@x": true}}', "the checkout's own settings left as they were");
  noLinearWrites(c);
});

// Outside any repository the config names, and with no config at all: the
// base alone.
kase("work_safe_elsewhere", "work: safe outside a configured repository: the base alone", async (c) => {
  mkdirSync(`${c.dir}/tmp/plain`);
  assert.equal((await c.nsw(["safe"], { cwd: `${c.dir}/tmp/plain` })).status, 0);
  assert.equal(c.count((l) => l.tool === "claude"), 1, "claude started");
  assert.deepEqual(JSON.parse(c.read("settings-given.json")).sandbox.network.allowedDomains, ["github.com"], "the base's hosts only");
});

// Refused as an agent's start is, and forge's sessions are sandboxed anyway.
kase("work_safe_refused", "work: safe refused for settings that change the sandbox, and on forge", async (c) => {
  work(c);
  mkdirSync(`${c.demo}/.claude`, { recursive: true });
  writeFileSync(`${c.demo}/.claude/settings.local.json`, '{"sandbox": {"excludedCommands": ["docker *"]}}');
  const r = await c.nsw(["safe"], { cwd: c.demo });
  assert.equal(r.status, 1);
  assert.ok(r.out.includes(`would change the sandbox or run a command outside it: ${realpathSync(c.demo)}/.claude/settings.local.json`), r.out);
  assert.equal(c.count((l) => l.tool === "claude"), 0, "no claude");
  const f = await c.ns(["safe"], { cwd: c.demo });
  assert.equal(f.status, 1, "forge: exit 1");
  assert.ok(f.out.includes("safe is work mode's"), f.out);
});
