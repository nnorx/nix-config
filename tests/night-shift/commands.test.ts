// check, status, file, the snapshots a run writes, a run's preflight brief,
// and its guards on what reaches claude. forge.test.ts and work.test.ts have
// the runs themselves.
import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { type Case, here, kase, script, ts } from "./harness.ts";

// The deployed dispatcher sets NIGHT_SHIFT_TS for the sessions it starts, so a
// run there that took it from the environment would test the store's code.
test("the dispatcher under test is not one from the store", () => {
  for (const p of [script, ts]) assert.ok(!p.startsWith("/nix/store/"), `${p}: unset NIGHT_SHIFT_SCRIPT and NIGHT_SHIFT_TS`);
});

// --- check and status --------------------------------------------------------

kase("check", "check: the key, missing states, repo labels, claude, ntfy", async (c) => {
  c.repo("demo");
  const { status, out } = await c.ns(["check"]);
  assert.equal(status, 0);
  for (const line of [
    "key: works, acting as Test User",
    "team TST: missing states: Running, Handoff ready, Needs you",
    `repo label demo: ${c.dir}/projects/demo`,
    `repo label other: no repository at ${c.dir}/projects/other`,
    "claude: 0.0.0 (night-shift test stub)",
    "ntfy: configured",
  ]) assert.ok(out.includes(line), line);
});

kase("check_offline", "check: Linear down: fails, saying so", async (c) => {
  writeFileSync(`${c.dir}/linear-down`, "");
  const { status, out } = await c.ns(["check"]);
  assert.equal(status, 1);
  assert.match(out, /night-shift: Linear did not answer/);
});

kase("work_check", "work: check: label, state, repository, trust, fields, sandbox, a notification", async (c) => {
  const demo = c.repo("demo");
  writeFileSync(`${c.dir}/config.json`, JSON.stringify({ label: "agent", startedState: "In Progress", repos: { TST: { dir: demo } } }));
  const { status, out } = await c.nsw(["check"]);
  assert.equal(status, 0);
  for (const line of [
    "label agent: not in Linear yet",
    "team TST: no state In Progress",
    `team TST: repository ${demo}`,
    `team TST: run claude in ${demo} once and accept the trust prompt`,
    "issue fields: all known to Linear",
    `sandbox: '${here}/fixtures/work-settings.json' is missing`,
  ]) assert.ok(out.includes(line), line);
  assert.equal(c.log().filter((l) => l.tool === "notify" && l.body === "A test notification from night-shift check").length, 1);
});

kase("status", "status: an agent with its report, and a kept session's settings", async (c) => {
  writeFileSync(`${c.state}/TST-1.json`, JSON.stringify({ ident: "TST-1", phase: "running", started: "2026-11-07T10:00:00Z", name: "tst-1-fix", worktree: "/wt" }));
  writeFileSync(`${c.state}/TST-1.report.md`, "# TST-1: Needs you\n\nSome text.\n");
  writeFileSync(`${c.state}/TST-2.settings`, "");
  const { status, out } = await c.ns(["status"]);
  assert.equal(status, 0);
  assert.ok(out.includes("TST-1  running  since 2026-11-07T10:00:00Z  tst-1-fix  /wt"));
  assert.ok(out.includes("    # TST-1: Needs you\n    \n    Some text."), "its report, indented");
  assert.ok(out.includes("TST-2  merged, but its worktree and session were kept"));
});

kase("status_empty", "status: no state files: nothing yet", async (c) => {
  assert.match((await c.ns(["status"])).out, /^nothing yet$/m);
});

// --- what a session reads Linear by --------------------------------------------

kase("backlog", "backlog: by state then priority, descriptions quoted, done left out", async (c) => {
  c.issue("issue-1", (i) => {
    i.state = { name: "Backlog", type: "backlog" };
    i.description = "## A heading\n\nText.";
  });
  c.issue("issue-2", (i) => {
    i.identifier = "TST-2";
    i.state = { name: "In Progress", type: "started" };
  });
  c.issue("issue-3", (i) => {
    i.identifier = "TST-3";
    i.state = { name: "Done", type: "completed" };
  });
  await c.ns(["file"]);
  const b = readFileSync(`${c.state}/backlog.md`, "utf8");
  assert.match(b, /## In Progress \(1\)\n\n### TST-2: Fix the widget[^]*## Backlog \(1\)\n\n### TST-1: Fix the widget/);
  assert.ok(b.includes("- Priority: Medium. Repo: demo. Project: none. Labels: Bug."));
  assert.ok(b.includes("> ## A heading\n>\n> Text."), "a heading quoted, blank lines too");
  assert.ok(!b.includes("TST-3"), "a done issue left out");
  assert.equal(statSync(`${c.state}/backlog.md`).mode & 0o777, 0o600, "Nick's alone");
});

kase("backlog_fails", "backlog: a failure writing it: reported, the docs still exported, file still succeeds", async (c) => {
  projects(c);
  mkdirSync(`${c.state}/backlog.md`);
  const { status, out } = await c.ns(["file"]);
  assert.equal(status, 0);
  assert.match(out, /backlog\.md not written; the next run will/);
  assert.ok(existsSync(`${c.state}/projects/night-shift/design.md`), "the docs exported anyway");
});

function projects(c: Case): void {
  writeFileSync(`${c.dir}/linear/projects.json`, JSON.stringify([
    { id: "project-1", name: "Night shift", status: { type: "started" }, documents: [{ id: "doc-1", title: "Design",
      content: "# Design\n\nThe old text.", updatedAt: "2026-11-01T09:00:00.000Z", url: "https://linear.app/test/document/design" }] },
    { id: "project-2", name: "Old work", status: { type: "completed" }, documents: [{ id: "doc-2", title: "Notes",
      content: "Done.", updatedAt: "2026-10-01T09:00:00.000Z", url: "https://linear.app/test/document/notes" }] },
  ]));
}

kase("docs_export", "docs: each open project's documents exported as drafts", async (c) => {
  projects(c);
  await c.ns(["file"]);
  assert.equal(readFileSync(`${c.state}/projects/night-shift/design.md`, "utf8"),
    "---\nproject: Night shift\ndoc: Design\nupdated: 2026-11-01T09:00:00.000Z\n---\n\n# Design\n\nThe old text.\n");
  assert.ok(!existsSync(`${c.state}/projects/old-work`), "a completed project left out");
});

kase("docs_quoted_title", "docs: a title in quotes exported so it reads back the same", async (c) => {
  c.repo("demo");
  projects(c);
  const p = JSON.parse(readFileSync(`${c.dir}/linear/projects.json`, "utf8"));
  p[0].documents[0].title = '"Design"';
  writeFileSync(`${c.dir}/linear/projects.json`, JSON.stringify(p));
  await c.ns(["file"]);
  mkdirSync(c.handoff, { recursive: true });
  writeFileSync(`${c.handoff}/design.md`,
    readFileSync(`${c.state}/projects/night-shift/design.md`, "utf8").replace("The old text.", "The new text."));
  const { out } = await c.ns(["file"]);
  assert.ok(out.includes("doc · Night shift · update"), "the same doc, not a new one");
});

// --- file ------------------------------------------------------------------------

/** Repo demo with a draft that is fine, beside whatever a case adds. */
function drafts(c: Case): void {
  c.repo("demo");
  mkdirSync(c.handoff, { recursive: true });
  copyFileSync(`${here}/drafts/good.md`, `${c.handoff}/good.md`);
}

async function refused(c: Case, file: string, why: string): Promise<void> {
  const { status, out } = await c.ns(["file"]);
  assert.equal(status, 1);
  assert.ok(out.includes("nothing filed"));
  assert.ok(out.includes(`${c.handoff}/${file}: ${why}`), why);
  assert.deepEqual([...c.ops("issueCreate"), ...c.ops("documentCreate"), ...c.ops("documentUpdate")], [], "nothing filed");
  assert.ok(existsSync(`${c.handoff}/good.md`) && existsSync(`${c.handoff}/${file}`), "both drafts kept");
}

kase("file_unknown_key", "file: an unknown key: nothing filed", async (c) => {
  drafts(c);
  copyFileSync(`${here}/drafts/unknown-key.md`, `${c.handoff}/unknown-key.md`);
  await refused(c, "unknown-key.md", "unknown key 'assignee'");
});

kase("file_control", "file: a control character: nothing filed", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/control.md`, "---\ntitle: forge: a control character\n---\n\nA bell \x07 in the text.\n");
  await refused(c, "control.md", "contains control or invisible characters");
});

kase("file_invisible", "file: a zero-width space: nothing filed", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/invisible.md`, "---\ntitle: forge: an invisible character\n---\n\nA zero-width\u200bspace.\n");
  await refused(c, "invisible.md", "contains control or invisible characters (U+200B on line 5)");
});

kase("file_bom", "file: a byte order mark: nothing filed", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/bom.md`, "\ufeff---\ntitle: forge: a byte order mark\n---\n\nText.\n");
  await refused(c, "bom.md", "contains control or invisible characters (U+FEFF on line 1)");
});

kase("file_priority_prototype", "file: a priority named after an object property: nothing filed", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/proto.md`, "---\ntitle: forge: a priority\npriority: constructor\n---\n\nText.\n");
  await refused(c, "proto.md", "priority is urgent, high, medium, low or none");
});

kase("file_no_title", "file: no title: nothing filed", async (c) => {
  drafts(c);
  copyFileSync(`${here}/drafts/no-title.md`, `${c.handoff}/no-title.md`);
  await refused(c, "no-title.md", "no title");
});

kase("work_file", "work: file is refused", async (c) => {
  const { status, out } = await c.nsw(["file"]);
  assert.equal(status, 1);
  assert.match(out, /file is forge's/);
});

kase("file_interactive", "file: a terminal answers y, then n: one filed, one kept", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/later.md`,
    readFileSync(`${here}/drafts/good.md`, "utf8").replace(/^title: .*$/m, "title: forge: a later change"));
  const { status, out } = await c.ns(["file"], { tty: "y\nn\n" });
  assert.equal(status, 0);
  assert.ok(out.includes("TST · demo · high · Night shift · into Backlog"));
  assert.deepEqual(c.ops("issueCreate").map((l) => l.variables.i), [{
    teamId: "team-1", title: "forge: make the widget faster", priority: 2,
    description: "The widget takes a second to draw. Make it take less.\n\n_Filed from a draft with `night-shift file`._",
    labelIds: ["label-demo"], stateId: "state-backlog", projectId: "project-1",
  }]);
  assert.ok(!existsSync(`${c.handoff}/good.md`) && !existsSync(`${c.handoff}/good.filing`), "the filed draft gone");
  assert.ok(existsSync(`${c.handoff}/later.md`), "the declined draft kept");
  assert.match(out, /filed TST-99/);
  assert.match(out, /filed 1 of 2/);
  assert.equal(c.ops("labels").length, 0, "no labels query without a labels: line");
  assert.ok(existsSync(`${c.state}/backlog.md`), "then writes the backlog");
}, true);

kase("file_labels", "file: labels: shown, and sent after the repo label", async (c) => {
  drafts(c);
  writeFileSync(`${c.handoff}/good.md`,
    readFileSync(`${here}/drafts/good.md`, "utf8").replace("priority: high", "priority: high\nlabels: Hands on"));
  const { status, out } = await c.ns(["file"], { tty: "y\n" });
  assert.equal(status, 0);
  assert.ok(out.includes("TST · demo · high · Night shift · labels Hands on · into Backlog"), out);
  assert.deepEqual(c.ops("issueCreate").map((l) => l.variables.i.labelIds), [["label-demo", "label-hands-on"]]);
  assert.equal(c.ops("labels").length, 1, "the labels in a query of their own");
}, true);

for (const [name, label, why] of [
  ["unknown", "Elsewhere", "no label 'Elsewhere' for team TST"],
  ["ambiguous", "Bug", "more than one label 'Bug' for team TST"],
  ["repo", "demo", "'demo' is a repo label; name the repository with repo:"],
]) {
  kase(`file_label_${name}`, `file: a label, ${name}: nothing filed`, async (c) => {
    drafts(c);
    writeFileSync(`${c.handoff}/labelled.md`, `---\ntitle: forge: a label\nlabels: Hands on, ${label}\n---\n\nText.\n`);
    await refused(c, "labelled.md", why!);
  });
}

kase("file_doc_update", "file: a doc edited from its export: the change shown, the doc updated", async (c) => {
  c.repo("demo");
  projects(c);
  await c.ns(["file"]);
  mkdirSync(c.handoff, { recursive: true });
  writeFileSync(`${c.handoff}/design.md`,
    readFileSync(`${c.state}/projects/night-shift/design.md`, "utf8").replace("The old text.", "The new text."));
  const { status, out } = await c.ns(["file"], { tty: "y\n" });
  assert.equal(status, 0);
  assert.ok(out.includes("doc · Night shift · update"));
  assert.ok(out.includes("-The old text.") && out.includes("+The new text."), "the change shown");
  assert.deepEqual(c.ops("documentUpdate").map((l) => l.variables), [{ id: "doc-1", i: { content: "# Design\n\nThe new text." } }]);
  assert.ok(out.includes("filed doc 'Design'  https://linear.app/test/document/design"));
  assert.ok(!existsSync(`${c.handoff}/design.md`), "the draft gone");
}, true);

kase("file_doc_fresh_export", "file: Linear's list lags the write: the export still has the doc as filed", async (c) => {
  c.repo("demo");
  projects(c);
  writeFileSync(`${c.dir}/linear/lag`, "");
  await c.ns(["file"]);
  mkdirSync(c.handoff, { recursive: true });
  writeFileSync(`${c.handoff}/design.md`,
    readFileSync(`${c.state}/projects/night-shift/design.md`, "utf8").replace("The old text.", "The new text."));
  writeFileSync(`${c.handoff}/decisions.md`, "---\nproject: Night shift\ndoc: Decisions\n---\n\nWhat was decided.\n");
  assert.equal((await c.ns(["file"], { tty: "y\ny\n" })).status, 0);
  const design = readFileSync(`${c.state}/projects/night-shift/design.md`, "utf8");
  assert.ok(design.includes("updated: 2026-11-07T12:00:00.000Z") && design.includes("The new text."), "the update exported");
  assert.ok(existsSync(`${c.state}/projects/night-shift/decisions.md`), "the new doc exported");
}, true);

kase("file_doc_stale", "file: a doc changed in Linear since its export: nothing filed", async (c) => {
  drafts(c);
  projects(c);
  writeFileSync(`${c.handoff}/stale.md`, "---\nproject: Night shift\ndoc: Design\nupdated: 2026-10-01T00:00:00.000Z\n---\n\nAn edit of an old export.\n");
  await refused(c, "stale.md", "'Design' changed in Linear at 2026-11-01T09:00:00.000Z, after the export this draft is from (2026-10-01T00:00:00.000Z)");
});

kase("file_doc_new", "file: a doc that is not there yet: created in the project", async (c) => {
  drafts(c);
  projects(c);
  writeFileSync(`${c.handoff}/decisions.md`, "---\nproject: Night shift\ndoc: Decisions\n---\n\nWhat was decided.\n");
  const { status, out } = await c.ns(["file"], { tty: "y\nn\n" });
  assert.equal(status, 0);
  assert.ok(out.includes("doc · Night shift · new"));
  assert.deepEqual(c.ops("documentCreate").map((l) => l.variables), [{ i: { projectId: "project-1", title: "Decisions", content: "What was decided." } }]);
}, true);

kase("file_doc_keys", "file: a doc draft with an issue's key: nothing filed", async (c) => {
  drafts(c);
  projects(c);
  writeFileSync(`${c.handoff}/mixed.md`, "---\nproject: Night shift\ndoc: Design\npriority: high\n---\n\nText.\n");
  await refused(c, "mixed.md", "a doc draft takes project, doc and updated, not priority");
});

kase("file_no_backlog", "file: a team with no backlog state: into the first not-started state, never Queued", async (c) => {
  drafts(c);
  const ws = JSON.parse(readFileSync(`${c.dir}/linear/workspace.json`, "utf8"));
  const team = ws.data.teams.nodes[0];
  team.states.nodes = team.states.nodes.filter((s: { type: string }) => s.type !== "backlog");
  team.states.nodes.find((s: { name: string }) => s.name === "Queued").position = 0;
  writeFileSync(`${c.dir}/linear/workspace.json`, JSON.stringify(ws));
  const { out } = await c.ns(["file"]);
  assert.ok(out.includes("· into Todo"), "into Todo");
  assert.ok(!out.includes("· into Queued"), "never Queued");
});

// --- a run's brief -----------------------------------------------------------------
// forge.test.ts has the rest of a run in forge mode; these are the cases on a
// repo with preflight, whose brief a handoff's comment carries.

const BRANCH = "worktree-tst-1-fix-the-widget";

/** An agent on TST-1 that handed off, by default in a repo with preflight's rules. */
function handedOff(c: Case, preflight = true): { repo: string; wt: string } {
  const repo = c.repo("demo");
  if (preflight) {
    mkdirSync(`${repo}/scripts`);
    writeFileSync(`${repo}/scripts/preflight-brief.jq`, "");
  }
  const wt = `${repo}/.claude/worktrees/tst-1-fix-the-widget`;
  c.git("-C", repo, "worktree", "add", "-q", "--no-track", "-b", BRANCH, wt, "origin/main");
  writeFileSync(`${c.state}/TST-1.json`, JSON.stringify({ id: "issue-1", ident: "TST-1", repo, worktree: wt, branch: BRANCH,
    name: "tst-1-fix-the-widget", session: "session-1", phase: "running", started: now(), since: now() }));
  writeFileSync(`${c.dir}/roster.json`, JSON.stringify([{ id: "job-1", sessionId: "session-1", name: "tst-1-fix-the-widget", cwd: wt, state: "done" }]));
  mkdirSync(`${repo}/.git/night-shift`);
  writeFileSync(`${repo}/.git/night-shift/TST-1.md`, "handoff\nFixed the widget.\n");
  c.issue("issue-1", (i) => (i.state = { name: "Running", type: "started" }));
  return { repo, wt };
}

const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const comments = (c: Case) => JSON.parse(readFileSync(`${c.dir}/linear/issues/issue-1.json`, "utf8")).comments.nodes.map((n: any) => n.body).join("\n");
const pushed = (c: Case) => c.log().filter((l) => l.tool === "ntfy").map((l) => l.body);

kase("run_brief", "run: a handoff in a repo with preflight: its verdict and findings, notes left out, preflight confined", async (c) => {
  const { repo } = handedOff(c);
  writeFileSync(`${c.dir}/brief.json`, JSON.stringify({
    verdict: { level: "review", text: "One host changes." },
    hosts: { gate: { findings: [{ level: "review", text: "its firewall changes" }, { level: "note", text: "its revision moves" }] } },
    plan: [{ level: "review", text: "merge by day" }],
  }));
  mkdirSync(`${c.dir}/secret-dir`);
  writeFileSync(`${c.dir}/home/token-a`, "");
  const { status } = await c.ns(["run"], { env: { NIGHT_SHIFT_HIDE: `${c.dir}/secret-dir\n~/token-*\n${c.dir}/absent` } });
  assert.equal(status, 0);
  const text = comments(c);
  assert.ok(text.includes("Fixed the widget.\n\n**Preflight: review.** One host changes.\n- gate, review: its firewall changes\n- review: merge by day\n\nTo publish:"), text);
  assert.ok(!text.includes("its revision moves"), "notes left out");
  assert.deepEqual(pushed(c), ["TST-1: Handoff ready (review)"]);
  const bwrap = c.log().find((l) => l.tool === "bwrap")!;
  const args = bwrap.args!.join(" ");
  assert.ok(args.startsWith(`--dev-bind / / --tmpfs ${c.dir}/secret-dir --ro-bind /dev/null ${c.dir}/home/token-a -- nix run .#preflight -- --head ${BRANCH} --json `), args);
  assert.equal(c.log().find((l) => l.tool === "nix")!.cwd, repo, "in the repo, on the agent's branch");
});

kase("run_brief_fails", "run: preflight fails on the branch: the comment says so and how to see why", async (c) => {
  handedOff(c);
  const { status } = await c.ns(["run"]);
  assert.equal(status, 0);
  assert.ok(comments(c).includes(`**Preflight failed** on this branch. Run \`nix run .#preflight -- --head ${BRANCH}\` to see why.`));
  assert.deepEqual(pushed(c), ["TST-1: Handoff ready"]);
});

// --- a run's guards on what reaches claude -------------------------------------------

kase("run_prompt_verbatim", "run: the task reaches claude as written, ${...} unexpanded, and the key in no child's reach", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => (i.description = "Use ${HOME} and ${{ github.ref }} as written."));
  const { status } = await c.ns(["run"]);
  assert.equal(status, 0);
  const scope = c.log().find((l) => l.tool === "systemd-run" && l.args!.includes("--bg"))!;
  const own = scope.args!.slice(0, scope.args!.indexOf("--"));
  assert.ok(own.includes("--expand-environment=no"), `systemd-run told not to expand: ${own.join(" ")}`);
  const bg = c.log().find((l) => l.tool === "claude" && l.args![0] === "--bg")!;
  assert.ok(bg.args![5]!.includes("Use ${HOME} and ${{ github.ref }} as written."), "the prompt as Nick wrote it");
  assert.ok(!existsSync(`${c.dir}/key-seen`), "no claude call had the key in its environment");
  assert.ok(!c.log().some((l) => l.args?.some((a) => a.includes("test-key"))), "nor in its arguments");
});

kase("run_resume_copy", "run: a resume that starts a copy: the copy stopped, Needs you, the original named", async (c) => {
  handedOff(c, false);
  c.issue("issue-1", (i) => (i.comments.nodes = [{ body: "Use the blue one.", createdAt: "2030-01-01T00:00:00.000Z", user: { id: "user-nick" } }]));
  writeFileSync(`${c.dir}/resume-copy`, "abc123");
  const { status } = await c.ns(["run"]);
  assert.equal(status, 0);
  assert.ok(c.log().some((l) => l.tool === "claude" && l.args?.join(" ") === "stop abc123"), "the copy stopped");
  assert.equal(JSON.parse(readFileSync(`${c.dir}/linear/issues/issue-1.json`, "utf8")).state.name, "Needs you");
  assert.ok(comments(c).includes("Not resumed: claude started a copy (abc123) instead of continuing the session, and the copy was stopped. `claude attach job-1` opens the original."));
  assert.ok(pushed(c).includes("TST-1: Did not resume"));
  assert.equal(JSON.parse(readFileSync(`${c.state}/TST-1.json`, "utf8")).phase, "waiting", "not counted as running");
});

// --- what a run refuses before it starts anything ------------------------------------

kase("run_tie", "run: two moves into Queued at the same moment: the later in Linear's list decides, as jq's max_by did", async (c) => {
  c.repo("demo");
  c.issue("issue-1", (i) => {
    const at = "2026-10-02T10:00:00.000Z";
    i.history.nodes = [{ createdAt: at, actorId: "user-nick", toState: { name: "Queued" } }, { createdAt: at, actorId: "user-sync", toState: { name: "Queued" } }];
  });
  await c.ns(["run"]);
  assert.equal(JSON.parse(readFileSync(`${c.dir}/linear/issues/issue-1.json`, "utf8")).state.name, "Needs you");
  assert.ok(comments(c).includes("Not started: only issues you move to Queued yourself are taken."));
});

kase("run_bad_max", "run: a limit that is not a whole number: fails, saying so, and starts nothing", async (c) => {
  c.repo("demo");
  c.issue("issue-1");
  const { status, out } = await c.ns(["run"], { env: { NIGHT_SHIFT_MAX: "abc" } });
  assert.equal(status, 1);
  assert.match(out, /NIGHT_SHIFT_MAX is a whole number, not 'abc'/);
  assert.ok(!c.log().some((l) => l.tool === "claude" && l.args?.[0] === "--bg"), "no agent started");
});

kase("work_bootstrap_string", "work: a bootstrap that is one string, not a list: fails, saying so", async (c) => {
  writeFileSync(`${c.dir}/config.json`, JSON.stringify({ repos: { TST: { dir: c.repo("demo"), bootstrap: "pnpm install" } } }));
  const { status, out } = await c.nsw(["run"]);
  assert.equal(status, 1);
  assert.match(out, /repos\.TST\.bootstrap in .* is a list of commands/);
});
