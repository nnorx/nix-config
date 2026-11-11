import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Linear } from "./linear.ts";
import { cmp, die, now } from "./util.ts";

/** Opens every comment this posts: the key acts as Nick, so this is how its comments are told apart from his. */
export const MARKER = "**Night shift**";

export interface Issue {
  id: string;
  identifier: string;
  title: string;
  description: string | null;
  url: string;
  state: { name: string; type: string };
  creator: { id: string } | null;
  team: { states: { nodes: { id: string; name: string; type: string; position: number }[] } };
  labels: { nodes: { name: string; parent: { name: string } | null }[] };
  comments: { nodes: { body: string; createdAt: string; user: { id: string } | null }[] };
  history: {
    pageInfo: { hasNextPage: boolean };
    nodes: { createdAt: string; actorId: string | null; toState: { name: string } | null }[];
  };
}

// The whole history, in whatever order Linear returns it, so the check on
// who queued it does not depend on the order.
const ISSUE = `query($id: String!) { issue(id: $id) { id identifier title description url
  state { name type }
  creator { id }
  team { states { nodes { id name type position } } }
  labels { nodes { name parent { name } } }
  comments(first: 100) { nodes { body createdAt user { id } } }
  history(first: 250) { pageInfo { hasNextPage } nodes { createdAt actorId toState { name } } } } }`;

export async function getIssue(linear: Linear, id: string): Promise<Issue> {
  return (await linear.gql<{ issue: Issue }>(ISSUE, { id })).issue;
}

export const closed = (i: { state: { type: string } }) => i.state.type === "completed" || i.state.type === "canceled";

export async function move(linear: Linear, i: Issue, name: string): Promise<void> {
  const state = i.team.states.nodes.find((s) => s.name === name)?.id;
  if (!state) die(`${i.identifier}'s team has no state '${name}'; see night-shift check`);
  await linear.gql("mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: {stateId: $s}) { success } }", {
    id: i.id,
    s: state,
  });
}

export async function comment(linear: Linear, i: Issue, markdown: string): Promise<void> {
  await linear.gql("mutation($id: String!, $b: String!) { commentCreate(input: {issueId: $id, body: $b}) { success } }", {
    id: i.id,
    b: `${MARKER}\n\n${markdown}`,
  });
}

/** Nick's comments, oldest first, after `since` when given, without this dispatcher's own. */
export function answers(i: Issue, viewer: string, since = ""): string {
  return i.comments.nodes
    .filter((c) => c.user?.id === viewer && !c.body.startsWith(MARKER) && (!since || c.createdAt > since))
    .sort((a, b) => cmp(a.createdAt, b.createdAt))
    .map((c) => `[${c.createdAt.slice(0, 16).replace("T", " ")}] ${c.body}`)
    .join("\n\n")
    .replace(/\n+$/, "");
}

const trimEnd = (s: string) => s.replace(/\n+$/, "");

/** The task as Nick wrote it, which both the agent's prompt and its issue file open with. */
export function task(i: Issue, viewer: string): string {
  return `# ${i.identifier}: ${i.title}

${trimEnd(i.description ?? "(no description)")}

## Nick's comments on the issue, oldest first

${answers(i, viewer) || "(none)"}`;
}

/**
 * The issue as the agent is handed it, as <ID>.issue.md next to its result,
 * for a session reviewing the branch: the key is out of Claude's reach. Under
 * .git/, so nothing publishes it. Written before claude starts, so a run that
 * fails to start still leaves it.
 */
export function writeIssue(i: Issue, viewer: string, result: string): void {
  mkdirSync(dirname(result), { recursive: true });
  const [head, ...rest] = task(i, viewer).split("\n");
  const meta = `- URL: ${i.url}\n- State: ${i.state.name}\n- Handed to the agent: ${now()}`;
  writeFileSync(result.replace(/\.md$/, ".issue.md"), `${head}\n\n${meta}\n${rest.join("\n")}\n`);
}
