// Publishes a PR that Claude Code prepared but cannot push, and squash-merges
// it. See home/pr-handoff.nix.

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname } from "node:path";
import { die, Exit, Fatal, maybe, must, mustShow, onPath, page, say, shown, tryRun, Tty } from "./proc.ts";
import { type Handoff, lfsconfigMoved, plain, readHandoff, show, showCommits, watched } from "./review.ts";

const USAGE = `usage: pr-handoff [--base <branch>] [--force-with-lease]
           push this branch and open its PR, or update the open one
       pr-handoff merge <number>
           squash-merge a PR with its prepared message, then delete the branch
       pr-handoff gitlens [<base>]
           open what this branch adds since it left <base>, the default
           branch unless given, in GitLens
`;

class Usage extends Error {}

const short = (sha: string) => sha.slice(0, 7);

/**
 * Yes or no. `d` pages through the change in full before asking again, and
 * `g` opens it in GitLens, where it is easier to move between files. The
 * summary above the question is enough for a docs fix, not for code going
 * out under Nick's name.
 */
async function confirm(question: string, into: string, tip: string, diff: string[]): Promise<boolean> {
  // PR_HANDOFF_TTY is for tests/pr-handoff/run.sh.
  const tty = Tty.open(process.env.PR_HANDOFF_TTY || "/dev/tty");
  if (!tty) return false;
  try {
    for (;;) {
      process.stdout.write(`${question} [y/N/d=diff/g=GitLens] `);
      const reply = tty.line();
      if (reply === undefined) return false;
      if (/^(y|yes)$/i.test(reply)) return true;
      if (/^d$/i.test(reply)) await page(diff);
      else if (/^g$/i.test(reply)) gitlens(into, tip);
      else return false;
    }
  } finally {
    tty.close();
  }
}

/**
 * Opens what head adds since it left origin/<base> in GitLens's Search &
 * Compare view, in the VS Code window already open, through the extension's
 * own link format. The left side is the merge base, so this is the PR's
 * three-dot diff. path= names the main checkout, which GitLens matches before
 * anything else; a worktree shares its refs, so the comparison is the same
 * from either. Returns rather than dies: at a prompt, a failure here should
 * not abandon the publish or merge.
 */
function gitlens(base: string, head: string): boolean {
  if (!onPath("code")) {
    process.stderr.write("pr-handoff: no code on PATH to open GitLens with\n");
    return false;
  }
  if (tryRun("git", ["fetch", "--quiet", "origin", base]).status !== 0) return false;
  // A PR's head may exist only on GitHub, when merging from another clone.
  const have = tryRun("git", ["cat-file", "-e", `${head}^{commit}`], { stdio: "ignore" }).status === 0;
  if (!have && tryRun("git", ["fetch", "--quiet", "origin", head]).status !== 0) return false;
  const from = maybe("git", "merge-base", `origin/${base}`, head);
  const to = maybe("git", "rev-parse", `${head}^{commit}`);
  const common = maybe("git", "rev-parse", "--path-format=absolute", "--git-common-dir");
  if (!from || !to || !common) return false;
  const r = tryRun("code", ["--open-url", `vscode://eamodio.gitlens/link/r/-/compare/${from}...${to}?path=${dirname(common)}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  // forge's code passes Wayland flags that its CLI warns about on every call.
  const said = `${r.stdout}${(r as { stderr?: Buffer }).stderr ?? ""}`.split("\n");
  const kept = said.filter((l) => l && !l.includes("is not in the list of known options"));
  if (kept.length) process.stderr.write(`${kept.join("\n")}\n`);
  return true;
}

/**
 * As origin answers, never refs/remotes/origin/HEAD: the shared refs are the
 * sandbox's to write, from any checkout. GitHub's API if origin names none.
 */
function defaultBranch(): string {
  const said = maybe("git", "ls-remote", "--symref", "origin", "HEAD") ?? "";
  const ref =
    /^ref: refs\/heads\/(\S*)\s*HEAD$/m.exec(said)?.[1] ||
    maybe("gh", "repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name");
  return ref || die("neither origin nor GitHub names a default branch");
}

/** The commit origin has branch at, from origin, or "". */
function remoteHead(branch: string): string {
  const r = tryRun("git", ["ls-remote", "origin", `refs/heads/${branch}`]);
  if (r.status !== 0) die(`could not ask origin for ${branch}`);
  for (const line of r.stdout.toString("utf8").split("\n")) {
    const [sha, ref] = line.split(/\s+/);
    if (ref === `refs/heads/${branch}`) return sha!;
  }
  return "";
}

function withBody<T>(h: Handoff, use: (file: string) => T): T {
  const tmp = mkdtempSync(`${tmpdir()}/pr-handoff.`);
  try {
    writeFileSync(`${tmp}/body`, h.body);
    return use(`${tmp}/body`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

async function publish(dir: string, args: string[]): Promise<void> {
  let base = "";
  let force = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--base" && i + 1 < args.length) base = args[++i]!;
    else if (args[i] === "--force-with-lease") force = true;
    else throw new Usage();
  }

  const branch = maybe("git", "symbolic-ref", "--quiet", "--short", "HEAD") || die("not on a branch");
  const fallback = defaultBranch();
  if (branch === fallback) die(`on ${branch}; publish from a feature branch`);
  const h = readHandoff(dir, `${dir}/${branch}.md`);

  // gh finds the newest PR from this branch, which may be closed or merged.
  const info = tryRun("gh", ["pr", "view", branch, "--json", "number,state,baseRefName", "-q", '"\\(.number) \\(.state) \\(.baseRefName)"'], {
    stdio: ["ignore", "pipe", "ignore"],
  });
  const [number = "", state = "", prBase = ""] = info.status === 0 ? info.stdout.toString("utf8").trim().split(/\s+/) : [];
  let action: string;
  let pr = "";
  if (state === "OPEN") {
    action = `update #${number}`;
    if (base && base !== prBase) die(`#${number} is based on ${prBase}, not ${base}; change that on GitHub`);
    base = prBase;
    pr = number;
  } else {
    action = "open a PR";
    base ||= fallback;
  }

  must("git", "fetch", "--quiet", "origin", base);
  // The commits the review is of, and those pushed, fixed here: an agent
  // still at work could commit or move refs while the question waits, and
  // that must not go out unread, as `merge` holds GitHub to its head. The
  // base and the lease are origin's answers, not refs here.
  const baseSha = remoteHead(base);
  if (!baseSha || tryRun("git", ["cat-file", "-e", `${baseSha}^{commit}`]).status !== 0) {
    die(`origin has no ${base}, or its head did not fetch`);
  }
  const held = force ? remoteHead(branch) : "";
  const tip = must("git", "rev-parse", "HEAD").trim();
  if (Number(must("git", "rev-list", "--count", `${baseSha}..${tip}`)) === 0) {
    die(`${branch} has no commits beyond origin's ${base}`);
  }
  for (const c of must("git", "rev-list", `${baseSha}..${tip}`).split("\n").filter(Boolean)) {
    plain(`commit ${short(c)}'s message`, tryRun("git", ["show", "-s", "--format=%B", c]).stdout);
  }

  say(`Branch: ${branch} -> ${base} at ${short(baseSha)} (${action})`);
  mustShow("git", "log", "--oneline", `${baseSha}..${tip}`);
  say(must("git", "diff", "--stat", `${baseSha}...${tip}`).trimEnd().split("\n").at(-1));
  if (must("git", "status", "--porcelain", "--untracked-files=no").trim()) {
    say("!! Uncommitted changes, which will not be pushed.");
  }
  if (lfsconfigMoved(baseSha)) {
    die(`the .lfsconfig here is not ${base}'s, and it decides where LFS objects are pushed; read it, and remove it or publish by hand`);
  }
  // Shown before the question, so a review starts there.
  const touched = watched(`${baseSha}...${tip}`);
  if (touched.length) {
    say("!! The branch changes files that run code on this machine; read these first:");
    for (const path of touched) say(`     ${path}`);
  }
  show(h);
  showCommits(`${baseSha}..${tip}`);
  if (!(await confirm(`Push ${branch} and ${action}?`, base, tip, ["git", "diff", `${baseSha}...${tip}`]))) {
    die("nothing published");
  }

  const now = must("git", "rev-parse", "HEAD").trim();
  if (now !== tip) {
    die(`nothing published: ${branch} moved from ${short(tip)} to ${short(now)} during the review.`,
      "Run pr-handoff again to review the new head.");
  }

  // With hooks off, the pre-push hook that uploads a repository's LFS objects
  // does not run, so this does. The .lfsconfig is checked again first: one
  // left during the review would otherwise choose where they go.
  const lfs = tryRun("git", ["lfs", "env"], { stdio: "ignore" }).status === 0 &&
    tryRun("git", ["grep", "-q", "-e", "filter=lfs", tip, "--", ":(top,glob)**/.gitattributes"]).status === 0;
  if (lfs) {
    if (lfsconfigMoved(baseSha)) die(`nothing published: an .lfsconfig that is not ${base}'s appeared during the review`);
    mustShow("git", "lfs", "push", "origin", tip);
  }
  // By commit, not by name, so nothing that lands on the branch now goes too.
  // A push sets no upstream for a commit, so that is set after. With no
  // branch on origin, there is nothing to lease.
  mustShow("git", "push", ...(held ? [`--force-with-lease=refs/heads/${branch}:${held}`] : []), "origin", `${tip}:refs/heads/${branch}`);
  shown("git", "branch", "--quiet", "--set-upstream-to", `origin/${branch}`, branch);
  withBody(h, (body) => {
    if (pr) {
      must("gh", "pr", "edit", pr, "--title", h.head, "--body-file", body);
      mustShow("gh", "pr", "view", pr, "--json", "url", "-q", ".url");
    } else {
      mustShow("gh", "pr", "create", "--base", base, "--head", branch, "--title", h.head, "--body-file", body);
    }
  });
}

async function merge(dir: string, args: string[]): Promise<void> {
  const n = args[0];
  if (args.length !== 1 || !/^[0-9]+$/.test(n!)) throw new Usage();
  const info = must("gh", "pr", "view", n!, "--json", "state,headRefName,baseRefName,headRefOid",
    "-q", '"\\(.state) \\(.headRefName) \\(.baseRefName) \\(.headRefOid)"');
  const [state = "", branch = "", base = "", tip = ""] = info.trim().split(/\s+/);
  if (state !== "OPEN") die(`#${n} is ${state}`);
  const h = readHandoff(dir, `${dir}/${branch}.squash.md`);
  if (!h.head.endsWith(`(#${n})`)) h.head = `${h.head} (#${n})`;

  say(`PR: #${n} ${branch} -> ${base}`);
  if (shown("gh", "pr", "checks", n!) !== 0) say("!! Not every check has passed.");
  show(h);
  // GitHub's diff of the PR, which is what merges, whatever is checked out here.
  if (!(await confirm(`Squash-merge #${n} into ${base} and delete ${branch}?`, base, tip, ["gh", "pr", "diff", n!]))) {
    die("nothing merged");
  }

  // Only the head read above, which the review was of. Merging deploys the
  // Pis that night, so a push to the branch since then must not ride along.
  const merged = withBody(h, (body) =>
    shown("gh", "pr", "merge", n!, "--squash", "--delete-branch", "--match-head-commit", tip,
      "--subject", h.head, "--body-file", body) === 0);
  if (!merged) {
    const now = maybe("gh", "pr", "view", n!, "--json", "headRefOid", "-q", ".headRefOid") || tip;
    if (now !== tip) {
      die(`nothing merged: ${branch} moved from ${short(tip)} to ${short(now)} during the review.`,
        `Run pr-handoff merge ${n} again to review the new head.`);
    }
    die("nothing merged");
  }
  rmSync(`${dir}/${branch}.md`, { force: true });
  rmSync(`${dir}/${branch}.squash.md`, { force: true });
}

async function main(argv: string[]): Promise<void> {
  // The review prints straight to the terminal. A pager would stop it halfway.
  process.env.GIT_PAGER = "cat";
  process.env.GH_PAGER = "cat";
  // No git hook runs, for any command here, git's or gh's: every checkout is
  // written by agents too, and its hooks would run with Nick's login. `git
  // push --no-verify` would skip only pre-push. CI runs the checks hooks
  // would. forge empties hooksPath for every repository (home/claude.nix);
  // this covers the Mac.
  const n = Number(process.env.GIT_CONFIG_COUNT ?? 0);
  process.env[`GIT_CONFIG_KEY_${n}`] = "core.hooksPath";
  process.env[`GIT_CONFIG_VALUE_${n}`] = "/dev/null";
  process.env.GIT_CONFIG_COUNT = String(n + 1);

  const [cmd, ...rest] = argv;
  if (cmd === "-h" || cmd === "--help") throw new Usage();
  if (cmd === "gitlens") {
    if (rest.length > 1) throw new Usage();
    if (!gitlens(rest[0] ?? defaultBranch(), "HEAD")) throw new Exit(1);
    return;
  }
  // Under the common dir, so every worktree shares one place and nothing here
  // is ever committed. Commands in Claude's sandbox can write there.
  const dir = `${must("git", "rev-parse", "--path-format=absolute", "--git-common-dir").trim()}/pr-handoff`;
  if (cmd === "merge") await merge(dir, rest);
  else await publish(dir, argv);
}

try {
  await main(process.argv.slice(2));
} catch (e) {
  if (e instanceof Usage) {
    process.stderr.write(USAGE);
    process.exitCode = 64;
  } else if (e instanceof Fatal) {
    process.stderr.write(`pr-handoff: ${e.message}\n`);
    process.exitCode = 1;
  } else if (e instanceof Exit) {
    process.exitCode = e.status;
  } else {
    throw e;
  }
}
