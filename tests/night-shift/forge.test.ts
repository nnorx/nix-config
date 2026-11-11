// A run in forge mode, through night-shift.sh: land, start, finish, the
// machine kept awake or let sleep, _after, and tidy. A case on tidy or land
// gives its repository a literal GitHub origin, and one that starts an agent,
// which must fetch, a local bare one: an insteadOf mapping instead would hide
// the GitHub URL from `git remote get-url`.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { ago, BRANCH, type Case, kase, type Logged, NAME } from "./harness.ts";

const pushed = (c: Case, body: string) => c.count((l) => l.tool === "ntfy" && l.body === body);
const systemctl = (c: Case, verb: string) =>
  c.count((l) => l.tool === "systemctl" && l.args?.join(" ") === `--user ${verb} night-shift-awake.service`);
const bg = (l: Logged) => l.tool === "claude" && (l.args ?? []).includes("--bg");

// --- 1. land, through run --------------------------------------------------------

/** A handoff whose PR merged at sha, by default the worktree's tip. */
function mergedHandoff(c: Case, sha?: string): string {
  c.repo("demo");
  c.git("-C", c.demo, "remote", "set-url", "origin", "https://github.com/test/demo");
  const wt = c.agentWorktree("waiting");
  c.issue("issue-1", (i) => (i.state = { name: "Handoff ready", type: "started" }));
  const prs = [
    { number: 11, html_url: "https://github.com/test/demo/pull/11", merged_at: null, head: { sha: "0000" } },
    { number: 12, html_url: "https://github.com/test/demo/pull/12", merged_at: "2026-10-12T08:00:00Z", head: { sha: sha ?? c.git("-C", wt, "rev-parse", "HEAD") } },
  ];
  writeFileSync(`${c.dir}/github`, `200\n${JSON.stringify(prs)}\n`);
  return wt;
}

/** Nothing removed: the worktree, its branch and its session are all still there, and the issue says why. */
function kept(c: Case, wt: string, why: string): void {
  assert.ok(existsSync(wt), "the worktree kept");
  assert.ok(c.branchExists(BRANCH), "the branch kept");
  assert.equal(c.claude("rm").length, 0, "no claude rm");
  assert.ok(c.comments().includes(`Kept its worktree \`${wt}\`, the branch and the agent's session, since ${why}`), c.comments());
  assert.equal(c.stateName(), "Done", "moved to Done anyway");
  assert.equal(c.st(), undefined, "the issue forgotten");
}

kase("land_clean", "land: merged at the tip, clean, sessions done: all removed, Done", async (c) => {
  const wt = mergedHandoff(c);
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.count((l) => l.tool === "github" && !!l.url?.endsWith(`/repos/test/demo/pulls?state=closed&head=test:${BRANCH}`)), 1, "asked GitHub for the branch's PRs");
  assert.ok(!existsSync(wt), "the worktree removed");
  assert.ok(!c.branchExists(BRANCH), "the branch deleted");
  assert.ok(!c.gitOk("-C", c.demo, "config", "--get-regexp", `^branch\\.${BRANCH}\\.`), "the branch's config section gone");
  assert.equal(c.count((l) => l.tool === "claude" && l.args?.join(" ") === "rm job-1"), 1, "the session removed");
  assert.equal(c.stateName(), "Done", "moved to Done, the first completed state");
  assert.ok(c.comments().includes(`Merged in [#12](https://github.com/test/demo/pull/12). Removed its worktree, the agent's session and the branch \`${BRANCH}\`.`), c.comments());
  assert.equal(c.st(), undefined, "the issue forgotten");
  assert.equal(c.count((l) => l.tool === "ntfy"), 0, "no push");
});

kase("land_moved_tip", "land: the tip moved past the merged head: all kept", async (c) => {
  const wt = mergedHandoff(c);
  const merged = c.git("-C", wt, "rev-parse", "HEAD");
  writeFileSync(`${wt}/widget.txt`, "widget\nmore\n");
  c.git("-C", wt, "commit", "-q", "-am", "after the merge");
  assert.equal((await c.ns(["run"])).status, 0);
  kept(c, wt, `\`${BRANCH}\` is at ${c.git("-C", wt, "rev-parse", "--short=12", "HEAD")}, and the PR merged ${merged.slice(0, 12)}.`);
});

kase("land_dirty", "land: a change not committed: all kept", async (c) => {
  const wt = mergedHandoff(c);
  writeFileSync(`${wt}/notes.txt`, "not committed\n");
  assert.equal((await c.ns(["run"])).status, 0);
  kept(c, wt, "it has changes not committed:");
  assert.ok(existsSync(`${wt}/notes.txt`), "the change itself kept");
  assert.ok(c.comments().includes("?? notes.txt"), "the comment names the file");
});

kase("land_busy", "land: a session still running: all kept", async (c) => {
  const wt = mergedHandoff(c);
  c.roster((r) => r.push({ id: "job-2", sessionId: "session-2", name: "a copy", cwd: wt, state: "running" }));
  assert.equal((await c.ns(["run"])).status, 0);
  kept(c, wt, "a session there is still at work: job-2 is running.");
});

// --- 2. start's refusals, through run --------------------------------------------

/** Refused by start: in Needs you, with nothing made and no agent started. */
async function refused(c: Case, comment: string, push: string): Promise<void> {
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes(comment), c.comments());
  assert.ok(!existsSync(`${c.demo}/.claude/worktrees`), "no worktree");
  assert.ok(!c.branchExists(BRANCH), "no branch");
  assert.equal(c.count(bg), 0, "no claude --bg");
  assert.equal(c.st(), undefined, "no state file");
  assert.equal(pushed(c, `TST-1: ${push}`), 1, "a push saying why");
}

kase("start_not_creator", "start: created by someone else: Needs you", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.creator.id = "user-other"));
  await refused(c, "Not started: only issues you created are taken", "Not yours");
});

kase("start_not_queuer", "start: queued last by someone else: Needs you", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => {
    i.history.nodes.push({ createdAt: "2026-10-01T10:00:00.000Z", actorId: "user-sync", toState: { name: "Queued" } });
    i.history.nodes.reverse();
  });
  await refused(c, "Not started: only issues you move to Queued yourself are taken.", "Not queued by you");
});

// An automation's move: recorded, with no actor. Nick created the issue, but
// the move is not his.
kase("start_no_actor", "start: queued last with no actor recorded: Needs you", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.history.nodes[1].actorId = null));
  await refused(c, "Not started: Linear recorded no person moving it to Queued", "Not queued by you");
});

kase("start_long_history", "start: history with another page: Needs you", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.history.pageInfo.hasNextPage = true));
  await refused(c, "Not started: its history is too long to tell who queued it.", "Not started");
});

kase("start_no_repo_label", "start: no repo label: Needs you", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.labels.nodes = i.labels.nodes.filter((l: any) => l.parent?.name !== "repo")));
  await refused(c, `Not started: give it a \`repo\` label naming a repository in ${c.dir}/projects with an \`origin\`.`, "No repo");
});

// --- 3. start's happy path, through run ------------------------------------------

kase("start", "start: worktree with no upstream, issue text, claude --bg, Running, kept awake", async (c) => {
  c.repo("demo");
  c.issue("issue-1");
  const wt = `${c.demo}/.claude/worktrees/${NAME}`;
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.git("-C", wt, "symbolic-ref", "--short", "HEAD"), BRANCH, "a worktree on its branch");
  assert.equal(c.git("-C", wt, "rev-parse", "HEAD"), c.git("-C", c.demo, "rev-parse", "origin/main"), "made from origin/main");
  assert.ok(!c.gitOk("-C", c.demo, "config", "--get", `branch.${BRANCH}.remote`), "with no upstream");
  assert.ok(c.read(`${c.demo}/.git/night-shift/TST-1.issue.md`).includes("Make the widget work again."), "TST-1.issue.md written");
  const starts = c.claude("--bg");
  assert.equal(starts.length, 1, "claude --bg called once");
  assert.equal(starts[0]!.cwd, wt, "in the worktree");
  assert.deepEqual(starts[0]!.args!.slice(1, 5), ["-n", NAME, "--permission-mode", "auto"], "named, in auto mode");
  assert.ok(starts[0]!.args![5]!.includes("# TST-1: Fix the widget"), "given the task");
  assert.equal(c.count((l) => l.tool === "systemd-run" && !!l.args?.includes("--bg")), 1, "through systemd-run, outside the unit");
  assert.equal(c.stateName(), "Running");
  assert.equal(c.st().phase, "running");
  assert.equal(c.st().session, "session-1", "with the session from the roster");
  assert.equal(systemctl(c, "start"), 1, "forge kept awake, on AC");
  assert.equal(systemctl(c, "stop"), 0, "and not let sleep");
});

// Created straight into Queued: no move recorded, so the creator queued it.
kase("start_created_queued", "start: created into Queued by you: started", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.history.nodes = []));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.claude("--bg").length, 1, "claude --bg called once");
  assert.equal(c.stateName(), "Running");
});

kase("start_battery", "start: on battery: started, forge let sleep", async (c) => {
  c.repo("demo");
  c.issue("issue-1");
  writeFileSync(`${c.dir}/power/AC/online`, "0\n");
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Running", "started anyway");
  assert.equal(systemctl(c, "stop"), 1, "forge let sleep, on battery");
  assert.equal(systemctl(c, "start"), 0, "and not kept awake");
});

// claude --bg fails, as with no claude installed or a directory never
// trusted: its first line with anything on it reaches the comment, and what
// start made goes.
async function bgFails(c: Case): Promise<string> {
  c.repo("demo");
  c.issue("issue-1");
  writeFileSync(`${c.dir}/claude-fail`, "\n  Error: workspace not trusted  \nRun claude here once and accept the prompt.\n");
  assert.equal((await c.ns(["run"])).status, 0);
  return `${c.demo}/.claude/worktrees/${NAME}`;
}

kase("start_bg_fails", "start: claude --bg fails: its first line in the comment, all removed, Needs you", async (c) => {
  const wt = await bgFails(c);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes(`Not started: \`claude --bg\` failed in \`${wt}\`, saying \`Error: workspace not trusted\`.`), c.comments());
  assert.ok(!c.comments().includes("accept the prompt"), "and none of the rest");
  assert.ok(c.comments().includes(`The worktree and \`${BRANCH}\` are removed`), "saying what went");
  assert.ok(!existsSync(wt), "the worktree removed");
  assert.ok(!c.git("-C", c.demo, "worktree", "list", "--porcelain").includes(wt), "and git's record of it");
  assert.ok(!c.branchExists(BRANCH), "the branch deleted");
  assert.equal(c.st(), undefined, "no state file");
  assert.equal(pushed(c, "TST-1: Did not start"), 1);
});

kase("start_bg_fails_requeued", "start: claude --bg failed, then queued again: started", async (c) => {
  const wt = await bgFails(c);
  rmSync(`${c.dir}/claude-fail`);
  c.linear("issue-1", (i) => (i.state = { name: "Queued", type: "unstarted" }));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Running", "started");
  assert.equal(c.git("-C", wt, "symbolic-ref", "--short", "HEAD"), BRANCH, "in a new worktree");
  assert.equal(c.st().phase, "running");
});

// Something committed on the branch before claude failed: nothing goes.
kase("start_bg_fails_committed", "start: claude --bg fails after a commit on the branch: all kept", async (c) => {
  writeFileSync(`${c.dir}/claude-before`, 'echo widget >widget.txt\ngit add widget.txt\ngit commit -q -m "fix the widget"\n');
  const wt = await bgFails(c);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes(`Kept the worktree and \`${BRANCH}\`, since \`${BRANCH}\` is no longer at the commit it was made from.`), c.comments());
  assert.ok(existsSync(`${wt}/widget.txt`), "the worktree kept");
  assert.ok(c.branchExists(BRANCH), "the branch kept");
});

kase("start_poisoned_head", "start: origin/HEAD pointed at an agent's branch: made from origin's", async (c) => {
  c.repo("demo");
  c.issue("issue-1");
  c.poisonHead();
  assert.equal((await c.ns(["run"])).status, 0);
  const wt = `${c.demo}/.claude/worktrees/${NAME}`;
  assert.equal(c.git("-C", wt, "rev-parse", "HEAD"), c.git("-C", `${c.dir}/remote/demo.git`, "rev-parse", "main"), "made from origin's main");
  assert.ok(!existsSync(`${wt}/evil.txt`), "with nothing of the agent's");
});

// --- 4. finish ---------------------------------------------------------------------

/** A running agent on TST-1, started then, that wrote result, if given. The roster says its session is at work. */
function runningAgent(c: Case, started = ago(), result?: string): string {
  c.repo("demo");
  c.agentWorktree("running", started);
  c.roster((r) => r.forEach((s) => (s.state = "running")));
  c.issue("issue-1", (i) => (i.state = { name: "Running", type: "started" }));
  const path = `${c.demo}/.git/night-shift/TST-1.md`;
  if (result !== undefined) {
    mkdirSync(`${c.demo}/.git/night-shift`, { recursive: true });
    writeFileSync(path, `${result}\n`);
  }
  return path;
}

/** The result read and moved aside, once. */
function archived(path: string): boolean {
  const dir = path.slice(0, path.lastIndexOf("/"));
  const base = path.slice(dir.length + 1);
  return !existsSync(path) && readdirSync(dir).filter((n) => n.startsWith(`${base}.`)).length === 1;
}

kase("finish_handoff", "finish: handoff: Handoff ready, archived, waiting, forge let sleep", async (c) => {
  const result = runningAgent(c, ago(), "handoff\nFixed the widget; preflight passes.");
  const wt = c.st().worktree;
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Handoff ready");
  assert.ok(c.comments().includes(`Handoff ready on \`${BRANCH}\`.\n\nFixed the widget; preflight passes.`), c.comments());
  assert.ok(c.comments().includes(`To publish: \`cd ${wt} && pr-handoff\`.`), "the comment says how to publish");
  assert.ok(archived(result), "the result archived");
  assert.equal(c.st().phase, "waiting");
  assert.equal(c.count((l) => l.tool === "ntfy" && l.body === "TST-1: Handoff ready" && l.title === "Night shift"), 1, "a push");
  assert.equal(c.count((l) => l.tool === "bwrap"), 0, "no preflight, with no rules in the repo");
  assert.equal(systemctl(c, "stop"), 1, "forge let sleep, with nothing running");
});

kase("finish_blocked", "finish: blocked: Needs you", async (c) => {
  const result = runningAgent(c, ago(), "blocked\n1. Which widget?");
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes("The agent stopped and needs you.\n\n1. Which widget?"), c.comments());
  assert.ok(archived(result), "the result archived");
  assert.equal(c.st().phase, "waiting");
  assert.equal(pushed(c, "TST-1: Needs you"), 1);
});

kase("finish_quiet", "finish: no result past the stall hours of work: Needs you", async (c) => {
  runningAgent(c, ago(5 * 3600));
  // A minute short of 4 hours of work as of the last run, 5 minutes ago.
  c.st((s) => Object.assign(s, { worked: 4 * 3600 - 60, ticked: ago(300) }));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes("No result after 4 hours of work."), c.comments());
  assert.equal(pushed(c, "TST-1: Went quiet"), 1);
  assert.equal(c.st().phase, "waiting");
});

kase("finish_working", "finish: no result within the stall hours: left alone", async (c) => {
  runningAgent(c, ago(3 * 3600));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Running", "left in Running");
  assert.equal(c.ops("issue").length, 0, "not asked about in Linear");
  assert.equal(c.st().phase, "running");
});

// Started 17 hours ago, at work, and no run since: forge was asleep, and the
// gap counts as one tick, not as 17 hours of silence.
kase("finish_asleep", "finish: hours asleep count as one tick: left alone", async (c) => {
  runningAgent(c, ago(17 * 3600));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Running", "left in Running");
  assert.equal(c.ops("issue").length, 0, "not asked about in Linear");
  assert.equal(c.st().worked, 1200, "20 minutes of work counted");
  assert.equal(systemctl(c, "start"), 1, "forge kept awake");
});

// The clock follows the interval each machine passes: with runs half an
// hour apart, a gap counts up to an hour.
kase("finish_asleep_interval", "finish: the clock follows the interval passed, and refuses a bad one", async (c) => {
  runningAgent(c, ago(17 * 3600));
  assert.equal((await c.ns(["run"], { env: { NIGHT_SHIFT_INTERVAL: "1800" } })).status, 0);
  assert.equal(c.st().worked, 3600, "an hour of work counted");
  const { status, out } = await c.ns(["run"], { env: { NIGHT_SHIFT_INTERVAL: "ten" } });
  assert.equal(status, 1, "a bad interval: exit 1");
  assert.ok(out.includes("NIGHT_SHIFT_INTERVAL is a number of seconds, not 'ten'"), out);
});

// The session ended without a result: left alone on the first look, flagged
// on one 5 minutes or more later.
kase("finish_ended", "finish: session ended with no result: Needs you on the second look", async (c) => {
  runningAgent(c);
  c.roster((r) => r.forEach((s) => (s.state = "done")));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Running", "left in Running at first");
  assert.ok(c.st().ended, "the end noted");
  c.st((s) => (s.ended = ago(600)));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you", "then moved to Needs you");
  assert.ok(c.comments().includes(`The agent's session ended (done) without writing a result. \`claude attach ${NAME}\``), c.comments());
  assert.equal(pushed(c, "TST-1: Went quiet"), 1);
});

// Waiting on a prompt: the same two looks, and says so.
kase("finish_prompt", "finish: session waiting on a prompt: Needs you, saying so", async (c) => {
  runningAgent(c);
  c.roster((r) => r.forEach((s) => (s.state = "blocked")));
  c.st((s) => (s.ended = ago(600)));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes("The agent is waiting on a prompt, with no result."), c.comments());
});

// Seen ended, then missing from the roster: the end seen stands.
kase("finish_roster_gap", "finish: ended, then gone from the roster: the end seen stands", async (c) => {
  runningAgent(c);
  c.roster((r) => r.splice(0));
  c.st((s) => Object.assign(s, { ended: ago(600), ended_as: "done" }));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you");
  assert.ok(c.comments().includes("The agent's session ended (done) without writing a result."), c.comments());
});

// A result after the issue was flagged, as when Nick answers the agent with
// claude attach: taken like any other.
kase("finish_late", "finish: a result after it was flagged: taken", async (c) => {
  const result = runningAgent(c, ago(), "handoff\nFixed the widget after all.");
  c.st((s) => (s.phase = "waiting"));
  c.linear("issue-1", (i) => (i.state = { name: "Needs you", type: "started" }));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Handoff ready");
  assert.ok(c.comments().includes("Fixed the widget after all."), c.comments());
  assert.ok(archived(result), "the result archived");
  assert.equal(c.st().phase, "waiting");
});

// A waiting issue with no result is left alone, though its session has ended
// as one that went quiet does.
kase("finish_waiting", "finish: waiting with no result: left alone", async (c) => {
  runningAgent(c);
  c.roster((r) => r.forEach((s) => (s.state = "done")));
  c.st((s) => Object.assign(s, { phase: "waiting", ended: ago(600) }));
  c.linear("issue-1", (i) => (i.state = { name: "Needs you", type: "started" }));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.stateName(), "Needs you", "left in Needs you");
  assert.equal(c.ops("issue").length, 0, "not asked about in Linear");
});

// Linear unreachable, forge taken off AC with an agent running: the run
// fails, and still lets forge sleep.
kase("awake_offline", "run: Linear down, on battery: fails, forge let sleep", async (c) => {
  runningAgent(c);
  writeFileSync(`${c.dir}/linear-down`, "");
  writeFileSync(`${c.dir}/power/AC/online`, "0\n");
  assert.equal((await c.ns(["run"])).status, 1, "the run fails");
  assert.equal(systemctl(c, "stop"), 1, "forge let sleep anyway");
});

// _finish alone, since run would go on to resume it (the next case).
kase("finish_requeued", "finish: re-queued meanwhile: a comment, left in Queued", async (c) => {
  const result = runningAgent(c, ago(), "handoff\nFixed the widget.");
  c.issue("issue-1");
  assert.equal((await c.ns(["_finish", "user-nick", `${c.state}/TST-1.json`])).status, 0);
  assert.equal(c.stateName(), "Queued", "left in Queued");
  assert.equal(c.ops("issueUpdate").length, 0, "not moved");
  assert.ok(c.comments().includes("Fixed the widget."), c.comments());
  assert.equal(c.count((l) => l.tool === "ntfy"), 0, "no push");
  assert.ok(archived(result), "the result archived");
  assert.equal(c.st().phase, "waiting");
});

const comment = { body: "Use the blue one.", createdAt: "2030-01-01T00:00:00.000Z", user: { id: "user-nick" } };

kase("finish_requeued_resumes", "finish: re-queued meanwhile: run resumes it", async (c) => {
  runningAgent(c, ago(), "handoff\nFixed the widget.");
  c.issue("issue-1", (i) => (i.comments.nodes = [comment]));
  assert.equal((await c.ns(["run"])).status, 0);
  assert.equal(c.count((l) => l.tool === "claude" && l.args?.join(" ") === "stop job-1"), 1, "the finished session stopped first");
  const resumes = c.claude("--bg").filter((l) => l.args![1] === "--resume");
  assert.equal(resumes.length, 1, "resumed once");
  assert.deepEqual(resumes[0]!.args!.slice(0, 3), ["--bg", "--resume", "session-1"]);
  assert.equal(resumes[0]!.args!.length, 4, "with no new flags");
  assert.ok(resumes[0]!.args![3]!.includes("Use the blue one."), "given Nick's comment");
  assert.equal(c.stateName(), "Running");
  assert.equal(c.st().phase, "running");
});

// The roster still calls the session running for two looks after the stop:
// the resume waits for it to say stopped.
kase("finish_requeued_slow_stop", "finish: re-queued, the roster slow to see the stop: resume waits", async (c) => {
  runningAgent(c, ago(), "handoff\nFixed the widget.");
  c.issue("issue-1", (i) => (i.comments.nodes = [comment]));
  writeFileSync(`${c.dir}/stop-slow`, "");
  assert.equal((await c.ns(["run"])).status, 0);
  const calls = c.log().filter((l) => l.tool === "claude");
  const stop = calls.findIndex((l) => l.args![0] === "stop");
  const resume = calls.findIndex((l) => l.args![1] === "--resume");
  assert.ok(stop >= 0 && resume > stop, "resumed after the stop");
  assert.equal(calls.slice(stop, resume).filter((l) => l.args![0] === "agents").length, 3, "three looks between the stop and the resume");
});

// --- 5. _after -----------------------------------------------------------------------

const failing = (c: Case) => c.count((l) => l.tool === "ntfy" && l.title === "Night shift is failing");

kase("after", "_after: a push on the third failure, once, reset by success", async (c) => {
  for (const n of [1, 2, 3, 4]) {
    assert.equal((await c.ns(["_after"], { env: { SERVICE_RESULT: "exit-code", EXIT_STATUS: "1" } })).status, 0);
    assert.equal(c.read("state/night-shift/failed-runs").trim(), String(n), `run ${n}: counted`);
    assert.equal(failing(c), n >= 3 ? 1 : 0, `run ${n}: pushes so far`);
  }
  assert.ok(c.log().find((l) => l.tool === "ntfy")!.body!.includes("The last 3 runs failed, the last with exit-code 1"));
  await c.ns(["_after"], { env: { SERVICE_RESULT: "success" } });
  assert.ok(!existsSync(`${c.state}/failed-runs`), "a success resets the count");
  assert.ok(!existsSync(`${c.state}/failed-runs.pushed`), "and the push");
  for (let n = 0; n < 3; n++) await c.ns(["_after"], { env: { SERVICE_RESULT: "timeout" } });
  assert.equal(failing(c), 2, "three more failures push again");
});

kase("after_push_failed", "_after: a push that failed is tried again", async (c) => {
  writeFileSync(`${c.dir}/ntfy-fail`, "");
  for (let n = 0; n < 3; n++) await c.ns(["_after"], { env: { SERVICE_RESULT: "exit-code" } });
  assert.equal(failing(c), 1, "the third tried to push");
  assert.ok(!existsSync(`${c.state}/failed-runs.pushed`), "not marked pushed");
  rmSync(`${c.dir}/ntfy-fail`);
  await c.ns(["_after"], { env: { SERVICE_RESULT: "exit-code" } });
  assert.equal(failing(c), 2, "the fourth tries again");
  assert.ok(existsSync(`${c.state}/failed-runs.pushed`), "and is marked pushed");
});

// --- 6. tidy -----------------------------------------------------------------------------

kase("tidy_refused", "tidy: GitHub's 403 ends its questions for the run", async (c) => {
  c.repo("demo");
  c.git("-C", c.demo, "remote", "set-url", "origin", "https://github.com/test/demo");
  for (const n of [1, 2]) {
    c.issue(`issue-${n}`, (i) => Object.assign(i, { identifier: `TST-${n}`, state: { name: "Handoff ready", type: "started" } }));
    writeFileSync(`${c.state}/TST-${n}.json`, JSON.stringify({
      id: `issue-${n}`, ident: `TST-${n}`, repo: c.demo, worktree: `${c.demo}/.claude/worktrees/tst-${n}`,
      branch: `worktree-tst-${n}`, name: `tst-${n}`, session: "", phase: "waiting",
      started: "2026-10-12T00:00:00Z", since: "2026-10-12T00:00:00Z",
    }));
  }
  writeFileSync(`${c.dir}/github`, '403\n{"message": "API rate limit exceeded"}\n');
  const { status, out } = await c.ns(["run"]);
  assert.equal(status, 0);
  assert.equal(c.count((l) => l.tool === "github"), 1, "GitHub asked once");
  assert.ok(out.includes("GitHub refused"), out);
  assert.ok(existsSync(`${c.state}/TST-1.json`) && existsSync(`${c.state}/TST-2.json`), "both issues kept");
  assert.equal(c.ops("issueUpdate").length, 0, "neither moved");
});
