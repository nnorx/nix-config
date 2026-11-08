// The night shift's commands in TypeScript. night-shift.sh is the entry
// point and execs this for them; its runs call `_backlog`.
// docs/night-shift.md has the rest.
import { writeBacklog, writeProjectDocs } from "./backlog.ts";
import { check, workCheck } from "./check.ts";
import { fileDrafts } from "./drafts.ts";
import { type Env, loadEnv } from "./env.ts";
import { type Doc, EXIT, Linear, LinearError, loadKey } from "./linear.ts";
import { status } from "./status.ts";
import { die, Fatal, warn } from "./util.ts";

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
    case "_backlog":
      return (await snapshots(env, linear(env), "the next run tries again")) ? 0 : 1;
    default:
      die(`night-shift.sh handles '${argv[0] ?? ""}', not this`);
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
