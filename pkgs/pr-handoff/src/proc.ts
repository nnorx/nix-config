import { spawn, spawnSync, type SpawnSyncOptions } from "node:child_process";
import { accessSync, closeSync, constants, openSync, readSync } from "node:fs";
import { delimiter } from "node:path";

/** An expected refusal: printed as "pr-handoff: <message>", exit 1. */
export class Fatal extends Error {}

/** A command that failed and said why itself: exit with its status. */
export class Exit extends Error {
  readonly status: number;
  constructor(status: number) {
    super(`exit ${status}`);
    this.status = status;
  }
}

export function die(...message: string[]): never {
  throw new Fatal(message.join(" "));
}

export interface Ran {
  status: number;
  stdout: Buffer;
}

/** A command, stdin closed, stderr to the terminal, stdout kept. */
export function tryRun(cmd: string, args: string[], opts: SpawnSyncOptions = {}): Ran {
  const r = spawnSync(cmd, args, { stdio: ["ignore", "pipe", "inherit"], ...opts });
  return { status: r.status ?? 1, stdout: (r.stdout as Buffer | null) ?? Buffer.alloc(0) };
}

/** Its stdout as text, or the run ends with its status, as errexit would. */
export function must(cmd: string, ...args: string[]): string {
  const r = tryRun(cmd, args);
  if (r.status !== 0) throw new Exit(r.status);
  return r.stdout.toString("utf8");
}

/** Its stdout as text, trimmed, or undefined when it fails. */
export function maybe(cmd: string, ...args: string[]): string | undefined {
  const r = tryRun(cmd, args);
  return r.status === 0 ? r.stdout.toString("utf8").trim() : undefined;
}

/** Straight to the terminal, so git and gh color as they would. */
export function shown(cmd: string, ...args: string[]): number {
  return spawnSync(cmd, args, { stdio: ["ignore", "inherit", "inherit"] }).status ?? 1;
}

/** As shown, or the run ends with its status. */
export function mustShow(cmd: string, ...args: string[]): void {
  const status = shown(cmd, ...args);
  if (status !== 0) throw new Exit(status);
}

export function say(line = ""): void {
  process.stdout.write(`${line}\n`);
}

export function onPath(name: string): boolean {
  return (process.env.PATH ?? "").split(delimiter).some((d) => {
    try {
      accessSync(`${d}/${name}`, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

/** cmd's output paged through less, whatever $LESS says: escapes show as text. */
export function page(cmd: string[]): Promise<void> {
  return new Promise((done) => {
    const source = spawn(cmd[0]!, cmd.slice(1), { stdio: ["ignore", "pipe", "inherit"] });
    const less = spawn("less", ["-+R", "-+r"], { stdio: [source.stdout, "inherit", "inherit"] });
    // Quitting less early ends the source with SIGPIPE, which is not a failure.
    let left = 2;
    const end = () => --left === 0 && done();
    source.once("exit", end).once("error", end);
    less.once("exit", end).once("error", end);
  });
}

/**
 * Lines typed at the terminal, from one descriptor held open, so a file
 * standing in for it is read on from where the last answer ended. A byte at
 * a time, so nothing past the newline is taken.
 */
export class Tty {
  private readonly fd: number;
  private constructor(fd: number) {
    this.fd = fd;
  }

  static open(path: string): Tty | undefined {
    try {
      return new Tty(openSync(path, "r"));
    } catch {
      return undefined;
    }
  }

  /** The line, trimmed as `read` trims it, or undefined without a newline. */
  line(): string | undefined {
    const byte = Buffer.alloc(1);
    const bytes: number[] = [];
    try {
      while (readSync(this.fd, byte, 0, 1, null) === 1) {
        if (byte[0] === 0x0a) return Buffer.from(bytes).toString("utf8").trim();
        bytes.push(byte[0]!);
      }
    } catch {
      // As at the end: no answer.
    }
    return undefined;
  }

  close(): void {
    closeSync(this.fd);
  }
}
