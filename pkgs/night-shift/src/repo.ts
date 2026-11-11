import { existsSync, renameSync } from "node:fs";
import type { Env } from "./env.ts";
import { cmp, commonDir, git } from "./util.ts";

export function resultPath(repo: string, ident: string): string {
  return `${commonDir(repo) ?? `${repo}/.git`}/night-shift/${ident}.md`;
}

/** Keeps a result that has been read, or that turned up too late, out of the way of the next one. */
export function archive(result: string): void {
  if (existsSync(result)) renameSync(result, `${result}.${Math.floor(Date.now() / 1000)}`);
}

/**
 * The branch origin's HEAD names, and its commit, as origin itself answers,
 * after a fetch. Not from refs/remotes/origin/HEAD: the sandbox lets commands
 * write the shared refs, fetch never resets that one, and an agent that
 * pointed it at its own branch would hand its code to the next agent. A
 * commit id from origin is one nothing in the repository can forge.
 */
export function fetchBase(repo: string): { branch: string; sha: string } | undefined {
  const r = git(repo, "ls-remote", "--symref", "origin", "HEAD");
  if (r.status !== 0) return undefined;
  const branch = /^ref: refs\/heads\/(\S+)\s+HEAD$/m.exec(r.stdout)?.[1];
  const sha = /^([0-9a-f]+)\s+HEAD$/m.exec(r.stdout)?.[1];
  if (!branch || !sha) return undefined;
  if (git(repo, "fetch", "--quiet", "origin").status !== 0) return undefined;
  if (git(repo, "cat-file", "-e", `${sha}^{commit}`).status !== 0) return undefined;
  return { branch, sha };
}

/**
 * The agent's worktree, on a new branch with no upstream and with no hook
 * run. --no-track: setting an upstream writes .git/config, which fails while
 * a sandboxed session in the repo holds its placeholder at .git/config.lock,
 * after git has made the branch. Nothing reads the upstream; pr-handoff sets
 * its own.
 */
export function addWorktree(repo: string, branch: string, worktree: string, base: string): boolean {
  return git(repo, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", "--no-track", "-b", branch, worktree, base)
    .status === 0;
}

const head = (dir: string) => git(dir, "symbolic-ref", "--quiet", "HEAD").stdout.trim();
export const tip = (repo: string, branch: string) =>
  git(repo, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}^{commit}`).stdout.trim();

/**
 * Undoes a start whose agent never ran, so queuing the issue again starts
 * afresh. Removes only what holds nothing: the branch still at the commit it
 * was made from, the worktree still on it, and nothing uncommitted, which
 * git's remove refuses without --force. Why it kept them, or "".
 */
export function discardStart(repo: string, worktree: string, branch: string, sha: string): string {
  if (tip(repo, branch) !== sha) return `\`${branch}\` is no longer at the commit it was made from.`;
  if (!onBranch(worktree, branch)) return `it is no longer on \`${branch}\`.`;
  let r = git(repo, "worktree", "remove", worktree);
  if (r.status !== 0) return `git would not remove it: ${(r.stdout + r.stderr).trim()}`;
  r = git(repo, "branch", "-D", branch);
  if (r.status !== 0) return `deleting \`${branch}\` failed: ${(r.stdout + r.stderr).trim()}`;
  return "";
}

export function onBranch(worktree: string, branch: string): boolean {
  return head(worktree) === `refs/heads/${branch}`;
}

/** The GitHub repository behind origin, as owner/name. */
export function githubRepo(repo: string): string | undefined {
  const url = git(repo, "remote", "get-url", "origin").stdout.trim();
  const m = /^(https:\/\/|ssh:\/\/git@|git@)github\.com[:/]([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/.exec(url);
  return m ? `${m[2]}/${m[3]!.replace(/\.git$/, "")}` : undefined;
}

export interface Merged {
  number: number;
  url: string;
  sha: string;
}

/**
 * The PR from the branch that merged, or null. Asked without a token: the
 * night shift has no GitHub login and must not get one. A private repo
 * answers 404, as a missing one does, and is left to Nick. "refused" is
 * nearly always the limit of 60 an hour without a token.
 */
export async function mergedPr(env: Env, slug: string, branch: string): Promise<Merged | null | "offline" | "refused"> {
  const owner = slug.split("/")[0];
  const url = `${env.githubUrl}/repos/${slug}/pulls?state=closed&head=${owner}:${encodeURIComponent(branch)}`;
  let res: Response;
  try {
    res = await fetch(url, {
      headers: { Accept: "application/vnd.github+json" },
      signal: AbortSignal.timeout(15_000),
      // As curl without -L: a moved repository is not followed.
      redirect: "manual",
    });
  } catch {
    return "offline";
  }
  if (res.status === 404) return null;
  if (res.status === 403 || res.status === 429) return "refused";
  if (res.status !== 200) return "offline";
  try {
    const prs = (await res.json()) as { number: number; html_url: string; merged_at: string | null; head: { sha: string } }[];
    const merged = prs.filter((p) => p.merged_at).sort((a, b) => cmp(a.merged_at!, b.merged_at!)).at(-1);
    return merged ? { number: merged.number, url: merged.html_url, sha: merged.head.sha } : null;
  } catch {
    return "offline";
  }
}
