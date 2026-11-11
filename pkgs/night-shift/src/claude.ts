import { spawn } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import type { Platform } from "./env.ts";

// claude outside the run, so the background daemon it may start, which hosts
// every agent, outlives it. On forge, in a scope of its own outside the unit,
// whose cgroup a stop or a finished run would kill. --expand-environment=no,
// because systemd-run otherwise expands "${...}" in its arguments the way
// ExecStart= does, and the prompt is one of them: it has to arrive as Nick
// wrote it. On a Mac, in a process group of its own, so the run's deadline,
// which ends the run's group, leaves the daemon be.
//
// Output goes through files, never pipes: a daemon that claude leaves running
// could inherit a pipe and hold this process's read open for as long as it
// lives.

export interface Said {
  status: number;
  stdout: string;
  stderr: string;
}

/** stdout is kept only when asked for, and otherwise goes nowhere, as stderr never does. */
export async function cl(platform: Platform, args: string[], cwd?: string, keepOut = false): Promise<Said> {
  const [cmd, argv] = platform === "darwin"
    ? ["claude", args]
    : ["systemd-run", ["--user", "--scope", "--collect", "--quiet", "--expand-environment=no", "--", "claude", ...args]];
  const dir = mkdtempSync(`${tmpdir()}/night-shift-claude.`);
  const out = keepOut ? openSync(`${dir}/out`, "w") : "ignore";
  const err = openSync(`${dir}/err`, "w");
  try {
    const child = spawn(cmd, argv, { cwd, stdio: ["ignore", out, err], detached: platform === "darwin" });
    const status = await new Promise<number>((done) => {
      child.on("error", () => done(127));
      child.on("exit", (code) => done(code ?? 1));
    });
    return {
      status,
      stdout: keepOut ? readFileSync(`${dir}/out`, "utf8") : "",
      stderr: readFileSync(`${dir}/err`, "utf8"),
    };
  } finally {
    if (typeof out === "number") closeSync(out);
    closeSync(err);
    rmSync(dir, { recursive: true, force: true });
  }
}

/** The roster's states for a session no longer at work. */
export const ENDED = ["done", "blocked", "stopped", "failed"];
export const atWork = (state: string) => !ENDED.includes(state);

export interface Session {
  id: string;
  sessionId: string;
  name?: string;
  cwd: string;
  state: string;
}

/** Every session in the roster, or undefined when it could not be read. */
export async function roster(platform: Platform): Promise<Session[] | undefined> {
  const r = await cl(platform, ["agents", "--json", "--all"], undefined, true);
  if (r.status !== 0) return undefined;
  try {
    const sessions = JSON.parse(r.stdout);
    return Array.isArray(sessions) ? sessions : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The background agent with that name in that worktree. `claude --bg` picks
 * its ids itself and ignores --session-id, so this asks its roster.
 */
export async function agent(platform: Platform, name: string, worktree: string): Promise<Session | undefined> {
  return (await roster(platform))?.filter((s) => s.name === name && s.cwd === worktree).at(-1);
}
