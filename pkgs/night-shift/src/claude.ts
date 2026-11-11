import { spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

// claude in a scope of its own, outside forge's unit (work mode's, on a Mac,
// is night-shift.sh's). Any claude command can start the background daemon,
// which hosts every agent: in the unit's cgroup, stopping or finishing a run
// would kill them.
//
// --expand-environment=no, because systemd-run otherwise expands "${...}" in
// its arguments the way ExecStart= does, and the prompt is one of them. An
// issue quoting a workflow's ${{ github.ref }} reached the agent with it
// emptied. The prompt has to arrive as Nick wrote it.
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
export function cl(args: string[], cwd?: string, keepOut = false): Said {
  const argv = ["--user", "--scope", "--collect", "--quiet", "--expand-environment=no", "--", "claude", ...args];
  const dir = mkdtempSync(`${tmpdir()}/night-shift-claude.`);
  const out = keepOut ? openSync(`${dir}/out`, "w") : "ignore";
  const err = openSync(`${dir}/err`, "w");
  try {
    const r = spawnSync("systemd-run", argv, { cwd, stdio: ["ignore", out, err] });
    return {
      status: r.status ?? 1,
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
export function roster(): Session[] | undefined {
  const r = cl(["agents", "--json", "--all"], undefined, true);
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
export function agent(name: string, worktree: string): Session | undefined {
  return roster()?.filter((s) => s.name === name && s.cwd === worktree).at(-1);
}
