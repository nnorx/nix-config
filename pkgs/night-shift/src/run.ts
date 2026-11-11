// A run in forge mode: take finished work back to Linear, land what Nick
// merged, then start what he queued. docs/night-shift.md has the states an
// issue moves through. night-shift.sh holds the run lock around this, and lets
// forge sleep once it ends. Nothing here publishes, merges or deploys.
import { spawnSync } from "node:child_process";
import { existsSync, globSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { tmpdir } from "node:os";
import { agent, atWork, cl, ENDED, roster, type Session } from "./claude.ts";
import { type Env, NEEDS, QUEUED, READY, RUNNING } from "./env.ts";
import { closed, comment, getIssue, type Issue, move, writeIssue } from "./issues.ts";
import { type Linear, LinearError } from "./linear.ts";
import { notify } from "./notify.ts";
import { promptNew, promptResume } from "./prompts.ts";
import {
  addWorktree, archive, discardStart, fetchBase, githubRepo, type Merged, mergedPr, onBranch, resultPath, tip,
} from "./repo.ts";
import { cmp, commonDir, die, Fatal, git, now, relay, say, warn } from "./util.ts";

/** An issue the dispatcher has started, as <ID>.json in the state directory. */
interface State {
  id: string;
  ident: string;
  repo: string;
  worktree: string;
  branch: string;
  name: string;
  session: string;
  phase: "running" | "waiting";
  started: string;
  since: string;
  /** Seconds of work counted, and when last counted (quiet). */
  worked?: number;
  ticked?: string;
  ended?: string;
  ended_as?: string;
  checked?: string;
  merged?: Merged;
}

const read = (f: string) => JSON.parse(readFileSync(f, "utf8")) as State;

function write(f: string, s: State): void {
  writeFileSync(`${f}.tmp`, `${JSON.stringify(s, null, 2)}\n`);
  renameSync(`${f}.tmp`, f);
}

function update(f: string, change: (s: State) => void): State {
  const s = read(f);
  change(s);
  write(f, s);
  return s;
}

const secs = (iso: string) => Math.floor(Date.parse(iso) / 1000);
const clock = () => Math.floor(Date.now() / 1000);

class Run {
  readonly env: Env;
  readonly linear: Linear;
  readonly viewer: string;

  constructor(env: Env, linear: Linear, viewer: string) {
    this.env = env;
    this.linear = linear;
    this.viewer = viewer;
  }

  files(): string[] {
    try {
      return readdirSync(this.env.stateDir).filter((f) => f.endsWith(".json")).sort().map((f) => `${this.env.stateDir}/${f}`);
    } catch {
      return [];
    }
  }

  running(): number {
    return this.files().filter((f) => read(f).phase === "running").length;
  }

  /** Drops an issue the dispatcher is done with, with its issue text and results, read or not. */
  forget(f: string, why?: string): void {
    const s = read(f);
    // Unless the repo is gone too.
    const common = commonDir(s.repo);
    const dir = `${common}/night-shift`;
    if (common && existsSync(dir)) {
      for (const n of readdirSync(dir)) {
        if (n === `${s.ident}.issue.md` || n === `${s.ident}.md` || n.startsWith(`${s.ident}.md.`)) {
          rmSync(`${dir}/${n}`, { force: true });
        }
      }
    }
    rmSync(f);
    say(`night-shift: forgot ${s.ident}${why ? `, ${why}` : ""}`);
  }

  /**
   * A comment, a move, and a push that names the issue by its identifier, and
   * never by its title: ntfy.sh is a third party, and a title can describe
   * the house.
   */
  async stop(i: Issue, state: string, markdown: string, what: string): Promise<void> {
    await comment(this.linear, i, markdown);
    await move(this.linear, i, state);
    await notify(this.env, "Night shift", `${i.identifier}: ${what}`, i.url);
    say(`night-shift: ${i.identifier}: ${what}`);
  }

  /**
   * stop for a result, except that an issue Nick moved back to Queued while
   * its agent worked stays there, and this run resumes it with his comments.
   */
  async report(i: Issue, state: string, markdown: string, what: string): Promise<void> {
    if (i.state.name !== QUEUED) return this.stop(i, state, markdown, what);
    await comment(this.linear, i, markdown);
    say(`night-shift: ${i.identifier}: ${what}, left in ${QUEUED}`);
  }

  /**
   * Why a running agent with no result counts as quiet, or undefined while
   * it is still at work. Either its session has ended, or waits on a prompt,
   * on two looks `settle` apart; or it has worked `stallHours` with the
   * machine awake. Each run adds the time since the last, but at most `tick`,
   * so hours asleep, when no run came, count as one tick.
   */
  quiet(f: string, s: State): string | undefined {
    const tick = 2 * this.env.interval;
    const settle = 5 * 60;
    const t = clock();
    const gap = t - secs(s.ticked ?? s.started);
    const worked = (s.worked ?? 0) + (gap < tick ? Math.max(gap, 0) : tick);
    const seen = agent(s.name, s.worktree)?.state;
    // A roster that does not list the session, or could not be read, says
    // nothing either way, so an end already seen stands.
    let ended: string | undefined;
    let as: string | undefined;
    if (seen === undefined) [ended, as] = [s.ended, s.ended_as];
    else if (!atWork(seen)) [ended, as] = [s.ended ?? now(), seen];
    update(f, (u) => {
      u.worked = worked;
      u.ticked = now();
      if (ended) [u.ended, u.ended_as] = [ended, as ?? ""];
      else {
        delete u.ended;
        delete u.ended_as;
      }
    });
    if (ended && t - secs(ended) >= settle) {
      return as === "blocked"
        ? "The agent is waiting on a prompt, with no result."
        : `The agent's session ended (${as ?? ""}) without writing a result.`;
    }
    if (worked >= this.env.stallHours * 3600) return `No result after ${this.env.stallHours} hours of work.`;
    return undefined;
  }

  /**
   * Preflight's verdict and findings, for repos that have its brief. It
   * evaluates code the agent wrote, with the network on since evaluation
   * fetches flake inputs, so NIGHT_SHIFT_HIDE's paths are hidden from it.
   */
  brief(repo: string, branch: string): string {
    if (!existsSync(`${repo}/scripts/preflight-brief.jq`)) return "";
    const dir = mkdtempSync(`${tmpdir()}/night-shift-brief.`);
    try {
      const args = ["--dev-bind", "/", "/"];
      for (const p of this.env.hide.split("\n").filter(Boolean)) {
        for (const q of globSync(p.replace(/^~/, this.env.home))) {
          const isDir = statSync(q, { throwIfNoEntry: false })?.isDirectory();
          args.push(...(isDir ? ["--tmpfs", q] : ["--ro-bind", "/dev/null", q]));
        }
      }
      const r = spawnSync("bwrap", [...args, "--", "nix", "run", ".#preflight", "--", "--head", branch, "--json", `${dir}/brief.json`], {
        cwd: repo,
        stdio: "ignore",
      });
      if (r.status === 0) {
        const b = JSON.parse(readFileSync(`${dir}/brief.json`, "utf8"));
        type Finding = { level: string; text: string };
        const shown = (f: Finding) => f.level !== "note";
        return [
          `**Preflight: ${b.verdict.level}.** ${b.verdict.text}`,
          ...Object.entries((b.hosts ?? {}) as Record<string, { findings?: Finding[] }>).flatMap(([h, v]) =>
            (v.findings ?? []).filter(shown).map((f) => `- ${h}, ${f.level}: ${f.text}`)
          ),
          ...((b.plan ?? []) as Finding[]).filter(shown).map((f) => `- ${f.level}: ${f.text}`),
        ].join("\n");
      }
    } catch {
      // As a failed run.
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
    return `**Preflight failed** on this branch. Run \`nix run .#preflight -- --head ${branch}\` to see why.`;
  }

  /**
   * One running issue: take its result back to Linear, or flag it as quiet.
   * A waiting issue's result is taken too: results are archived once read, so
   * one there now is new, from an agent Nick answered through `claude attach`.
   */
  async finish(f: string): Promise<void> {
    const s = read(f);
    const result = resultPath(s.repo, s.ident);
    const has = existsSync(result);
    if (s.phase !== "running" && !(s.phase === "waiting" && has)) return;
    let why: string | undefined;
    let kind = "";
    let body = "";
    let verdict = "";
    if (!has) {
      why = this.quiet(f, s);
      if (!why) return;
    } else {
      const text = readFileSync(result, "utf8");
      kind = (text.split("\n")[0] ?? "").replace(/\s/g, "");
      body = text.split("\n").slice(1).join("\n").replace(/\n+$/, "");
      // Preflight first: it takes minutes, and the issue's state is read
      // after it, so a re-queue made meanwhile counts.
      if (kind === "handoff") verdict = this.brief(s.repo, s.branch);
      // The agent has just reported, so the roster surely lists it: keep its
      // id for a resume after the roster forgets.
      const session = agent(s.name, s.worktree)?.sessionId;
      if (session) update(f, (u) => (u.session = session));
    }
    let i: Issue;
    try {
      i = await getIssue(this.linear, s.id);
    } catch (e) {
      if (!(e instanceof LinearError && e.kind === "notFound")) throw e;
      return this.forget(f, "closed while running");
    }
    if (closed(i)) return this.forget(f, "closed while running");

    const attach = `\`claude attach ${s.name}\``;
    if (why) {
      await this.report(i, NEEDS, `${why} ${attach} shows where it is; move this back to ${QUEUED} to nudge it.`, "Went quiet");
    } else {
      if (kind === "handoff") {
        const level = /^\*\*Preflight: ([^.]*)\./.exec(verdict)?.[1];
        await this.report(
          i,
          READY,
          `Handoff ready on \`${s.branch}\`.\n\n${body}\n${verdict ? `\n${verdict}\n` : ""}\nTo publish: \`cd ${s.worktree} && pr-handoff\`. To talk to the agent: ${attach}.`,
          `Handoff ready${level ? ` (${level})` : ""}`,
        );
      } else {
        await this.report(
          i,
          NEEDS,
          `The agent stopped and needs you.\n\n${body}\n\nAnswer in a comment and move this back to ${QUEUED} to resume it, or ${attach}.`,
          "Needs you",
        );
      }
      archive(result);
    }
    update(f, (u) => (u.phase = "waiting"));
  }

  /** Continues the issue's session in its worktree. False, with the issue stopped and why, when it could not. */
  async resume(i: Issue, f: string): Promise<boolean> {
    const s = read(f);
    // The roster first; the id saved earlier covers a roster that has
    // forgotten the session.
    const found = agent(s.name, s.worktree);
    const session = found?.sessionId || s.session;
    if (!session) {
      await this.stop(i, NEEDS, `Could not find the agent's session to resume in \`${s.worktree}\`.`, "Did not resume");
      return false;
    }
    const result = resultPath(s.repo, s.ident);
    // finish took any result written before this run; one written since is
    // moot, as the resume asks for a new one.
    archive(result);
    writeIssue(i, this.viewer, result);
    // --resume continues the session under the same id only if it is stopped
    // and given no flags; otherwise it starts a copy under a new id. Its
    // name and permission mode are saved with it, and passing them again
    // counts as new flags.
    if (found) {
      cl(["stop", found.id]);
      // The roster can still call a session busy just after it stops, and a
      // resume then starts a copy. So wait, up to a minute, for it to say the
      // session has ended, or to forget it.
      for (let n = 0; n < 30; n++) {
        const st = agent(s.name, s.worktree)?.state;
        if (st === undefined || !atWork(st)) break;
        await sleep(2000);
      }
    }
    const r = cl(["--bg", "--resume", session, promptResume(i, this.viewer, s.since, result)], s.worktree);
    if (r.status !== 0) {
      await this.stop(i, NEEDS, `Could not resume the session in \`${s.worktree}\`.`, "Did not resume");
      return false;
    }
    relay(r.stderr);
    // claude says so when it started a copy instead, which would put two
    // agents in one worktree: stop it and let Nick decide.
    const copy = /started a copy as ([0-9a-f]+)/.exec(r.stderr)?.[1];
    if (copy) {
      cl(["stop", copy]);
      await this.stop(
        i,
        NEEDS,
        `Not resumed: claude started a copy (${copy}) instead of continuing the session, and the copy was stopped. \`claude attach ${found?.id ?? session}\` opens the original.`,
        "Did not resume",
      );
      return false;
    }
    // quiet's clock starts over.
    update(f, (u) => {
      Object.assign(u, { phase: "running", started: now(), since: now(), session });
      for (const k of ["worked", "ticked", "ended"] as const) delete u[k];
    });
    return true;
  }

  /** One queued issue: start an agent on it, or resume the one it had. */
  async start(id: string): Promise<void> {
    const i = await getIssue(this.linear, id);
    if (i.state.name !== QUEUED) return;
    const f = `${this.env.stateDir}/${i.identifier}.json`;

    // Whoever last moved it into Queued, or created it there. Anything synced
    // in from elsewhere can reach the state; only Nick's own hand starts an
    // agent. The creator stands in only when no move into Queued is recorded
    // at all: a move with no actor, as an automation makes, is nobody's.
    if (i.history.pageInfo.hasNextPage) {
      return this.stop(i, NEEDS, "Not started: its history is too long to tell who queued it. Start it with `claude` instead.", "Not started");
    }
    const moves = i.history.nodes.filter((h) => h.toState?.name === QUEUED);
    const last = moves.reduce<(typeof moves)[number] | undefined>((a, h) => (!a || h.createdAt > a.createdAt ? h : a), undefined);
    const queuer = last ? last.actorId : i.creator?.id;
    if (!queuer) {
      return this.stop(
        i,
        NEEDS,
        `Not started: Linear recorded no person moving it to ${QUEUED}, as for an automation's move. Only issues you move to ${QUEUED} yourself are taken.`,
        "Not queued by you",
      );
    }
    if (queuer !== this.viewer) {
      return this.stop(i, NEEDS, `Not started: only issues you move to ${QUEUED} yourself are taken.`, "Not queued by you");
    }
    // The title and description become the agent's task, given as Nick's, so
    // they must be his too.
    if (i.creator?.id !== this.viewer) {
      return this.stop(
        i,
        NEEDS,
        "Not started: only issues you created are taken, since the agent is given the description as your task.",
        "Not yours",
      );
    }

    if (existsSync(f)) {
      // Re-queued while its agent works: resumed once its result is in (report).
      if (read(f).phase === "running") return;
      if (!(await this.resume(i, f))) return;
    } else if (!(await this.fresh(i, f))) {
      return;
    }
    await move(this.linear, i, RUNNING);
    say(`night-shift: started ${i.identifier}`);
  }

  /** A new worktree and agent for the issue, and its state file. False, with the issue stopped, when not. */
  async fresh(i: Issue, f: string): Promise<boolean> {
    const projects = this.env.projects;
    const label = i.labels.nodes.find((l) => l.parent?.name === "repo")?.name ?? "";
    const repo = `${projects}/${label}`;
    if (!/^[A-Za-z0-9._-]+$/.test(label) || git(repo, "remote", "get-url", "origin").status !== 0) {
      await this.stop(i, NEEDS, `Not started: give it a \`repo\` label naming a repository in ${projects} with an \`origin\`.`, "No repo");
      return false;
    }
    // Offline, say: leave it queued for the next run.
    const fb = fetchBase(repo) ?? die(`${i.identifier}: could not fetch ${label}; trying again next run`);
    const base = `origin/${fb.branch}`;
    const name = `${i.identifier.toLowerCase()}-${slug(i.title)}`;
    const worktree = `${repo}/.claude/worktrees/${name}`;
    const branch = `worktree-${name}`;
    if (!addWorktree(repo, branch, worktree, fb.sha)) {
      await this.stop(i, NEEDS, `Not started: could not make the worktree \`${worktree}\` on \`${branch}\`. One may be left from an earlier run.`, "No worktree");
      return false;
    }
    const result = resultPath(repo, i.identifier);
    writeIssue(i, this.viewer, result);
    const prompt = promptNew(i, this.viewer, { repo, worktree, branch, base, result });
    const r = cl(["--bg", "-n", name, "--permission-mode", "auto", prompt], worktree);
    if (r.status !== 0) {
      // stderr says why, no claude or a directory never trusted say.
      const said = firstLine(r.stderr);
      let text = said
        ? `Not started: \`claude --bg\` failed in \`${worktree}\`, saying \`${said}\`.`
        : `Not started: \`claude --bg\` failed in \`${worktree}\`, saying nothing.`;
      const kept = discardStart(repo, worktree, branch, fb.sha);
      text += kept
        ? ` Kept the worktree and \`${branch}\`, since ${kept}`
        : ` The worktree and \`${branch}\` are removed, so moving it to ${QUEUED} again starts afresh.`;
      await this.stop(i, NEEDS, text, "Did not start");
      return false;
    }
    relay(r.stderr);
    // since: when the agent last heard from Nick, so a resume passes on every
    // comment made after it. The session may be "" if the roster lags;
    // finish and a resume ask again.
    const at = now();
    write(f, {
      id: i.id, ident: i.identifier, repo, worktree, branch, name,
      session: agent(name, worktree)?.sessionId ?? "", phase: "running", started: at, since: at,
    });
    return true;
  }

  /**
   * One handoff whose PR Nick merged: clean up after its agent, then move it
   * to Done. The worktree goes only when nothing in it can be lost: the
   * branch's tip is the head the PR merged, nothing is uncommitted, and no
   * session in it is still at work. Squash merges leave the branch out of
   * main's history, so `git branch --merged` cannot say. Otherwise all of it
   * stays, and the comment says why.
   *
   * The worktree goes first, by git, before `claude rm` sees the sessions,
   * which removes only a worktree it recorded making (`claude --bg -w`).
   */
  async land(f: string): Promise<void> {
    const s = read(f);
    const m = s.merged!;
    const i = await getIssue(this.linear, s.id);
    // Moved on since tidy asked: the next run looks again.
    if (i.state.name !== READY) return;
    const completed = i.team.states.nodes.filter((t) => t.type === "completed").sort((a, b) => a.position - b.position)[0]?.name ??
      die(`${s.ident}'s team has no completed state`);

    const at = tip(s.repo, s.branch);
    // Every session in the worktree, by name or not: a resume that started a
    // copy leaves two.
    const sessions: Session[] | undefined = roster()?.filter((x) => x.cwd === s.worktree);
    const removed: string[] = [];
    let keep = "";
    if (!sessions) {
      keep = "Claude's sessions could not be listed.";
    } else if (at && at !== m.sha) {
      keep = `\`${s.branch}\` is at ${at.slice(0, 12)}, and the PR merged ${m.sha.slice(0, 12)}.`;
    } else if (sessions.some((x) => !ENDED.includes(x.state))) {
      keep = `a session there is still at work: ${sessions.filter((x) => !ENDED.includes(x.state)).map((x) => `${x.id} is ${x.state}`).join(", ")}.`;
    } else if (existsSync(s.worktree)) {
      const st = git(s.worktree, "status", "--porcelain", "--untracked-files=all");
      const dirty = (st.stdout + st.stderr).replace(/\n+$/, "");
      if (!at || !onBranch(s.worktree, s.branch)) {
        keep = `it is no longer on \`${s.branch}\`.`;
      } else if (st.status !== 0 || dirty) {
        keep = `it has changes not committed:\n\`\`\`\n${dirty.split("\n").slice(0, 10).join("\n")}\n\`\`\``;
      } else {
        const r = git(s.repo, "worktree", "remove", "--force", s.worktree);
        if (r.status !== 0) keep = `git would not remove it: ${(r.stdout + r.stderr).trim()}`;
        else removed.push("its worktree");
      }
    } else {
      // Gone already, Nick's doing: drop git's record of it, or the branch
      // counts as checked out there and cannot be deleted.
      git(s.repo, "worktree", "prune");
    }

    let text = `Merged in [#${m.number}](${m.url}). `;
    if (keep) {
      text += `Kept its worktree \`${s.worktree}\`, the branch and the agent's session, since ${keep}`;
    } else {
      let note = "";
      let n = 0;
      for (const x of sessions!) {
        if (cl(["rm", x.id]).status === 0) n++;
        else note += ` \`claude rm ${x.id}\` failed.`;
      }
      if (n === 1) removed.push("the agent's session");
      else if (n > 1) removed.push(`the agent's ${n} sessions`);
      const d = at ? git(s.repo, "branch", "-D", s.branch) : undefined;
      if (d && d.status !== 0) {
        note += ` Deleting \`${s.branch}\` failed: ${(d.stdout + d.stderr).trim()}`;
      } else {
        if (at) removed.push(`the branch \`${s.branch}\``);
        // branch -D drops its section too, unless something already took the
        // branch and left the section behind.
        git(s.repo, "config", "--remove-section", `branch.${s.branch}`);
      }
      text += removed.length === 0
        ? "Nothing of the agent's was left to remove."
        : `Removed ${removed.length === 1 ? removed[0] : `${removed.slice(0, -1).join(", ")} and ${removed.at(-1)}`}.`;
      text += note;
    }
    // No push: Nick merged it himself.
    await comment(this.linear, i, text);
    await move(this.linear, i, completed);
    this.forget(f, `merged in #${m.number}, moved to ${completed}`);
  }

  /**
   * Forgets waiting issues Nick has closed, with their issue text and results.
   * Their worktrees stay, since one may hold work not yet published. Only an
   * answer from Linear counts: offline, nothing is forgotten. An issue in
   * Handoff ready whose PR has merged is landed instead.
   *
   * One request per 50 waiting issues, Linear's default page, so an issue
   * missing from an answer does not exist. includeArchived matches what an
   * issue's own query finds, so one archived while waiting is judged by its
   * state. GitHub allows 60 requests an hour without a token, for every
   * caller on forge's address, so it is asked once a run for each issue in
   * Handoff ready, the longest unasked first, and not again in a run it
   * refuses.
   */
  async tidy(): Promise<void> {
    const waiting = this.files()
      .map((f) => ({ f, s: read(f) }))
      .filter(({ s }) => s.phase === "waiting")
      .sort((a, b) => cmp(a.s.checked ?? "", b.s.checked ?? ""));
    let github = true;
    for (let n = 0; n < waiting.length; n += 50) {
      const chunk = waiting.slice(n, n + 50);
      let nodes: { id: string; state: { name: string; type: string } }[];
      try {
        nodes = (await this.linear.gql<{ issues: { nodes: typeof nodes } }>(
          "query($ids: [ID!]!) { issues(first: 50, includeArchived: true, filter: {id: {in: $ids}}) { nodes { id state { name type } } } }",
          { ids: chunk.map(({ s }) => s.id) },
        )).issues.nodes;
      } catch (e) {
        if (!(e instanceof LinearError)) throw e;
        warn(e.message);
        continue;
      }
      for (const { f, s } of chunk) {
        const i = nodes.find((x) => x.id === s.id);
        if (!i || closed(i)) {
          this.forget(f);
          continue;
        }
        if (!github || i.state.name !== READY) continue;
        const slug = githubRepo(s.repo);
        if (!slug) continue;
        update(f, (u) => (u.checked = now()));
        const pr = await mergedPr(this.env, slug, s.branch);
        if (pr === "refused") {
          warn("GitHub refused, likely its hourly limit; merged PRs are looked for next run");
          github = false;
        } else if (pr === "offline") {
          warn(`GitHub did not answer for ${s.ident}`);
        } else if (pr) {
          update(f, (u) => (u.merged = pr));
          await child("_land", f, () => this.land(f));
        }
      }
    }
  }

  async queue(): Promise<void> {
    const queued = (await this.linear.gql<{ issues: { nodes: { id: string; priority: number; createdAt: string }[] } }>(
      "query($s: String!) { issues(first: 50, filter: {state: {name: {eq: $s}}}) { nodes { id priority createdAt } } }",
      { s: QUEUED },
    )).issues.nodes;
    const rank = (p: number) => (p === 0 ? 5 : p);
    queued.sort((a, b) => cmp(rank(a.priority), rank(b.priority)) || cmp(a.createdAt, b.createdAt));
    for (const { id } of queued) {
      if (this.running() >= this.env.max) break;
      await child("_start", id, () => this.start(id));
    }
  }
}

/**
 * Each issue is handled on its own, so one that fails, a deleted issue or a
 * repo that will not fetch, costs that issue a warning and not the whole run.
 */
async function child(what: string, arg: string, work: () => Promise<void>): Promise<void> {
  try {
    await work();
  } catch (e) {
    warn(e instanceof Fatal || e instanceof LinearError ? e.message : String((e as Error)?.stack ?? e));
    warn(`${what} ${arg} failed; next run tries again`);
  }
}

/** The title as a branch name's tail: lower case, dashes, at most 32 characters. */
export function slug(title: string): string {
  return `${title}\n`.replace(/[A-Z]/g, (c) => c.toLowerCase()).replace(/[^a-z0-9]+/g, "-").replace(/^-/, "").slice(0, 32).replace(/-$/, "");
}

/**
 * Its first line with anything on it, for a comment's code span: at most
 * about 200 characters, terminal escapes and control characters dropped, and
 * backticks made quotes, which would otherwise end the span.
 */
export function firstLine(text: string): string {
  const clean = text
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
    .replaceAll("`", "'");
  const line = clean.split("\n").find((l) => l.trim())?.trim() ?? "";
  return line.length > 200 ? `${line.slice(0, 200)}...` : line;
}

const viewerOf = async (linear: Linear) => (await linear.gql<{ viewer: { id: string } }>("query { viewer { id } }")).viewer.id;

/** `night-shift run`: every state file's issue, then tidy, then the queue. */
export async function run(env: Env, linear: Linear): Promise<void> {
  const r = new Run(env, linear, await viewerOf(linear));
  for (const f of r.files()) await child("_finish", f, () => r.finish(f));
  await r.tidy();
  await r.queue();
}

/** One issue's half of a run, as the tests call it: _finish <viewer> <state file>, and the rest likewise. */
export async function one(env: Env, linear: Linear, verb: string, viewer: string, arg: string): Promise<void> {
  const r = new Run(env, linear, viewer);
  if (verb === "_finish") await r.finish(arg);
  else if (verb === "_start") await r.start(arg);
  else if (verb === "_land") await r.land(arg);
  else die(`no ${verb}`);
}
