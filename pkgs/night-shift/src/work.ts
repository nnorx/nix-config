import { spawnSync } from "node:child_process";
import { appendFileSync, closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import type { Env } from "./env.ts";
import type { Change, Issue } from "./issues.ts";
import { latest } from "./machine.ts";
import type { Merged } from "./repo.ts";
import { die, isFile, run } from "./util.ts";

// Work mode: a Mac at work, against a Linear team Nick shares. Each team's
// repository and setup come from NIGHT_SHIFT_CONFIG, a file of Nick's outside
// this public repo; docs/night-shift.md, "On a Mac", has its shape. The one
// thing it writes to Linear is the move to the team's started state.

export interface RepoConf {
  dir?: string;
  /** Setup commands, run in a new worktree outside the sandbox. */
  bootstrap?: string[];
  /** Additions to the agents' sandbox, which can only add. */
  sandbox?: {
    allowedDomains?: string[];
    allowWrite?: string[];
    denyRead?: string[];
    allowLocalBinding?: boolean;
    env?: Record<string, string>;
  };
  checks?: string;
  /** With {ID}, {id} and {slug}. The identifier in it links the PR to the issue. */
  branch?: string;
}

export interface WorkConfig {
  label: string;
  startedState: string;
  max: number;
  stallHours: number;
  repos: Record<string, RepoConf>;
}

export function loadConfig(env: Env): WorkConfig {
  let text: string;
  try {
    text = readFileSync(env.config ?? "", "utf8");
  } catch {
    die(`no config at '${env.config ?? ""}'; docs/night-shift.md, "On a Mac", has its shape`);
  }
  let c: Record<string, any>;
  try {
    c = JSON.parse(text);
  } catch {
    die(`${env.config} is not a JSON object`);
  }
  if (typeof c !== "object" || c === null || Array.isArray(c)) die(`${env.config} is not a JSON object`);
  const max = c.max ?? env.max;
  const stallHours = c.stallHours ?? env.stallHours;
  if (![max, stallHours].every((n) => /^[0-9]+$/.test(String(n)))) {
    die(`max and stallHours in ${env.config} are whole numbers`);
  }
  // The repos' own tools, which launchd's PATH does not carry.
  const extra = ((c.path ?? []) as string[]).map((p) => p.replace(/^~/, env.home));
  if (extra.length) process.env.PATH = [...extra, process.env.PATH].join(":");
  for (const [team, r] of Object.entries((c.repos ?? {}) as Record<string, RepoConf>)) {
    const list = r.bootstrap;
    if (list !== undefined && !(Array.isArray(list) && list.every((x) => typeof x === "string"))) {
      die(`repos.${team}.bootstrap in ${env.config} is a list of commands`);
    }
  }
  return {
    label: c.label ?? "agent",
    startedState: c.startedState ?? "In Progress",
    max: Number(max),
    stallHours: Number(stallHours),
    repos: c.repos ?? {},
  };
}

export function repoDir(env: Env, conf: RepoConf | undefined): string {
  return (conf?.dir ?? "").replace(/^~/, env.home);
}

/**
 * The settings files a session in dir, a checkout or worktree of repo, reads
 * below --settings: the user's, the main checkout's two, and the branch's.
 */
function settingsFiles(env: Env, repo: string, dir: string): string[] {
  return [
    `${env.home}/.claude/settings.json`,
    `${repo}/.claude/settings.json`,
    `${repo}/.claude/settings.local.json`,
    `${dir}/.claude/settings.json`,
  ];
}

/**
 * Settings files that would change an agent's sandbox, or run a command
 * outside it: --settings outranks a project's scalars, but lists add up
 * across scopes. Claude runs helper commands itself, with Nick's full access,
 * so a repository's are refused; Nick's own are his to run.
 */
export function overrides(env: Env, repo: string, worktree: string): string[] {
  const user = `${env.home}/.claude/settings.json`;
  const risky = ["sandbox", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "gcpAuthRefresh", "otelHeadersHelper", "subagentStatusLine"];
  return settingsFiles(env, repo, worktree).filter((f) => {
    if (!isFile(f)) return false;
    try {
      const keys = Object.keys(JSON.parse(readFileSync(f, "utf8")));
      return keys.some((k) => (f === user ? k === "sandbox" : risky.includes(k)));
    } catch {
      return false;
    }
  });
}

const added = (base: unknown, more: unknown): unknown[] => {
  if (more === undefined || more === null) return (base ?? []) as unknown[];
  if (!Array.isArray(more) || (base != null && !Array.isArray(base))) throw new Error("not a list");
  return [...((base ?? []) as unknown[]), ...more];
};

/**
 * A session's settings in dir: Nix's base plus the repo's additions from the
 * config, which can only add, and never over a variable the base sets.
 * Written outside the checkout, where commands in the sandbox cannot change
 * it, and given with --settings. Every plugin a scope enables is turned off
 * unless the base enables it: a plugin's LSP servers and monitors run outside
 * the sandbox, and a language server loads code from the checkout. False when
 * the base is missing, a settings file is not JSON, or the additions do not fit.
 */
export function writeSettings(env: Env, conf: RepoConf, out: string, dir: string, repo: string): boolean {
  if (!env.settings || !isFile(env.settings)) return false;
  try {
    // The checkout's own settings.local.json too: in an agent's worktree it is
    // the dispatcher's (writeLocalSettings).
    const files = [...settingsFiles(env, repo, dir), `${dir}/.claude/settings.local.json`].filter(isFile);
    const plugins = [...new Set(files.flatMap((f) => Object.keys(JSON.parse(readFileSync(f, "utf8")).enabledPlugins ?? {})))].sort();
    const s = JSON.parse(readFileSync(env.settings, "utf8"));
    const x = conf.sandbox ?? {};
    s.sandbox ??= {};
    s.sandbox.network ??= {};
    s.sandbox.filesystem ??= {};
    s.sandbox.network.allowedDomains = added(s.sandbox.network.allowedDomains, x.allowedDomains);
    s.sandbox.filesystem.allowWrite = added(s.sandbox.filesystem.allowWrite, x.allowWrite);
    s.sandbox.filesystem.denyRead = added(s.sandbox.filesystem.denyRead, x.denyRead);
    if (x.allowLocalBinding === true) s.sandbox.network.allowLocalBinding = true;
    s.env = { ...(x.env ?? {}), ...(s.env ?? {}) };
    s.enabledPlugins = { ...Object.fromEntries(plugins.map((p) => [p, false])), ...(s.enabledPlugins ?? {}) };
    writeFileSync(out, `${JSON.stringify(s, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/**
 * The sandbox, environment, deny rules and what turns hooks and plugins off,
 * in the worktree's .claude/settings.local.json, which commands in the
 * sandbox cannot write. A session claude starts there without --settings, a
 * copy from a resume say, is contained all the same.
 */
export function writeLocalSettings(settings: string, worktree: string): boolean {
  try {
    const s = JSON.parse(readFileSync(settings, "utf8"));
    const local = {
      sandbox: s.sandbox ?? null,
      env: s.env ?? null,
      disableAllHooks: s.disableAllHooks ?? null,
      enabledPlugins: s.enabledPlugins ?? null,
      permissions: { deny: s.permissions?.deny ?? null },
    };
    mkdirSync(`${worktree}/.claude`, { recursive: true });
    writeFileSync(`${worktree}/.claude/settings.local.json`, `${JSON.stringify(local, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/** The repo's setup commands in the new worktree, outside the sandbox, each with half an hour to finish. */
export function bootstrap(env: Env, conf: RepoConf, worktree: string, log: string): boolean {
  writeFileSync(log, "");
  for (const cmd of conf.bootstrap ?? []) {
    if (!cmd) continue;
    appendFileSync(log, `$ ${cmd}\n`);
    const fd = openSync(log, "a");
    try {
      // GNU timeout ends the command's whole process group, as a run's
      // deadline does.
      const r = spawnSync("timeout", ["1800", env.bash, "-c", cmd], { cwd: worktree, stdio: ["ignore", fd, fd] });
      if (r.status !== 0) return false;
    } finally {
      closeSync(fd);
    }
  }
  return true;
}

export interface Labelled {
  createdAt: string;
  actorId: string | null;
  botActor: { id: string } | null;
}

/**
 * The history entry that last added the label, or the issue's creation for
 * a label set when it was made; undefined without the label. A creation
 * counts as Nick's only if no integration made it: Linear leaves the creator
 * empty for one acting as itself, and names the bot for one acting as him.
 */
export function labelled(i: Issue, label: string): Labelled | undefined {
  const id = i.labels.nodes.find((l) => l.name === label)?.id;
  if (!id) return undefined;
  const adds = i.history.nodes.filter((h: Change) => (h.addedLabelIds ?? []).includes(id));
  const last = latest(adds);
  if (last) return { createdAt: last.createdAt, actorId: last.actorId, botActor: last.botActor ?? null };
  return { createdAt: i.createdAt ?? "", actorId: i.creator?.id ?? null, botActor: i.botActor ?? null };
}

/**
 * Why the issue is not taken, or "". An integration acting with Nick's login,
 * the Linear MCP server in a Claude session say, could add the label as him;
 * Linear records it as a bot's, which is refused.
 */
export function refusal(i: Issue, l: Labelled | undefined, viewer: string): string {
  if ((i.assignee?.id ?? "") !== viewer) return "it is not assigned to you";
  if (i.history.pageInfo.hasNextPage) return "its history is too long to tell who added the label";
  if (!l) return "it does not carry the label";
  if (l.actorId !== viewer || l.botActor !== null) return "the label was last added by someone else or by an integration";
  const edited = i.history.nodes.some((h) =>
    h.createdAt > l.createdAt && h.actorId !== viewer && (h.updatedDescription === true || (h.fromTitle ?? null) !== null)
  );
  return edited ? "someone else changed its title or description after you added the label" : "";
}

/**
 * The PR from the branch that merged, from gh: a private repository answers
 * only with a token. Read-only, and here, outside the sandbox, is the one
 * place that has Nick's login. "failed" when gh could not say.
 */
export function mergedPrGh(slug: string, branch: string): Merged | null | "failed" {
  const r = run("gh", ["pr", "list", "--repo", slug, "--head", branch, "--state", "merged", "--json", "number,url,headRefOid"]);
  if (r.status !== 0) return "failed";
  try {
    const prs = JSON.parse(r.stdout) as { number: number; url: string; headRefOid: string }[];
    const pr = prs.reduce<(typeof prs)[number] | undefined>((a, p) => (!a || p.number > a.number ? p : a), undefined);
    return pr ? { number: pr.number, url: pr.url, sha: pr.headRefOid } : null;
  } catch {
    return "failed";
  }
}

const real = (p: string) => {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
};

/**
 * `night-shift safe`, cld-safe: an interactive Claude session here in the
 * agents' sandbox, with the repository's additions from the config when this
 * is in a repository it names. Refused, as an agent's start is, when the
 * repository's settings would change the sandbox or run a command outside
 * it. Nothing is written in the checkout, whose settings.local.json is Nick's,
 * and the settings go when the session ends.
 */
export function safe(env: Env, args: string[]): number {
  if (env.mode !== "work") die("safe is work mode's: on forge, every Claude session is sandboxed already");
  const here = process.cwd();
  const top = run("git", ["rev-parse", "--show-toplevel"], here);
  const dir = top.status === 0 ? top.stdout.trim() : here;
  // A worktree's main checkout, whose settings its sessions read too.
  const common = run("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], here);
  const commonDir = common.stdout.trim();
  const repo = common.status === 0 && commonDir.endsWith("/.git") ? commonDir.slice(0, -"/.git".length) : dir;
  let conf: RepoConf = {};
  if (env.config && isFile(env.config)) {
    conf = Object.values(loadConfig(env).repos).find((c) => repoDir(env, c) && real(repoDir(env, c)) === real(repo)) ?? {};
  }
  const over = overrides(env, repo, dir);
  if (over.length) die(`these settings would change the sandbox or run a command outside it: ${over.join(" ")}`);
  mkdirSync(env.stateDir, { recursive: true });
  // A directory of its own, not *.json or *.settings, the state files' and
  // kept sessions' globs.
  const tmp = mkdtempSync(`${env.stateDir}/safe.`);
  const settings = `${tmp}/settings.json`;
  try {
    if (!writeSettings(env, conf, settings, dir, repo)) {
      die(`the settings could not be written: '${env.settings ?? ""}' is missing, or a Claude settings file here is not JSON`);
    }
    // Ctrl-C, a closed terminal and a stop are the session's to answer: this
    // process outlives it to remove the settings.
    for (const sig of ["SIGINT", "SIGHUP", "SIGTERM"] as const) process.on(sig, () => {});
    const r = spawnSync("claude", ["--settings", settings, "--strict-mcp-config", ...args], { stdio: "inherit" });
    return r.status ?? 1;
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
