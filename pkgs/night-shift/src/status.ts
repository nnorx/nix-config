import { existsSync, readdirSync, readFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { isFile, say } from "./util.ts";

interface State {
  ident: string;
  phase: string;
  started?: string | null;
  labelled?: string | null;
  name?: string | null;
  worktree?: string | null;
}

/** What each issue's agent is doing, from the state files. */
export function status(env: Env): void {
  let files: string[] = [];
  try {
    files = readdirSync(env.stateDir).filter((f) => !f.startsWith(".")).sort();
  } catch {
    // No state directory: nothing yet.
  }
  let any = false;
  for (const f of files.filter((f) => f.endsWith(".json"))) {
    any = true;
    const s = JSON.parse(readFileSync(`${env.stateDir}/${f}`, "utf8")) as State;
    say(`${s.ident}  ${s.phase}  since ${s.started ?? s.labelled ?? "null"}  ${s.name ?? ""}  ${s.worktree ?? ""}`);
    // Work mode's reports, which on forge are comments on the issue.
    const report = `${env.stateDir}/${s.ident}.report.md`;
    if (isFile(report)) {
      const lines = readFileSync(report, "utf8").replace(/\n$/, "").split("\n");
      for (const line of lines) say(`    ${line}`);
    }
  }
  // Work mode's settings for a session land kept after forgetting the
  // issue: delete one with `claude rm` of its session.
  for (const f of files.filter((f) => f.endsWith(".settings"))) {
    const ident = f.slice(0, -".settings".length);
    if (existsSync(`${env.stateDir}/${ident}.json`)) continue;
    any = true;
    say(`${ident}  merged, but its worktree and session were kept; ${env.stateDir}/${f} stays until you remove them`);
  }
  if (!any) say("nothing yet");
}
