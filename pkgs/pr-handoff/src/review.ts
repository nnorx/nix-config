import { lstatSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { die, maybe, must, say, tryRun } from "./proc.ts";

// What the review shows before anything is published: the PR is public, and
// this runs as Nick on text that agents wrote.

export interface Handoff {
  /** The first line: the title, or the squash's subject. */
  head: string;
  /** The rest, less its leading blank lines, as bytes for gh's --body-file. */
  body: Buffer;
}

/**
 * The handoff at path, in dir. Never evaluated: it reaches gh as an argument
 * and a file, so nothing Claude writes can make this do more than publish it.
 */
export function readHandoff(dir: string, path: string): Handoff {
  if (lstatSync(dir, { throwIfNoEntry: false })?.isSymbolicLink()) die(`${dir} is a link; publish by hand`);
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile()) die(`no handoff at ${path}, or not a plain file; ask Claude to write one`);
  if (st.size === 0) die(`no handoff at ${path}; ask Claude to write one`);
  const raw = readFileSync(path);
  plain(`the handoff ${path}`, raw);
  const nl = raw.indexOf(0x0a);
  const head = (nl === -1 ? raw : raw.subarray(0, nl)).toString("utf8");
  if (!head) die(`the first line of ${path}, the title, is empty`);
  let rest = nl === -1 ? Buffer.alloc(0) : raw.subarray(nl + 1);
  while (rest[0] === 0x0a) rest = rest.subarray(1);
  return { head, body: rest };
}

/**
 * Refuses text with a control character but tab or newline, C1 as UTF-8, or
 * bytes that are not UTF-8, since the terminal would act on it as it is
 * shown, or show other than what is published.
 */
export function plain(what: string, text: Buffer): void {
  for (let i = 0, line = 1; i < text.length; i++) {
    const b = text[i]!;
    if (b === 0x0a) line++;
    else if (b <= 0x08 || (b >= 0x0b && b <= 0x1f) || b === 0x7f || (b === 0xc2 && text[i + 1]! >= 0x80 && text[i + 1]! <= 0x9f)) {
      die(`line ${line} of ${what} has a control character; nothing shown or published`);
    }
  }
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(text);
  } catch {
    die(`${what} is not valid UTF-8; nothing shown or published`);
  }
}

// What looks like an IP or MAC address. lib/net.nix's own addresses are
// public and match too, so a hit is a reason to look, not to refuse.
const ADDRESS = /\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/;

/** Each line of text that looks like an address, as grep -n has it. */
function addresses(text: string): string[] {
  const lines = text.split("\n");
  if (text.endsWith("\n")) lines.pop();
  return lines.flatMap((l, n) => (ADDRESS.test(l) ? [`${n + 1}:${l}`] : []));
}

export function show(h: Handoff): void {
  say("--- title");
  say(h.head);
  say("--- body");
  process.stdout.write(h.body);
  say("---");
  const hits = addresses(`${h.head}\n${h.body.toString("utf8")}`);
  if (hits.length) {
    say("!! These lines look like an IP or MAC address:");
    for (const hit of hits) say(hit);
  }
}

/**
 * The same check over each commit message in range. A branch's commits stay
 * listed on its PR after the squash merge, so their messages are published
 * with it.
 */
export function showCommits(range: string): void {
  const hits = must("git", "rev-list", "--reverse", range)
    .split("\n")
    .filter(Boolean)
    .flatMap((c) => addresses(must("git", "show", "-s", "--format=%B", c)).map((hit) => `${c.slice(0, 7)}:${hit}`));
  if (hits.length) {
    say("!! These commit message lines look like an IP or MAC address:");
    for (const hit of hits) say(hit);
  }
}

// Files the branch changes that run on Nick's machine once he works in the
// checkout, rather than on GitHub's: hooks, build and test setup, editor and
// environment config. More patterns, extended regular expressions on the
// path, from the repository's git config:
// `git config --add pr-handoff.watch '^ci/local/'`.
const WATCHED =
  "(^|/)(\\.husky|\\.githooks|scripts|\\.claude|\\.vscode|\\.github/workflows)/|(^|/)(Makefile|[^/]*\\.mk|pyproject\\.toml|package\\.json|\\.yarnrc\\.yml|\\.envrc|flake\\.nix|\\.pre-commit-config\\.yaml)$";

/** The paths range changes that match, by grep -E, as git config's are. */
export function watched(range: string): string[] {
  const extra = (maybe("git", "config", "--get-all", "pr-handoff.watch") ?? "").split("\n").filter(Boolean);
  const names = must("git", "diff", "--name-only", range);
  const r = spawnSync("grep", ["-E", [WATCHED, ...extra].join("|")], { input: names, stdio: ["pipe", "pipe", "inherit"] });
  if (r.status === 2) die("grep refused a pr-handoff.watch pattern; fix it in git config");
  return r.stdout.toString("utf8").split("\n").filter(Boolean);
}

/**
 * Whether the .lfsconfig git-lfs would read here differs from base's.
 * git-lfs reads it from the working tree, else the index, else HEAD, and it
 * says where LFS objects go (lfs.url, lfs.pushurl). Untracked, neither the
 * diff nor the uncommitted check shows it, and `git lfs push` would upload
 * the branch's objects wherever it says. --no-filters: the bytes git-lfs
 * reads, not what a .gitattributes rule would make of them.
 */
export function lfsconfigMoved(base: string): boolean {
  const top = must("git", "rev-parse", "--show-toplevel").trim();
  const verify = (rev: string) => maybe("git", "rev-parse", "--quiet", "--verify", rev) ?? "";
  let ours: string;
  if (lstatSync(`${top}/.lfsconfig`, { throwIfNoEntry: false })) {
    const r = tryRun("git", ["hash-object", "--no-filters", "--", `${top}/.lfsconfig`], { stdio: ["ignore", "pipe", "ignore"] });
    if (r.status !== 0) return true;
    ours = r.stdout.toString("utf8").trim();
  } else {
    ours = verify(":.lfsconfig") || verify("HEAD:.lfsconfig");
  }
  return ours !== verify(`${base}:.lfsconfig`);
}
