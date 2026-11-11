// What every case has to hand. A case starts from an empty directory of its
// own: HOME, the state directory, projects, a Linear key and ntfy topic, a git
// config, and power supplies that say it is on AC. The dispatcher runs there
// through night-shift.sh, as the timer runs it, with an environment of the
// case's own. The stubs under stubs/ come first on PATH, as claude,
// systemd-run, bwrap, systemctl and nix, and for work mode osascript, gh,
// caffeinate and launchctl; everything else is real, git included. http.ts
// serves Linear, GitHub and ntfy on loopback, each request answered by
// stubs/curl. Nothing reaches the network, the real claude, or Nick's own
// state directory.
//
// The dispatcher acts as Nick in Linear and deletes worktrees, branches and
// sessions; each guard on that was checked once, by hand or in a live run,
// and the cases check them again on every change. NIGHT_SHIFT_SCRIPT and
// NIGHT_SHIFT_TS name what is under test, by default this checkout's, so a
// guard can be broken in a scratch copy to see its case fail.
// NIGHT_SHIFT_TESTS_KEEP=1 keeps every case's directory and its log.jsonl.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, test } from "node:test";

export const here = import.meta.dirname;
const root = resolve(here, "../..");
const script = resolve(process.env.NIGHT_SHIFT_SCRIPT ?? `${root}/pkgs/night-shift/night-shift.sh`);
const ts = resolve(process.env.NIGHT_SHIFT_TS ?? `${root}/pkgs/night-shift/src/main.ts`);
const bash = process.env.NIGHT_SHIFT_BASH ?? "bash";

const work = mkdtempSync(join(tmpdir(), "night-shift-ts."));
if (process.env.NIGHT_SHIFT_TESTS_KEEP) process.stderr.write(`night-shift tests: keeping ${work}\n`);
const bin = `${work}/bin`;
mkdirSync(bin);
const stubs: [string, string, string?][] = [
  ["claude", "claude"], ["systemctl", "systemctl"], ["nix", "nix"], ["osascript", "osascript"], ["gh", "gh"],
  ["caffeinate", "caffeinate"], ["launchctl", "launchctl"], ["systemd-run", "scope", "systemd-run"], ["bwrap", "scope", "bwrap"],
];
for (const [tool, stub, as] of stubs) {
  const env = as ? `export NS_STUB=${as}; ` : "";
  writeFileSync(`${bin}/${tool}`, `#!${bash}\n${env}exec ${bash} -euo pipefail ${here}/stubs/${stub} "$@"\n`);
  chmodSync(`${bin}/${tool}`, 0o755);
}
const path = `${bin}:${process.env.PATH}`;

const server = spawn("node", [`${here}/http.ts`, work, `${here}/stubs/curl`, bash, `${work}/port`], {
  stdio: "inherit",
  env: { ...process.env, PATH: path },
});
let port = "";
for (let i = 0; i < 100 && !port; i++) {
  await new Promise((r) => setTimeout(r, 50));
  try {
    port = readFileSync(`${work}/port`, "utf8");
  } catch {
    // Not listening yet.
  }
}
if (!port) throw new Error("http.ts did not start");

after(() => {
  server.kill();
  if (!process.env.NIGHT_SHIFT_TESTS_KEEP) rmSync(work, { recursive: true, force: true });
});

export const hasTty = spawnSync("script", ["--version"], { encoding: "utf8" }).stdout?.includes("util-linux");

/** A case of its own, failing on any request the stubs do not know or find too complex. */
export function kase(name: string, what: string, body: (c: Case) => Promise<void>, tty = false): void {
  test(what, { skip: tty && !hasTty && "no util-linux script" }, async () => {
    const c = new Case(name);
    await body(c);
    assert.deepEqual(c.unknown(), [], "no request the stubs do not know, nor one too complex");
  });
}

/** UTC to the second, `seconds` ago, as the dispatcher writes times. */
export const ago = (seconds = 0) => new Date(Date.now() - seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

export interface Logged {
  tool: string;
  op?: string;
  args?: string[];
  cwd?: string;
  url?: string;
  variables?: any;
  title?: string;
  body?: string;
  script?: string[];
  lock?: boolean;
}

/** The worktree and branch the dispatcher makes for TST-1, on forge and, from its template, in work mode. */
export const NAME = "tst-1-fix-the-widget";
export const BRANCH = `worktree-${NAME}`;
export const WBRANCH = "feat/TST-1/fix-the-widget";

export class Case {
  readonly dir: string;
  readonly name: string;
  readonly state: string;
  readonly handoff: string;
  readonly demo: string;

  constructor(name: string) {
    this.name = name;
    this.dir = `${work}/${name}`;
    this.state = `${this.dir}/state/night-shift`;
    this.demo = `${this.dir}/projects/demo`;
    this.handoff = `${this.demo}/.git/linear-handoff`;
    for (const d of ["home", "state/night-shift", "tmp", "projects", "remote", "linear/issues", "power/AC", "power/BAT"]) {
      mkdirSync(`${this.dir}/${d}`, { recursive: true });
    }
    writeFileSync(`${this.dir}/power/AC/type`, "Mains\n");
    writeFileSync(`${this.dir}/power/AC/online`, "1\n");
    writeFileSync(`${this.dir}/power/BAT/type`, "Battery\n");
    writeFileSync(`${this.dir}/log.jsonl`, "");
    writeFileSync(`${this.dir}/key`, "test-key\n");
    writeFileSync(`${this.dir}/ntfy`, `http://127.0.0.1:${port}/${name}/ntfy\n`);
    copyFileSync(`${here}/fixtures/workspace.json`, `${this.dir}/linear/workspace.json`);
    const gc = `${this.dir}/gitconfig`;
    for (const [k, v] of [["user.name", "Night Shift Test"], ["user.email", "test@example.invalid"],
      ["init.defaultBranch", "main"], ["commit.gpgsign", "false"], ["advice.detachedHead", "false"]]) {
      spawnSync("git", ["config", "--file", gc, k!, v!]);
    }
  }

  env(extra: Record<string, string> = {}): Record<string, string> {
    return {
      PATH: path, HOME: `${this.dir}/home`, TMPDIR: `${this.dir}/tmp`, XDG_STATE_HOME: `${this.dir}/state`,
      GIT_CONFIG_GLOBAL: `${this.dir}/gitconfig`, GIT_CONFIG_NOSYSTEM: "1", NS_CASE: this.dir,
      NIGHT_SHIFT_KEY_FILE: `${this.dir}/key`, NIGHT_SHIFT_NTFY_FILE: `${this.dir}/ntfy`,
      NIGHT_SHIFT_PROJECTS: `${this.dir}/projects`, NIGHT_SHIFT_TS: ts, NIGHT_SHIFT_POWER: `${this.dir}/power`,
      NIGHT_SHIFT_MAX: "2", NIGHT_SHIFT_STALL_HOURS: "4", NIGHT_SHIFT_FAILED_RUNS: "3",
      NIGHT_SHIFT_LINEAR_URL: `http://127.0.0.1:${port}/${this.name}/graphql`,
      NIGHT_SHIFT_GITHUB_URL: `http://127.0.0.1:${port}/${this.name}/github`,
      ...extra,
    };
  }

  /**
   * The dispatcher, as forge runs it, from the case's directory or cwd. With
   * tty, on a terminal of its own (util-linux's script), which types tty into
   * it; otherwise with no stdin and no terminal.
   */
  async ns(
    args: string[],
    opts: { env?: Record<string, string>; tty?: string; cwd?: string } = {},
  ): Promise<{ status: number; out: string }> {
    const env = this.env(opts.env);
    const cwd = opts.cwd ?? this.dir;
    const cmd = [bash, "-euo", "pipefail", script, ...args];
    const child = opts.tty === undefined
      ? spawn(cmd[0]!, cmd.slice(1), { cwd, env, stdio: ["ignore", "pipe", "pipe"] })
      : spawn("script", ["-qec", ["env", "-i", ...Object.entries(env).map(([k, v]) => `${k}=${v}`), ...cmd].map(quote).join(" "), "/dev/null"],
        { cwd, env: { ...process.env, SHELL: bash }, stdio: ["pipe", "pipe", "pipe"] });
    if (opts.tty !== undefined) child.stdin!.end(opts.tty);
    let out = "";
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (out += d));
    const status = await new Promise<number>((r) => child.on("close", (code) => r(code ?? 1)));
    return { status, out };
  }

  /** Work mode, on a Mac: the case's config, the settings fixture for Nix's, and the key from a command, as the keychain gives it. */
  nsw(args: string[], opts: { env?: Record<string, string>; cwd?: string } = {}) {
    return this.ns(args, {
      cwd: opts.cwd,
      env: {
        NIGHT_SHIFT_MODE: "work", NIGHT_SHIFT_PLATFORM: "darwin", NIGHT_SHIFT_CONFIG: `${this.dir}/config.json`,
        NIGHT_SHIFT_SETTINGS: `${here}/fixtures/work-settings.json`, NIGHT_SHIFT_KEY_CMD: `cat ${this.dir}/key`,
        NIGHT_SHIFT_LOG: `${this.dir}/night-shift.log`,
        ...opts.env,
      },
    });
  }

  /** git as the dispatcher sees it; its stdout, trimmed. Throws on failure. */
  git(...args: string[]): string {
    const r = spawnSync("git", args, { env: this.env(), encoding: "utf8" });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
    return r.stdout.trim();
  }

  gitOk(...args: string[]): boolean {
    return spawnSync("git", args, { env: this.env(), stdio: "ignore" }).status === 0;
  }

  branchExists(branch: string): boolean {
    return this.gitOk("-C", this.demo, "show-ref", "--verify", "--quiet", `refs/heads/${branch}`);
  }

  /** projects/<name>, cloned from a bare remote/<name>.git with one commit on main. */
  repo(name: string): string {
    const seed = `${this.dir}/tmp/seed-${name}`;
    this.git("init", "-q", seed);
    writeFileSync(`${seed}/README.md`, `# ${name}\n`);
    this.git("-C", seed, "add", "README.md");
    this.git("-C", seed, "commit", "-q", "-m", "first");
    this.git("clone", "-q", "--bare", seed, `${this.dir}/remote/${name}.git`);
    this.git("clone", "-q", `${this.dir}/remote/${name}.git`, `${this.dir}/projects/${name}`);
    return `${this.dir}/projects/${name}`;
  }

  /** An issue in Linear, from fixtures/issue.json, or another fixture. */
  issue(id: string, change: (i: any) => void = () => {}, fixture = "issue.json"): void {
    const i = JSON.parse(readFileSync(`${here}/fixtures/${fixture}`, "utf8"));
    i.id = id;
    change(i);
    writeFileSync(`${this.dir}/linear/issues/${id}.json`, JSON.stringify(i));
  }

  /** An issue as Linear has it now, changed when given a change. */
  linear(id = "issue-1", change?: (i: any) => void): any {
    const f = `${this.dir}/linear/issues/${id}.json`;
    const i = JSON.parse(readFileSync(f, "utf8"));
    if (change) {
      change(i);
      writeFileSync(f, JSON.stringify(i));
    }
    return i;
  }

  stateName(id = "issue-1"): string {
    return this.linear(id).state.name;
  }

  /** The comments on an issue, as one text. */
  comments(id = "issue-1"): string {
    return this.linear(id).comments.nodes.map((n: any) => n.body).join("\n");
  }

  /** TST-1's state file, changed when given a change; undefined when there is none. */
  st(change?: (s: any) => void, ident = "TST-1"): any {
    const f = `${this.state}/${ident}.json`;
    let s: any;
    try {
      s = JSON.parse(readFileSync(f, "utf8"));
    } catch {
      return undefined;
    }
    if (change) {
      change(s);
      writeFileSync(f, JSON.stringify(s));
    }
    return s;
  }

  /** A file under the case, or "" without one. */
  read(rel: string): string {
    try {
      return readFileSync(rel.startsWith("/") ? rel : `${this.dir}/${rel}`, "utf8");
    } catch {
      return "";
    }
  }

  roster(change?: (r: any[]) => void): any[] {
    const f = `${this.dir}/roster.json`;
    const r = JSON.parse(this.read(f) || "[]");
    if (change) {
      change(r);
      writeFileSync(f, JSON.stringify(r));
    }
    return r;
  }

  /**
   * A worktree the dispatcher would have made for TST-1, with one commit on
   * its branch, and the state file of an issue that has reached phase. The
   * roster lists its session as done.
   */
  agentWorktree(phase: string, started = ago(), branch = BRANCH, extra: Record<string, unknown> = {}): string {
    const wt = `${this.demo}/.claude/worktrees/${NAME}`;
    this.git("-C", this.demo, "worktree", "add", "-q", "--no-track", "-b", branch, wt, "origin/main");
    writeFileSync(`${wt}/widget.txt`, "widget\n");
    this.git("-C", wt, "add", "widget.txt");
    this.git("-C", wt, "commit", "-q", "-m", "fix the widget");
    writeFileSync(`${this.state}/TST-1.json`, JSON.stringify({
      id: "issue-1", ident: "TST-1", repo: this.demo, worktree: wt, branch, name: NAME,
      session: "session-1", phase, started, since: started, ...extra,
    }));
    this.roster((r) => r.splice(0, r.length, { id: "job-1", sessionId: "session-1", name: NAME, cwd: wt, state: "done" }));
    return wt;
  }

  /**
   * An agent can write the repository's shared refs, origin/HEAD among them,
   * which fetch leaves alone: points demo's at a branch of the agent's. What
   * the next worktree is made from must come from origin itself.
   */
  poisonHead(): void {
    this.git("-C", this.demo, "checkout", "-q", "-b", "evil");
    writeFileSync(`${this.demo}/evil.txt`, "the agent's\n");
    this.git("-C", this.demo, "add", "evil.txt");
    this.git("-C", this.demo, "commit", "-q", "-m", "evil");
    this.git("-C", this.demo, "checkout", "-q", "main");
    this.git("-C", this.demo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/evil");
  }

  log(): Logged[] {
    return readFileSync(`${this.dir}/log.jsonl`, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  }

  /** How many logged requests match. */
  count(match: (l: Logged) => boolean): number {
    return this.log().filter(match).length;
  }

  ops(op: string): Logged[] {
    return this.log().filter((l) => l.op === op);
  }

  claude(first: string): Logged[] {
    return this.log().filter((l) => l.tool === "claude" && l.args?.[0] === first);
  }

  /** Requests the stubs do not know. */
  unknown(): Logged[] {
    return this.log().filter((l) => l.tool === "unknown" || l.op === "unknown" || l.op === "no key" || l.op === "too complex");
  }
}
