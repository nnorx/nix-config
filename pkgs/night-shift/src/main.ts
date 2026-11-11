// The night shift's dispatcher: issues Nick queues in Linear, worked by
// background Claude Code agents, each ending in a PR handoff for him to
// publish. night-shift.sh is the entry point: it holds a run's lock, lets the
// machine sleep after it, and gives a Mac's run its deadline; everything else
// is here. docs/night-shift.md has the states an issue moves through and the
// two modes: forge, the default, against Nick's own team, and work, on a Mac
// against a team he shares.
//
// Nothing here publishes, merges or deploys. Agents run in Claude Code's
// sandbox under Nick's settings; only this, outside it, talks to Linear.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { writeBacklog, writeProjectDocs } from "./backlog.ts";
import { check, workCheck } from "./check.ts";
import { fileDrafts } from "./drafts.ts";
import { type Env, loadEnv, QUEUED } from "./env.ts";
import { type Doc, EXIT, Linear, LinearError, loadKey } from "./linear.ts";
import { afterRun, awake } from "./machine.ts";
import { one, run } from "./run.ts";
import { status } from "./status.ts";
import { die, Fatal, say, warn } from "./util.ts";
import { loadConfig, safe } from "./work.ts";

const USAGE = `usage: night-shift run      take finished work back to Linear, then start queued work
       night-shift file     create Linear issues from drafts in each repo's .git/linear-handoff/
       night-shift check    confirm the key, states, repo labels and tools
       night-shift status   what each issue's agent is doing
       night-shift resume <ID> <answer>
                            work mode: resume an agent that stopped, with your answer
       night-shift safe [claude args]
                            work mode: claude here, in the agents' sandbox
`;

function usage(): never {
  process.stderr.write(USAGE);
  process.exit(64);
}

const linear = (env: Env) => new Linear(loadKey(env), env.linearUrl);

/**
 * backlog.md, then the project docs. Snapshots never fail the work before
 * them, so any error is reported, not thrown, and one does not stop the other.
 */
async function snapshots(env: Env, l: Linear, then: string, fresh: Doc[] = []): Promise<boolean> {
  const steps: [string, () => Promise<void>][] = [
    ["backlog.md not written", () => writeBacklog(env, l)],
    ["project docs not exported", () => writeProjectDocs(env, l, fresh)],
  ];
  let ok = true;
  for (const [failed, step] of steps) {
    try {
      await step();
    } catch (e) {
      warn(`${e instanceof Error ? e.message : String(e)}; ${failed}; ${then}`);
      ok = false;
    }
  }
  return ok;
}

/**
 * Work mode's answer to an agent that stopped, picked up by the next run,
 * which resumes the session with it. That run starts now on a Mac, when
 * launchd has the job; without -k, a run already going is left be.
 */
function resume(env: Env, ident: string, answer: string): void {
  if (env.mode !== "work") die(`resume is work mode's; on forge, answer in Linear and move the issue back to ${QUEUED}`);
  const id = ident.toUpperCase();
  const f = `${env.stateDir}/${id}.json`;
  if (!existsSync(f) || JSON.parse(readFileSync(f, "utf8")).phase !== "waiting") {
    die(`${id} has no agent waiting; night-shift status lists them`);
  }
  writeFileSync(`${env.stateDir}/${id}.answer`, `${answer}\n`);
  const kicked = env.launchdLabel &&
    spawnSync("launchctl", ["kickstart", `gui/${process.getuid?.()}/${env.launchdLabel}`], { stdio: "ignore" }).status === 0;
  say(kicked
    ? `night-shift: ${id} resumes in the run starting now, or the next if one is already going`
    : `night-shift: ${id} resumes on the next run; \`night-shift run\` starts one now`);
}

async function main(argv: string[]): Promise<number> {
  const env = loadEnv();
  switch (argv[0]) {
    case "check":
      if (env.mode === "work") await workCheck(env, linear(env));
      else await check(env, linear(env));
      return 0;
    case "status":
      status(env);
      return 0;
    case "file": {
      if (env.mode !== "forge") die("file is forge's: in work mode, issues are filed in Linear by hand");
      const l = linear(env);
      const fresh = await fileDrafts(env, l);
      // So what was just filed is there without waiting for a run.
      await snapshots(env, l, "the next run will", fresh);
      return 0;
    }
    case "run": {
      // The config before the key: a run with no config fails as that.
      const work = env.mode === "work" ? loadConfig(env) : undefined;
      const l = linear(env);
      await run(env, l, work);
      if (!work) await snapshots(env, l, "the next run tries again");
      return 0;
    }
    // One issue's half of a run, as the tests call it.
    case "_finish":
    case "_start":
    case "_land": {
      if (argv.length !== 3) usage();
      const work = env.mode === "work" ? loadConfig(env) : undefined;
      await one(env, linear(env), work, argv[0], argv[1]!, argv[2]!);
      return 0;
    }
    case "_awake":
      awake(env);
      return 0;
    case "_after":
      await afterRun(env);
      return 0;
    case "resume":
      if (argv.length !== 3 || !argv[2]) usage();
      resume(env, argv[1]!, argv[2]!);
      return 0;
    case "safe":
      return safe(env, argv.slice(1));
    default:
      usage();
  }
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (e) {
  if (e instanceof Fatal) {
    warn(e.message);
    process.exitCode = 1;
  } else if (e instanceof LinearError) {
    warn(e.message);
    process.exitCode = EXIT[e.kind];
  } else {
    throw e;
  }
}
