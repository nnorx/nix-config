import { readFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { die, isFile } from "./util.ts";

// Work mode: a Mac at work, against a Linear team Nick shares. Each team's
// repository and setup come from NIGHT_SHIFT_CONFIG, a file of Nick's outside
// this public repo; docs/night-shift.md, "On a Mac", has its shape.

export interface RepoConf {
  dir?: string;
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
  if (![max, stallHours].every((n) => Number.isInteger(Number(n)) && Number(n) >= 0)) {
    die(`max and stallHours in ${env.config} are whole numbers`);
  }
  // The repos' own tools, which launchd's PATH does not carry.
  const extra = ((c.path ?? []) as string[]).map((p) => p.replace(/^~/, env.home));
  if (extra.length) process.env.PATH = [...extra, process.env.PATH].join(":");
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
 * Settings files that would change an agent's sandbox, or run a command
 * outside it: --settings outranks a project's scalars, but lists add up
 * across scopes. Claude runs helper commands itself, with Nick's full access,
 * so a repository's are refused; Nick's own are his to run.
 */
export function overrides(env: Env, repo: string, worktree: string): string[] {
  const user = `${env.home}/.claude/settings.json`;
  const files = [user, `${repo}/.claude/settings.json`, `${repo}/.claude/settings.local.json`, `${worktree}/.claude/settings.json`];
  const risky = ["sandbox", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "gcpAuthRefresh", "otelHeadersHelper", "subagentStatusLine"];
  return files.filter((f) => {
    if (!isFile(f)) return false;
    try {
      const keys = Object.keys(JSON.parse(readFileSync(f, "utf8")));
      return keys.some((k) => (f === user ? k === "sandbox" : risky.includes(k)));
    } catch {
      return false;
    }
  });
}
