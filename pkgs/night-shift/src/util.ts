import { spawnSync } from "node:child_process";
import { closeSync, openSync, readSync, statSync } from "node:fs";

/** An expected failure: printed as "night-shift: <message>", exit 1. */
export class Fatal extends Error {}

export function die(message: string): never {
  throw new Fatal(message);
}

export function warn(message: string): void {
  process.stderr.write(`night-shift: ${message}\n`);
}

export function say(line = ""): void {
  process.stdout.write(`${line}\n`);
}

/** UTC to the second, as `date -u +%FT%TZ` writes it. */
export function now(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export interface Ran {
  status: number;
  stdout: string;
  stderr: string;
  missing: boolean;
}

/** A command to completion, stdin closed. `missing` when it is not on PATH. */
export function run(cmd: string, args: string[], cwd?: string): Ran {
  const r = spawnSync(cmd, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const missing = (r.error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
  return { status: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", missing };
}

export function git(dir: string, ...args: string[]): Ran {
  return run("git", ["-C", dir, ...args]);
}

/** The repository's shared .git directory, for a checkout or a worktree. */
export function commonDir(dir: string): string | undefined {
  const r = git(dir, "rev-parse", "--path-format=absolute", "--git-common-dir");
  return r.status === 0 ? r.stdout.trim() : undefined;
}

export function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/**
 * One line typed at the terminal, or "" with none to type it. Read a byte at
 * a time so nothing past the newline is taken from whoever reads next.
 */
export function askTty(prompt: string): string {
  process.stdout.write(prompt);
  let fd: number;
  try {
    fd = openSync("/dev/tty", "r");
  } catch {
    return "";
  }
  const byte = Buffer.alloc(1);
  const bytes: number[] = [];
  try {
    while (readSync(fd, byte, 0, 1, null) === 1 && byte[0] !== 0x0a) bytes.push(byte[0]!);
  } catch {
    return "";
  } finally {
    closeSync(fd);
  }
  return Buffer.from(bytes).toString("utf8").replace(/\r$/, "");
}
