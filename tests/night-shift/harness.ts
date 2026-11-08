// What the TypeScript cases (commands.test.ts) have to hand: a case directory
// as run.sh's begin makes it, the dispatcher run there through night-shift.sh
// with an environment of the case's own, and http.ts serving Linear and ntfy
// from stubs/curl. Children run async, so this process stays free meanwhile.
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export const here = import.meta.dirname;
const root = resolve(here, "../..");
const script = resolve(process.env.NIGHT_SHIFT_SCRIPT ?? `${root}/pkgs/night-shift/night-shift.sh`);
const ts = resolve(process.env.NIGHT_SHIFT_TS ?? `${root}/pkgs/night-shift/src/main.ts`);
const bash = process.env.NIGHT_SHIFT_BASH ?? "bash";

const work = mkdtempSync(join(tmpdir(), "night-shift-ts."));
const bin = `${work}/bin`;
mkdirSync(bin);
for (const tool of ["claude", "osascript"]) {
  writeFileSync(`${bin}/${tool}`, `#!${bash}\nexec ${bash} -euo pipefail ${here}/stubs/${tool} "$@"\n`);
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

export function done(): void {
  server.kill();
  if (!process.env.NIGHT_SHIFT_TESTS_KEEP) rmSync(work, { recursive: true, force: true });
}

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

export interface Logged {
  tool: string;
  op?: string;
  variables?: any;
  title?: string;
  body?: string;
}

export class Case {
  readonly dir: string;
  readonly name: string;
  readonly state: string;
  readonly handoff: string;

  constructor(name: string) {
    this.name = name;
    this.dir = `${work}/${name}`;
    this.state = `${this.dir}/state/night-shift`;
    this.handoff = `${this.dir}/projects/demo/.git/linear-handoff`;
    for (const d of ["home", "state/night-shift", "tmp", "projects", "remote", "linear/issues"]) {
      mkdirSync(`${this.dir}/${d}`, { recursive: true });
    }
    writeFileSync(`${this.dir}/log.jsonl`, "");
    writeFileSync(`${this.dir}/key`, "test-key\n");
    writeFileSync(`${this.dir}/ntfy`, `http://127.0.0.1:${port}/${name}/ntfy\n`);
    copyFileSync(`${here}/fixtures/workspace.json`, `${this.dir}/linear/workspace.json`);
    const gc = `${this.dir}/gitconfig`;
    for (const [k, v] of [["user.name", "Night Shift Test"], ["user.email", "test@example.invalid"],
      ["init.defaultBranch", "main"], ["commit.gpgsign", "false"]]) {
      spawnSync("git", ["config", "--file", gc, k!, v!]);
    }
  }

  env(extra: Record<string, string> = {}): Record<string, string> {
    return {
      PATH: path, HOME: `${this.dir}/home`, TMPDIR: `${this.dir}/tmp`, XDG_STATE_HOME: `${this.dir}/state`,
      GIT_CONFIG_GLOBAL: `${this.dir}/gitconfig`, GIT_CONFIG_NOSYSTEM: "1", NS_CASE: this.dir,
      NIGHT_SHIFT_KEY_FILE: `${this.dir}/key`, NIGHT_SHIFT_NTFY_FILE: `${this.dir}/ntfy`,
      NIGHT_SHIFT_PROJECTS: `${this.dir}/projects`, NIGHT_SHIFT_TS: ts,
      NIGHT_SHIFT_LINEAR_URL: `http://127.0.0.1:${port}/${this.name}/graphql`,
      ...extra,
    };
  }

  /**
   * The dispatcher, as forge runs it. With tty, on a terminal of its own
   * (util-linux's script), which types tty into it.
   */
  async ns(args: string[], opts: { env?: Record<string, string>; tty?: string } = {}): Promise<{ status: number; out: string }> {
    const env = this.env(opts.env);
    const cmd = [bash, "-euo", "pipefail", script, ...args];
    const child = opts.tty === undefined
      ? spawn(cmd[0]!, cmd.slice(1), { cwd: this.dir, env, stdio: ["ignore", "pipe", "pipe"] })
      : spawn("script", ["-qec", ["env", "-i", ...Object.entries(env).map(([k, v]) => `${k}=${v}`), ...cmd].map(quote).join(" "), "/dev/null"],
        { cwd: this.dir, env: { ...process.env, SHELL: bash }, stdio: ["pipe", "pipe", "pipe"] });
    if (opts.tty !== undefined) child.stdin!.end(opts.tty);
    let out = "";
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (out += d));
    const status = await new Promise<number>((r) => child.on("close", (code) => r(code ?? 1)));
    return { status, out };
  }

  /** Work mode, on a Mac. */
  nsw(args: string[]) {
    return this.ns(args, {
      env: {
        NIGHT_SHIFT_MODE: "work", NIGHT_SHIFT_PLATFORM: "darwin", NIGHT_SHIFT_CONFIG: `${this.dir}/config.json`,
        NIGHT_SHIFT_SETTINGS: `${here}/fixtures/work-settings.json`, NIGHT_SHIFT_KEY_CMD: `cat ${this.dir}/key`,
      },
    });
  }

  git(...args: string[]): void {
    const r = spawnSync("git", args, { env: this.env(), encoding: "utf8" });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
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

  /** An issue in Linear, from fixtures/issue.json. */
  issue(id: string, change: (i: any) => void = () => {}): void {
    const i = JSON.parse(readFileSync(`${here}/fixtures/issue.json`, "utf8"));
    i.id = id;
    change(i);
    writeFileSync(`${this.dir}/linear/issues/${id}.json`, JSON.stringify(i));
  }

  log(): Logged[] {
    return readFileSync(`${this.dir}/log.jsonl`, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  }

  ops(op: string): Logged[] {
    return this.log().filter((l) => l.op === op);
  }

  /** Requests the stubs do not know. */
  unknown(): Logged[] {
    return this.log().filter((l) => l.tool === "unknown" || l.op === "unknown" || l.op === "no key" || l.op === "too complex");
  }
}
