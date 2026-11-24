import { spawn } from "node:child_process";
import { constants } from "node:os";
import { createInterface } from "node:readline";

/** An expected stop: printed as "fleet-deploy: <message>", exit 1. */
export class Fatal extends Error {}

/** A stop whose reason is already printed. */
export class Exit extends Error {
  readonly status: number;
  constructor(status: number) {
    super(`exit ${status}`);
    this.status = status;
  }
}

export function die(message: string): never {
  throw new Fatal(message);
}

export const say = (line = "") => void process.stdout.write(`${line}\n`);
export const step = (line: string) => say(`\n==> ${line}`);

/** Captured output, as `printf '%s\n' "$(...)" | sed 's/^/   /'` shows it. */
export function indent(text: string): void {
  for (const line of text.replace(/\n+$/, "").split("\n")) say(`   ${line}`);
}

/** Streamed output, indented line by line as it comes. */
class Indenter {
  private rest = "";
  write(chunk: Buffer): void {
    const lines = (this.rest + chunk.toString("utf8")).split("\n");
    this.rest = lines.pop() ?? "";
    for (const line of lines) say(`   ${line}`);
  }
  end(): void {
    if (this.rest) say(`   ${this.rest}`);
    this.rest = "";
  }
}

/** keep: captured. show: to the terminal. indent: to stdout, indented. none: dropped. */
type Out = "keep" | "show" | "indent" | "none";

export interface Ran {
  status: number;
  stdout: string;
  stderr: string;
}

/**
 * A command, its stdin closed unless asked for, so nothing it runs takes the
 * answers to the prompts. Asynchronous, so Ctrl-C reaches the handler at once.
 * A command that cannot start is 127, and one killed by a signal 128 plus its
 * number, as in the shell.
 */
export function run(
  cmd: string,
  args: string[],
  o: { cwd?: string; env?: NodeJS.ProcessEnv; stdin?: "ignore" | "inherit"; out?: Out; err?: Out } = {},
): Promise<Ran> {
  const outMode = o.out ?? "keep";
  const errMode = o.err ?? "show";
  const stdio = (m: Out) => (m === "show" ? "inherit" : m === "none" ? "ignore" : "pipe");
  return new Promise((resolve) => {
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    const indenter = new Indenter();
    const done = (status: number) => {
      indenter.end();
      resolve({ status, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") });
    };
    const child = spawn(cmd, args, {
      cwd: o.cwd,
      env: o.env,
      stdio: [o.stdin ?? "ignore", stdio(outMode), stdio(errMode)],
    });
    child.stdout?.on("data", (d: Buffer) => (outMode === "indent" ? indenter.write(d) : out.push(d)));
    child.stderr?.on("data", (d: Buffer) => (errMode === "indent" ? indenter.write(d) : err.push(d)));
    child.once("error", () => done(127));
    child.once("close", (code, signal) => done(code ?? 128 + (signal ? constants.signals[signal] : 0)));
  });
}

/**
 * Answers to the prompts, a line each from stdin, read only once the first
 * question is asked so that ssh-add can have the terminal before it. Trimmed
 * as `read` trims, and empty once stdin ends, which skips.
 */
export class Answers {
  private lines: string[] = [];
  private ended = false;
  private started = false;
  private wake: () => void = () => {};

  async ask(question: string): Promise<string> {
    // As `read -p`: the question only to a terminal.
    if (process.stdin.isTTY) process.stderr.write(question);
    if (!this.started) {
      this.started = true;
      const rl = createInterface({ input: process.stdin, terminal: false });
      rl.on("line", (line) => {
        this.lines.push(line);
        this.wake();
      });
      rl.on("close", () => {
        this.ended = true;
        this.wake();
      });
    }
    while (this.lines.length === 0 && !this.ended) await new Promise<void>((r) => (this.wake = r));
    return (this.lines.shift() ?? "").replace(/^[ \t]+|[ \t]+$/g, "");
  }
}

export function took(ms: number): string {
  const s = Math.round(ms / 1000);
  return s < 60 ? `${s} s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}
