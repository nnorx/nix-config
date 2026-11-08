import { readFileSync } from "node:fs";
import { STATES, type Env } from "./env.ts";
import type { Linear } from "./linear.ts";
import { notify } from "./notify.ts";
import { git, isFile, run, say } from "./util.ts";
import { loadConfig, overrides, repoDir } from "./work.ts";

const WORK_FIELDS = readFileSync(new URL("../work-fields.graphql", import.meta.url), "utf8");

function claudeVersion(): void {
  const r = run("claude", ["--version"]);
  say(r.missing ? "claude: not on PATH" : `claude: ${r.stdout.trim()}`);
}

/** Forge: the key, the team's states, a repository for each repo label. */
export async function check(env: Env, linear: Linear): Promise<void> {
  const data = await linear.gql<{
    viewer: { displayName: string };
    teams: { nodes: { key: string; states: { nodes: { name: string }[] } }[] };
    issueLabels: { nodes: { name: string }[] };
  }>(`query { viewer { id displayName }
    teams { nodes { key name states { nodes { name } } } }
    issueLabels(first: 250, filter: {parent: {name: {eq: "repo"}}}) { nodes { name } } }`);
  say(`key: works, acting as ${data.viewer.displayName}`);
  for (const team of data.teams.nodes) {
    const have = team.states.nodes.map((s) => s.name);
    const missing = STATES.filter((s) => !have.includes(s));
    say(`team ${team.key}: ${missing.length ? `missing states: ${missing.join(", ")}` : "all four states"}`);
  }
  for (const { name } of data.issueLabels.nodes) {
    const dir = `${env.projects}/${name}`;
    say(`repo label ${name}: ${git(dir, "rev-parse", "--git-dir").status === 0 ? dir : `no repository at ${dir}`}`);
  }
  if (data.issueLabels.nodes.length === 0) say("no labels in a 'repo' group yet");
  claudeVersion();
  say(isFile(env.ntfyFile ?? "") ? "ntfy: configured" : "ntfy: no topic, so no pushes");
}

/** Work mode: the key, the label, each team's state, repository and settings. */
export async function workCheck(env: Env, linear: Linear): Promise<void> {
  const config = loadConfig(env);
  const data = await linear.gql<{
    viewer: { displayName: string };
    teams: { nodes: { key: string; states: { nodes: { name: string }[] } }[] };
    issueLabels: { nodes: unknown[] };
  }>(
    `query($l: String!) { viewer { id displayName }
    teams { nodes { key states { nodes { name } } } }
    issueLabels(first: 50, filter: {name: {eq: $l}}) { nodes { name } } }`,
    { l: config.label },
  );
  say(`key: works, acting as ${data.viewer.displayName}`);
  say(`label ${config.label}: ${data.issueLabels.nodes.length ? "exists" : "not in Linear yet"}`);
  let trusted: Record<string, { hasTrustDialogAccepted?: boolean }> = {};
  try {
    trusted = JSON.parse(readFileSync(`${env.home}/.claude.json`, "utf8")).projects ?? {};
  } catch {
    // No Claude state yet: nothing trusted.
  }
  for (const k of Object.keys(config.repos).sort()) {
    const dir = repoDir(env, config.repos[k]);
    const team = data.teams.nodes.find((t) => t.key === k);
    if (!team) say(`team ${k}: not found`);
    else if (team.states.nodes.some((s) => s.name === config.startedState)) say(`team ${k}: has ${config.startedState}`);
    else say(`team ${k}: no state ${config.startedState}`);
    say(git(dir, "remote", "get-url", "origin").status === 0
      ? `team ${k}: repository ${dir}`
      : `team ${k}: no repository with an origin at '${dir}'`);
    // claude --bg refuses a directory whose trust prompt was never accepted.
    say(trusted[dir]?.hasTrustDialogAccepted === true
      ? `team ${k}: Claude trusts it`
      : `team ${k}: run claude in ${dir} once and accept the trust prompt`);
    for (const s of overrides(env, dir, dir)) {
      say(`team ${k}: ${s} changes the sandbox or runs a command outside it, so its issues are refused`);
    }
  }
  // The fields a run asks for, so one Linear renamed shows here, not as a failed run.
  await linear.gql(`query { issues(first: 1, filter: {assignee: {isMe: {eq: true}}}) { nodes { ${WORK_FIELDS} } } }`);
  say("issue fields: all known to Linear");
  let s: any;
  try {
    s = JSON.parse(readFileSync(env.settings ?? "", "utf8"));
  } catch {
    s = {};
  }
  const sandboxed =
    s.sandbox?.enabled &&
    s.sandbox?.filesystem?.denyRead?.includes("~/Library/Keychains") &&
    s.disableAllHooks === true &&
    s.permissions?.deny?.includes("WebFetch") &&
    s.permissions?.deny?.includes("WebSearch");
  say(sandboxed
    ? "sandbox: on, with the keychain hidden, hooks off and no web tools"
    : `sandbox: '${env.settings ?? ""}' is missing, does not hide ~/Library/Keychains, leaves hooks on, or allows web tools`);
  claudeVersion();
  if (await notify(env, "Night shift", "A test notification from night-shift check")) say("notification: sent");
}
