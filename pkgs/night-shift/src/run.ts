// A run: take finished work back to Linear, land what Nick merged, then start
// what he queued. docs/night-shift.md has the states an issue moves through,
// and how work mode, on a Mac against a team he shares, differs from forge's.
// night-shift.sh holds the run lock around this, and lets the machine sleep
// once it ends. Nothing here publishes, merges or deploys.
import { spawnSync } from "node:child_process";
import { existsSync, globSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { agent, atWork, cl, roster, type Session } from "./claude.ts";
import { type Env, NEEDS, QUEUED, READY, RUNNING } from "./env.ts";
import { closed, comment, getIssue, type Issue, move, trimEnd, writeIssue } from "./issues.ts";
import { type Linear, LinearError } from "./linear.ts";
import { latest, running } from "./machine.ts";
import { notify } from "./notify.ts";
import { promptNew, promptResume, workPromptNew, workPromptResume } from "./prompts.ts";
import {
  addWorktree, archive, discardStart, fetchBase, githubRepo, type Merged, mergedPr, onBranch, resultPath, tip,
} from "./repo.ts";
import { cmp, commonDir, die, Fatal, git, now, relay, say, warn } from "./util.ts";
import {
  bootstrap, type Labelled, labelled, mergedPrGh, overrides, refusal, type RepoConf, repoDir, type WorkConfig, writeLocalSettings,
  writeSettings,
} from "./work.ts";

/** An issue the dispatcher has taken, or in work mode refused, as <ID>.json in the state directory. */
interface State {
  id: string;
  ident: string;
  phase: "running" | "waiting" | "refused";
  repo: string;
  worktree: string;
  branch: string;
  name: string;
  session: string;
  started: string;
  /** When the agent last heard from Nick. */
  since: string;
  /** Seconds of work counted, and when last counted (quiet). */
  worked?: number;
  ticked?: string;
  ended?: string;
  ended_as?: string;
  checked?: string;
  merged?: Merged;
  // Work mode's: when the label was added, when Linear last showed the issue
  // unchanged, and the untracked files setup left.
  labelled?: string;
  seen?: string;
  setup?: string[];
}

const read = (f: string) => JSON.parse(readFileSync(f, "utf8")) as State;

function write(f: string, s: Partial<State>): void {
  writeFileSync(`${f}.tmp`, `${JSON.stringify(s, null, 2)}\n`);
  renameSync(`${f}.tmp`, f);
}

function update(f: string, change: (s: State) => void): void {
  const s = read(f);
  change(s);
  write(f, s);
}

const secs = (iso: string) => Math.floor(Date.parse(iso) / 1000);
const clock = () => Math.floor(Date.now() / 1000);

class Run {
  readonly env: Env;
  readonly linear: Linear;
  readonly viewer: string;
  /** Work mode's config; undefined on forge. */
  readonly work?: WorkConfig;

  constructor(env: Env, linear: Linear, viewer: string, work?: WorkConfig) {
    this.env = env;
    this.linear = linear;
    this.viewer = viewer;
    this.work = work;
  }

  get max(): number {
    return this.work?.max ?? this.env.max;
  }

  get stallHours(): number {
    return this.work?.stallHours ?? this.env.stallHours;
  }

  issue(id: string): Promise<Issue> {
    return getIssue(this.linear, id, this.env.mode);
  }

  cl(args: string[], cwd?: string) {
    return cl(this.env.platform, args, cwd);
  }

  agent(name: string, worktree: string) {
    return agent(this.env.platform, name, worktree);
  }

  files(): string[] {
    try {
      return readdirSync(this.env.stateDir).filter((f) => f.endsWith(".json")).sort().map((f) => `${this.env.stateDir}/${f}`);
    } catch {
      return [];
    }
  }

  running(): number {
    return running(this.env);
  }

  /** Drops an issue the dispatcher is done with, with its issue text and results, read or not. */
  forget(f: string, why?: string): void {
    const s = read(f);
    // Unless the repo is gone too.
    const common = s.repo ? commonDir(s.repo) : undefined;
    const dir = `${common}/night-shift`;
    if (common && existsSync(dir)) {
      for (const n of readdirSync(dir)) {
        if (n === `${s.ident}.issue.md` || n === `${s.ident}.md` || n.startsWith(`${s.ident}.md.`)) {
          rmSync(`${dir}/${n}`, { force: true });
        }
      }
    }
    // Work mode's, beside the state file. Not the settings an agent's session
    // was started with, which it reads again on every resume and which may
    // outlive this, a session land kept say; land removes them with it.
    for (const ext of ["report.md", "answer", "bootstrap.log"]) rmSync(`${this.env.stateDir}/${s.ident}.${ext}`, { force: true });
    rmSync(f);
    say(`night-shift: forgot ${s.ident}${why ? `, ${why}` : ""}`);
  }

  /**
   * A comment and a move on forge, and a push that names the issue by its
   * identifier, never by its title: ntfy.sh is a third party, and a title can
   * describe the house. In work mode the issue is left as it is, since
   * teammates read it: the text goes to <ID>.report.md, which `night-shift
   * status` shows, under what the state would have been.
   */
  async stop(i: Issue, state: string, markdown: string, what: string): Promise<void> {
    if (this.work) {
      mkdirSync(this.env.stateDir, { recursive: true });
      writeFileSync(`${this.env.stateDir}/${i.identifier}.report.md`, `# ${i.identifier}: ${state}\n\n_${now()}_\n\n${markdown}\n`);
    } else {
      await comment(this.linear, i, markdown);
      await move(this.linear, i, state);
    }
    await notify(this.env, "Night shift", `${i.identifier}: ${what}`, i.url);
    say(`night-shift: ${i.identifier}: ${what}`);
  }

  /**
   * stop for a result, except that on forge an issue Nick moved back to
   * Queued while its agent worked stays there, and this run resumes it with
   * his comments.
   */
  async report(i: Issue, state: string, markdown: string, what: string): Promise<void> {
    if (this.work || i.state.name !== QUEUED) return this.stop(i, state, markdown, what);
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
  async quiet(f: string, s: State): Promise<string | undefined> {
    const tick = 2 * this.env.interval;
    const settle = 5 * 60;
    const t = clock();
    const gap = t - secs(s.ticked ?? s.started);
    const worked = (s.worked ?? 0) + (gap < tick ? Math.max(gap, 0) : tick);
    const seen = (await this.agent(s.name, s.worktree))?.state;
    // A roster that does not list the session, or could not be read, says
    // nothing either way, so an end already seen stands.
    let ended: string | undefined;
    let as: string | undefined;
    if (seen === undefined) [ended, as] = [s.ended, s.ended_as];
    else if (!atWork(seen)) [ended, as] = [s.ended ?? now(), seen];
    update(f, (u) => {
      u.worked = worked;
      u.ticked = now();
      if (ended) {
        [u.ended, u.ended_as] = [ended, as ?? ""];
      } else {
        delete u.ended;
        delete u.ended_as;
      }
    });
    if (ended && t - secs(ended) >= settle) {
      return as === "blocked"
        ? "The agent is waiting on a prompt, with no result."
        : `The agent's session ended (${as ?? ""}) without writing a result.`;
    }
    if (worked >= this.stallHours * 3600) return `No result after ${this.stallHours} hours of work.`;
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
    if (s.phase === "refused") return;
    const result = resultPath(s.repo, s.ident);
    const has = existsSync(result);
    if (s.phase !== "running" && !has) return;
    let why: string | undefined;
    let kind = "";
    let body = "";
    let verdict = "";
    if (!has) {
      why = await this.quiet(f, s);
      if (!why) return;
    } else {
      const text = readFileSync(result, "utf8");
      kind = (text.split("\n")[0] ?? "").replace(/\s/g, "");
      body = trimEnd(text.split("\n").slice(1).join("\n"));
      // Preflight first: it takes minutes, and the issue's state is read
      // after it, so a re-queue made meanwhile counts. Not in work mode, whose
      // repos have no preflight and whose Mac has no bwrap to confine one:
      // there the agent's checks in its sandbox and CI's on the PR stand in.
      if (kind === "handoff" && !this.work) verdict = this.brief(s.repo, s.branch);
      // The agent has just reported, so the roster surely lists it: keep its
      // id for a resume after the roster forgets.
      const session = (await this.agent(s.name, s.worktree))?.sessionId;
      if (session) update(f, (u) => (u.session = session));
    }
    let i: Issue;
    try {
      i = await this.issue(s.id);
    } catch (e) {
      if (!(e instanceof LinearError && e.kind === "notFound")) throw e;
      return this.forget(f, "closed while running");
    }
    // In work mode Linear completes an issue when its PR merges, and one that
    // waited on Nick may have reported again since. tidy lands it as this
    // run's next step; forgetting it here would leave all that behind.
    if (this.work && s.phase === "waiting" && closed(i)) return;
    if (closed(i)) return this.forget(f, "closed while running");

    // How Nick answers: in Linear on forge; here in work mode, where the
    // agent reads nothing from the issue but its text when it started.
    const attach = `\`claude attach ${s.name}\``;
    const nudge = this.work ? `\`night-shift resume ${s.ident} "<what to do>"\` nudges it` : `move this back to ${QUEUED} to nudge it`;
    const answer = this.work
      ? `Answer with \`night-shift resume ${s.ident} "<answer>"\` to resume it`
      : `Answer in a comment and move this back to ${QUEUED} to resume it`;
    if (why) {
      await this.report(i, NEEDS, `${why} ${attach} shows where it is; ${nudge}.`, "Went quiet");
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
        await this.report(i, NEEDS, `The agent stopped and needs you.\n\n${body}\n\n${answer}, or ${attach}.`, "Needs you");
      }
      archive(result);
    }
    update(f, (u) => (u.phase = "waiting"));
  }

  /**
   * Continues the issue's session in its worktree, told what the prompt says
   * given when the agent last heard from Nick and the result path. False,
   * with the issue stopped and why, when it could not.
   */
  async resume(i: Issue, f: string, prompt: (since: string, result: string) => string): Promise<boolean> {
    const s = read(f);
    // The roster first; the id saved earlier covers a roster that has
    // forgotten the session.
    const found = await this.agent(s.name, s.worktree);
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
    // and given no flags; otherwise it starts a copy under a new id. Its name,
    // permission mode and, in work mode, its --settings and
    // --strict-mcp-config are saved with it, and passing them again counts as
    // new flags.
    if (found) {
      await this.cl(["stop", found.id]);
      // The roster can still call a session busy just after it stops, and a
      // resume then starts a copy. So wait, up to a minute, for it to say the
      // session has ended, or to forget it.
      for (let n = 0; n < 30; n++) {
        const st = (await this.agent(s.name, s.worktree))?.state;
        if (st === undefined || !atWork(st)) break;
        await sleep(2000);
      }
    }
    const r = await this.cl(["--bg", "--resume", session, prompt(s.since, result)], s.worktree);
    if (r.status !== 0) {
      await this.stop(i, NEEDS, `Could not resume the session in \`${s.worktree}\`.`, "Did not resume");
      return false;
    }
    relay(r.stderr);
    // claude says so when it started a copy instead, which would put two
    // agents in one worktree: stop it and let Nick decide. A copy keeps none
    // of the saved flags, so in work mode it is sandboxed only by the
    // worktree's own settings (writeLocalSettings).
    const copy = /started a copy as ([0-9a-f]+)/.exec(r.stderr)?.[1];
    if (copy) {
      await this.cl(["stop", copy]);
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

  /** One queued issue on forge: start an agent on it, or resume the one it had. */
  async start(id: string): Promise<void> {
    const i = await this.issue(id);
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
    const last = latest(moves);
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
      if (!(await this.resume(i, f, (since, result) => promptResume(i, this.viewer, since, result)))) return;
    } else if (!(await this.fresh(i, f))) {
      return;
    }
    await move(this.linear, i, RUNNING);
    say(`night-shift: started ${i.identifier}`);
  }

  /** A new worktree and agent for a forge issue, and its state file. False, with the issue stopped, when not. */
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
    const r = await this.cl(["--bg", "-n", name, "--permission-mode", "auto", prompt], worktree);
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
      session: (await this.agent(name, worktree))?.sessionId ?? "", phase: "running", started: at, since: at,
    });
    return true;
  }

  /** Work mode: not taken, and said once. The state file remembers which labelling was refused. */
  async refuse(i: Issue, l: Labelled | undefined, why: string): Promise<void> {
    write(`${this.env.stateDir}/${i.identifier}.json`, {
      id: i.id, ident: i.identifier, phase: "refused", labelled: l?.createdAt ?? "", seen: i.updatedAt ?? "",
    });
    await this.stop(i, "Not started", `Not started: ${why}. Add the label again to try again.`, "Not started");
  }

  /** Work mode: looked at and left as it was. The queue asks for it again only once it has changed since. */
  seen(i: Issue, f: string): void {
    update(f, (u) => (u.seen = i.updatedAt ?? ""));
  }

  /** Work mode: undoes a start that ended before an agent ran. */
  discard(repo: string, worktree: string, branch: string, ident: string): void {
    git(repo, "worktree", "remove", "--force", worktree);
    git(repo, "branch", "-D", branch);
    rmSync(`${this.env.stateDir}/${ident}.settings`, { force: true });
  }

  /** Work mode: one issue assigned to Nick with his label. Start an agent on it, resume the one it had, or say why not, once. */
  async workStart(id: string): Promise<void> {
    const work = this.work!;
    const i = await this.issue(id);
    if (closed(i)) return;
    const ident = i.identifier;
    const f = `${this.env.stateDir}/${ident}.json`;
    const l = labelled(i, work.label);

    if (existsSync(f)) {
      const s = read(f);
      if (s.phase === "running") return;
      if (s.phase === "waiting") {
        const file = `${this.env.stateDir}/${ident}.answer`;
        let answer = "";
        if (existsSync(file)) {
          answer = trimEnd(readFileSync(file, "utf8"));
          rmSync(file);
        } else if (!l || !(l.createdAt > s.since) || refusal(i, l, this.viewer)) {
          return this.seen(i, f);
        }
        // Either way its trigger is spent, so a resume that fails is said
        // once, not every run.
        const ok = await this.resume(i, f, (since, result) => workPromptResume(i, this.viewer, since, result, answer));
        update(f, (u) => (ok ? delete u.seen : (u.since = now())));
        return;
      }
      if (!l || !(l.createdAt > (s.labelled ?? ""))) return this.seen(i, f);
      rmSync(f);
    }

    const why = refusal(i, l, this.viewer);
    if (why) return this.refuse(i, l, why);
    const key = i.team.key ?? "";
    const conf = work.repos[key];
    const repo = repoDir(this.env, conf);
    if (!repo || git(repo, "remote", "get-url", "origin").status !== 0) {
      return this.refuse(i, l, `no repository with an \`origin\` is set for team ${key} in ${this.env.config}`);
    }
    // Not <ID>.json or any *.json: that is the state files' glob.
    const settings = `${this.env.stateDir}/${ident}.settings`;
    if (!this.env.settings || !existsSync(this.env.settings)) {
      return this.refuse(i, l, `the sandbox settings at '${this.env.settings ?? ""}' are missing, so no agent starts; \`hms\` writes them`);
    }
    // Offline, or the SSH agent locked: left for the next run.
    const fb = fetchBase(repo) ?? die(`${ident}: could not fetch ${basename(repo)}; trying again next run`);
    const base = `origin/${fb.branch}`;
    const slugged = slug(i.title);
    const name = `${ident.toLowerCase()}-${slugged}`;
    const worktree = `${repo}/.claude/worktrees/${name}`;
    // The identifier in the branch is what links the PR to the issue.
    const branch = (conf!.branch ?? "night-shift/{id}-{slug}")
      .replaceAll("{ID}", ident).replaceAll("{id}", ident.toLowerCase()).replaceAll("{slug}", slugged);
    if (git(repo, "check-ref-format", "--branch", branch).status !== 0) {
      return this.refuse(i, l, `the branch template gives \`${branch}\`, which is not a branch name`);
    }
    if (!addWorktree(repo, branch, worktree, fb.sha)) {
      return this.refuse(i, l, `could not make the worktree \`${worktree}\` on \`${branch}\`. One may be left from an earlier run`);
    }
    // No agent has run in the worktree yet, so on any refusal from here, or
    // anything thrown, it goes, with its branch, and adding the label again
    // starts afresh.
    try {
      await this.setUp(i, l, { repo, worktree, branch, base, settings, name }, conf!);
    } catch (e) {
      this.discard(repo, worktree, branch, ident);
      throw e;
    }
  }

  /** Work mode: the rest of a start, in a worktree made for it, which goes on a refusal. */
  async setUp(
    i: Issue,
    l: Labelled | undefined,
    w: { repo: string; worktree: string; branch: string; base: string; settings: string; name: string },
    conf: RepoConf,
  ): Promise<void> {
    const { repo, worktree, branch, base, settings, name } = w;
    const ident = i.identifier;
    const f = `${this.env.stateDir}/${ident}.json`;
    const over = overrides(this.env, repo, worktree);
    if (over.length) {
      this.discard(repo, worktree, branch, ident);
      return this.refuse(i, l, `these settings would change the agent's sandbox or run a command outside it: ${over.join(" ")}`);
    }
    const log = `${this.env.stateDir}/${ident}.bootstrap.log`;
    if (!bootstrap(this.env, conf, worktree, log)) {
      this.discard(repo, worktree, branch, ident);
      return this.refuse(i, l, `setting up the worktree failed, and it is removed. \`${log}\` says why`);
    }
    if (!writeSettings(this.env, conf, settings, worktree, repo) || !writeLocalSettings(settings, worktree)) {
      this.discard(repo, worktree, branch, ident);
      return this.refuse(
        i,
        l,
        `the agent's settings could not be written: the repository's \`sandbox\` in ${this.env.config} does not fit them, or a Claude settings file is not JSON. The worktree is removed`,
      );
    }
    // The files setup left untracked, before the agent has written anything,
    // for land to tell from the agent's work. Not tracked files setup changed:
    // the agent may change one of those too, a lockfile say.
    const setup = git(worktree, "status", "--porcelain", "--untracked-files=all").stdout.split("\n").filter((x) => x.startsWith("?? "));
    const result = resultPath(repo, ident);
    writeIssue(i, this.viewer, result);
    // No MCP servers: the repo's own include Linear's, through which a session
    // acting as Nick could add the label to an issue and queue it.
    const prompt = workPromptNew(i, this.viewer, { repo, worktree, branch, base, result }, conf.checks);
    const r = await this.cl(["--bg", "-n", name, "--settings", settings, "--strict-mcp-config", "--permission-mode", "auto", prompt], worktree);
    if (r.status !== 0) {
      this.discard(repo, worktree, branch, ident);
      const said = firstLine(r.stderr);
      return this.refuse(i, l, `\`claude --bg\` failed${said ? `, saying \`${said}\`,` : ""} and the worktree is removed`);
    }
    relay(r.stderr);
    const at = now();
    write(f, {
      id: i.id, ident, repo, worktree, branch, name, session: (await this.agent(name, worktree))?.sessionId ?? "",
      phase: "running", started: at, since: at, labelled: l?.createdAt ?? "", setup,
    });
    if (i.state.name !== this.work!.startedState) await move(this.linear, i, this.work!.startedState);
    say(`night-shift: started ${ident}`);
  }

  /**
   * One handoff whose PR Nick merged: clean up after its agent, then on forge
   * move it to Done. The worktree goes only when nothing in it can be lost:
   * the branch's tip is the head the PR merged, nothing is uncommitted, and no
   * session in it is still at work. Squash merges leave the branch out of
   * main's history, so `git branch --merged` cannot say. Otherwise all of it
   * stays, and the comment, or in work mode the log, says why.
   *
   * The worktree goes first, by git, before `claude rm` sees the sessions,
   * which removes only a worktree it recorded making (`claude --bg -w`).
   */
  async land(f: string): Promise<void> {
    const s = read(f);
    const m = s.merged!;
    const i = await this.issue(s.id);
    // Moved on since tidy asked: the next run looks again. In work mode
    // Linear's GitHub integration has completed it already.
    let completed: string;
    if (this.work) {
      if (i.state.type !== "completed") return;
      completed = i.state.name;
    } else {
      if (i.state.name !== READY) return;
      completed = i.team.states.nodes.filter((t) => t.type === "completed").sort((a, b) => a.position - b.position)[0]?.name ??
        die(`${s.ident}'s team has no completed state`);
    }

    const at = tip(s.repo, s.branch);
    // Every session in the worktree, by name or not: a resume that started a
    // copy leaves two.
    const sessions: Session[] | undefined = (await roster(this.env.platform))?.filter((x) => x.cwd === s.worktree);
    const busy = sessions?.filter((x) => atWork(x.state)) ?? [];
    const removed: string[] = [];
    let keep = "";
    if (!sessions) {
      keep = "Claude's sessions could not be listed.";
    } else if (at && at !== m.sha) {
      keep = `\`${s.branch}\` is at ${at.slice(0, 12)}, and the PR merged ${m.sha.slice(0, 12)}.`;
    } else if (busy.length) {
      keep = `a session there is still at work: ${busy.map((x) => `${x.id} is ${x.state}`).join(", ")}.`;
    } else if (existsSync(s.worktree)) {
      if (!at || !onBranch(s.worktree, s.branch)) {
        keep = `it is no longer on \`${s.branch}\`.`;
      } else {
        // Untracked files that setup left are not the agent's work. File by
        // file, so one the agent added inside a directory of setup's shows.
        const st = git(s.worktree, "status", "--porcelain", "--untracked-files=all");
        const dirty = trimEnd(st.stdout + st.stderr).split("\n").filter((x) => x && !(s.setup ?? []).includes(x)).join("\n");
        if (st.status !== 0 || dirty) {
          keep = `it has changes not committed:\n\`\`\`\n${dirty.split("\n").slice(0, 10).join("\n")}\n\`\`\``;
        } else {
          // --force for what setup left. Nothing else is uncommitted by now.
          const r = git(s.repo, "worktree", "remove", "--force", s.worktree);
          if (r.status !== 0) keep = `git would not remove it: ${(r.stdout + r.stderr).trim()}`;
          else removed.push("its worktree");
        }
      }
    } else {
      // Gone already, Nick's doing: drop git's record of it, or the branch
      // counts as checked out there and cannot be deleted.
      git(s.repo, "worktree", "prune");
    }

    let text = `Merged in [#${m.number}](${m.url}). `;
    const settings = `${this.env.stateDir}/${s.ident}.settings`;
    if (keep) {
      text += `Kept its worktree \`${s.worktree}\`, the branch and the agent's session, since ${keep}`;
    } else {
      let note = "";
      let n = 0;
      for (const x of sessions!) {
        if ((await this.cl(["rm", x.id])).status === 0) n++;
        else note += ` \`claude rm ${x.id}\` failed.`;
      }
      // Work mode's sandbox for the sessions just removed (forget keeps it).
      rmSync(settings, { force: true });
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
    // No push: Nick merged it himself. In work mode nothing goes to the
    // issue, which teammates read; the log has what was removed or kept.
    if (this.work) {
      say(`night-shift: ${s.ident}: ${text}`);
      if (keep) {
        // The session kept may still be attached to or resumed, with the
        // settings it was started with, so they stay; status lists them.
        if (existsSync(settings)) say(`night-shift: ${s.ident}: its sandbox settings stay at ${settings} until the session goes`);
        await notify(this.env, "Night shift", `${s.ident}: merged, worktree kept`);
      }
      return this.forget(f, `merged in #${m.number}`);
    }
    await comment(this.linear, i, text);
    await move(this.linear, i, completed);
    this.forget(f, `merged in #${m.number}, moved to ${completed}`);
  }

  /**
   * Forgets waiting issues Nick has closed, with their issue text and results.
   * Their worktrees stay, since one may hold work not yet published. Only an
   * answer from Linear counts: offline, nothing is forgotten. An issue whose
   * PR has merged is landed instead.
   *
   * One request per 50 issues, Linear's default page, so an issue missing
   * from an answer does not exist. includeArchived matches what an issue's
   * own query finds, so one archived while waiting is judged by its state.
   * GitHub allows 60 requests an hour without a token, for every caller on
   * forge's address, so it is asked once a run for each issue in Handoff
   * ready, the longest unasked first, and not again in a run it refuses. In
   * work mode refused issues are asked about too, so one that closes is
   * forgotten, and gh, with Nick's login, says what merged.
   */
  async tidy(): Promise<void> {
    const phases = this.work ? ["waiting", "refused"] : ["waiting"];
    const waiting = this.files()
      .map((f) => ({ f, s: read(f) }))
      .filter(({ s }) => phases.includes(s.phase))
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
        if (!i) {
          this.forget(f);
        } else if (this.work) {
          await this.workTidy(i, f, s);
        } else if (closed(i)) {
          this.forget(f);
        } else if (github && i.state.name === READY) {
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
  }

  /**
   * Work mode's tidy for an issue Linear has. A canceled one is forgotten. A
   * completed one that waited for Nick is landed when gh finds the merged PR
   * from its branch, and forgotten otherwise, its worktree kept, as forge
   * does with an issue closed by hand.
   */
  async workTidy(i: { state: { type: string } }, f: string, s: State): Promise<void> {
    if (i.state.type === "canceled") return this.forget(f);
    if (i.state.type !== "completed") return;
    if (s.phase !== "waiting") return this.forget(f, "completed");
    const slug = githubRepo(s.repo);
    const pr = slug ? mergedPrGh(slug, s.branch) : null;
    if (pr === "failed") {
      warn(`gh could not say whether ${s.ident} merged; the next run asks again`);
    } else if (pr) {
      update(f, (u) => (u.merged = pr));
      await child("_land", f, () => this.land(f));
    } else {
      this.forget(f, "completed with no merged PR from its branch; its worktree stays");
    }
  }

  /** Forge's queue: what Nick moved to Queued, highest priority first. */
  async queue(): Promise<void> {
    const queued = (await this.linear.gql<{ issues: { nodes: { id: string; priority: number; createdAt: string }[] } }>(
      "query($s: String!) { issues(first: 50, filter: {state: {name: {eq: $s}}}) { nodes { id priority createdAt } } }",
      { s: QUEUED },
    )).issues.nodes;
    for (const { id } of byRank(queued)) {
      if (this.running() >= this.max) break;
      await child("_start", id, () => this.start(id));
    }
  }

  /**
   * Work mode's: answers left with `night-shift resume` first, since Nick is
   * waiting on those, then the issues assigned to him with his label, highest
   * priority first. Passed over: those with an agent at work, and those
   * waiting or refused that have not changed in Linear since workStart last
   * looked, which a label added again or a new comment would.
   */
  async workQueue(): Promise<void> {
    let answers: string[] = [];
    try {
      answers = readdirSync(this.env.stateDir).filter((n) => n.endsWith(".answer")).sort();
    } catch {
      // No state directory yet.
    }
    for (const a of answers) {
      if (this.running() >= this.max) return;
      const f = `${this.env.stateDir}/${a.slice(0, -".answer".length)}.json`;
      if (existsSync(f)) {
        const id = read(f).id;
        await child("_start", id, () => this.workStart(id));
      } else {
        rmSync(`${this.env.stateDir}/${a}`, { force: true });
      }
    }
    const known = new Map(this.files().map(read).map((s) => [s.id, s]));
    type Node = { id: string; priority: number; createdAt: string; updatedAt: string };
    const nodes = (await this.linear.gql<{ issues: { nodes: Node[] } }>(
      `query($l: String!) { issues(first: 50, filter: {assignee: {isMe: {eq: true}},
      labels: {some: {name: {eq: $l}}}, state: {type: {nin: ["completed", "canceled"]}}}) {
      nodes { id priority createdAt updatedAt } } }`,
      { l: this.work!.label },
    )).issues.nodes;
    const changed = (n: Node) => {
      const s = known.get(n.id);
      return !s || (s.phase === "waiting" && n.updatedAt > (s.seen ?? s.since)) || (s.phase === "refused" && n.updatedAt > (s.seen ?? ""));
    };
    for (const { id } of byRank(nodes).filter(changed)) {
      if (this.running() >= this.max) break;
      await child("_start", id, () => this.workStart(id));
    }
  }
}

const rank = (p: number) => (p === 0 ? 5 : p);
const byRank = <T extends { priority: number; createdAt: string }>(xs: T[]) =>
  [...xs].sort((a, b) => cmp(rank(a.priority), rank(b.priority)) || cmp(a.createdAt, b.createdAt));

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

/** `night-shift run`: every state file's issue, then tidy, then the queue. work: work mode's config. */
export async function run(env: Env, linear: Linear, work?: WorkConfig): Promise<void> {
  const r = new Run(env, linear, await viewerOf(linear), work);
  for (const f of r.files()) await child("_finish", f, () => r.finish(f));
  await r.tidy();
  if (r.work) await r.workQueue();
  else await r.queue();
}

/** One issue's half of a run, as the tests call it: _finish <viewer> <state file>, and the rest likewise. */
export async function one(env: Env, linear: Linear, work: WorkConfig | undefined, verb: string, viewer: string, arg: string): Promise<void> {
  const r = new Run(env, linear, viewer, work);
  if (verb === "_finish") await r.finish(arg);
  else if (verb === "_start") await (r.work ? r.workStart(arg) : r.start(arg));
  else if (verb === "_land") await r.land(arg);
  else die(`no ${verb}`);
}
