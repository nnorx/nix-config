import { lstatSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname } from "node:path";
import { QUEUED, type Env } from "./env.ts";
import { all, DOC_FIELDS, DOCS, type Doc, type Linear, LinearError, PROJECTS } from "./linear.ts";
import { askTty, commonDir, die, git, run, say, warn } from "./util.ts";

// Drafts for `night-shift file`: <repo>/.git/linear-handoff/<any>.md, written
// by Claude or by hand. A front matter of `key: value` lines, then the text.
//
//   ---
//   title: forge: push to ntfy when runs keep failing     an issue
//   repo: nix-config        default: the repository the draft is in
//   priority: high          urgent, high, medium, low or none (default)
//   project: Night shift    default: none; must exist in the team
//   team: NNO               needed only with more than one team
//   labels: Hands on, Bug   default: none; each one existing label, not repo's
//   ---
//
//   ---
//   project: NAS            a project's document, created or replaced
//   doc: Design
//   updated: 2026-11-07T…   from the export; refused if Linear's is newer
//   ---
//
// Filed as Nick, an issue passes the dispatcher's "created by you" check, so
// each draft is shown and confirmed on its own. An issue lands in the
// backlog, never in Queued: starting an agent stays his move.

const ISSUE_KEYS = ["title", "repo", "priority", "project", "team", "labels"];
const DOC_KEYS = ["project", "doc", "updated"];
const PRIORITIES: Record<string, number> = { urgent: 1, high: 2, medium: 3, low: 4, none: 0, "": 0 };
const PRIORITY_NAMES = ["no priority", "urgent", "high", "medium", "low"];
const FILED = "_Filed from a draft with `night-shift file`._";

// What Nick reads must be what is filed, so anything that could make them
// differ is refused.
const HIDDEN = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\p{Cf}\p{Zl}\p{Zp}]/u;

export interface Draft {
  fields: Map<string, string>;
  keys: string[];
  body: string;
}

/** The draft, or why it cannot be filed. */
export function parseDraft(raw: Buffer): Draft | string {
  let text: string;
  try {
    // ignoreBOM keeps a byte order mark in the text, for HIDDEN to refuse.
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(raw);
  } catch {
    return "not valid UTF-8";
  }
  const hidden = HIDDEN.exec(text);
  if (hidden) {
    const code = hidden[0].codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0");
    const line = text.slice(0, hidden.index).split("\n").length;
    return `contains control or invisible characters (U+${code} on line ${line})`;
  }
  const lines = text.split("\n");
  if (text.endsWith("\n")) lines.pop();
  const close = lines.indexOf("---", 1);
  if (lines[0] !== "---" || close === -1) return "front matter must open and close with ---";
  const fields = new Map<string, string>();
  const keys: string[] = [];
  for (const line of lines.slice(1, close)) {
    if (!line.trim()) continue;
    const colon = line.indexOf(":");
    const key = colon === -1 ? line : line.slice(0, colon);
    if (!key) continue;
    keys.push(key);
    if (colon === -1 || fields.has(key)) continue;
    const value = line.slice(colon + 1).trim();
    fields.set(key, /^(".*"|'.*')$/.test(value) ? value.slice(1, -1) : value);
  }
  const rest = lines.slice(close + 1);
  const first = rest.findIndex((l) => l.trim() !== "");
  const body = first === -1 ? "" : rest.slice(first).join("\n").replace(/\n+$/, "");
  return { fields, keys, body };
}

interface Workspace {
  viewer: { displayName: string };
  teams: {
    nodes: {
      id: string;
      key: string;
      states: { nodes: { id: string; name: string; type: string; position: number }[] };
      projects: { nodes: { id: string; name: string }[] };
    }[];
  };
  repo: { nodes: { id: string; name: string; team: { id: string } | null }[] };
  labels: { nodes: { id: string; name: string; team: { id: string } | null; parent: { name: string } | null }[] };
}

const WORKSPACE = `query { viewer { displayName }
    teams { nodes { id key states { nodes { id name type position } } projects(first: 100) { nodes { id name } } } }
    repo: issueLabels(first: 250, filter: {parent: {name: {eq: "repo"}}}) { nodes { id name team { id } } } }`;

// A query of its own: joined to WORKSPACE, the two together pass Linear's
// complexity cap.
const LABELS = `query { labels: issueLabels(first: 250, filter: {isGroup: {eq: false}}) {
    nodes { id name team { id } parent { name } } } }`;

interface Filing {
  /** One line: what and where. */
  shown: string;
  title: string;
  /** The text as filed, or for an update the change to it. */
  preview: string;
  mutation: string;
  variables: Record<string, unknown>;
  filed: (data: any) => string;
  /** The doc as Linear now has it, for the export, whose list can lag a write. */
  doc?: (data: any) => Doc;
}

function issueFiling(d: Draft, repoDir: string, ws: Workspace): Filing | string {
  const unknown = d.keys.find((k) => !ISSUE_KEYS.includes(k));
  if (unknown === "updated") return "updated is for a doc draft, with doc:";
  if (unknown !== undefined) return `unknown key '${unknown}'`;
  const title = d.fields.get("title");
  if (!title) return "no title";
  const repo = d.fields.get("repo") || repoDir;
  let key = d.fields.get("team");
  if (!key) {
    if (ws.teams.nodes.length !== 1) return "more than one team; add team:";
    key = ws.teams.nodes[0]!.key;
  }
  const team = ws.teams.nodes.find((t) => t.key === key);
  if (!team) return `no team '${key}'`;
  // Exactly one repo label of that name that this team can use: the
  // workspace's, or the team's own.
  const labels = ws.repo.nodes.filter((l) => l.name === repo && (l.team === null || l.team.id === team.id));
  if (labels.length !== 1) return `no single repo label '${repo}' for team ${key}`;
  // The backlog, or failing that the first not-started state; never Queued.
  const states = team.states.nodes.filter((s) => s.name !== QUEUED).sort((a, b) => a.position - b.position);
  const state = states.find((s) => s.type === "backlog") ?? states.find((s) => s.type === "unstarted");
  if (!state) return `team ${key} has no backlog state`;
  const named = d.fields.get("priority") ?? "";
  const priority = Object.hasOwn(PRIORITIES, named) ? PRIORITIES[named] : undefined;
  if (priority === undefined) return "priority is urgent, high, medium, low or none";
  const projectName = d.fields.get("project") ?? "";
  const names = [...new Set((d.fields.get("labels") ?? "").split(",").map((n) => n.trim()).filter(Boolean))];
  const labelIds = [labels[0]!.id];
  for (const name of names) {
    const usable = ws.labels.nodes.filter((l) => l.name === name && (l.team === null || l.team.id === team.id));
    if (usable.some((l) => l.parent?.name === "repo")) return `'${name}' is a repo label; name the repository with repo:`;
    if (usable.length !== 1) return `${usable.length ? "more than one" : "no"} label '${name}' for team ${key}`;
    labelIds.push(usable[0]!.id);
  }
  const input: Record<string, unknown> = {
    teamId: team.id,
    title,
    priority,
    description: `${d.body}\n\n${FILED}`,
    labelIds,
    stateId: state.id,
  };
  if (projectName) {
    const projects = team.projects.nodes.filter((p) => p.name === projectName);
    if (projects.length !== 1) return `no single project '${projectName}' in team ${key}`;
    input.projectId = projects[0]!.id;
  }
  const where = [key, repo, PRIORITY_NAMES[priority], ...(projectName ? [projectName] : []), ...(names.length ? [`labels ${names.join(", ")}`] : [])];
  return {
    shown: `${where.join(" · ")} · into ${state.name}`,
    title,
    preview: input.description as string,
    mutation: "mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success issue { identifier url } } }",
    variables: { i: input },
    filed: (data) => `filed ${data.issueCreate.issue.identifier}  ${data.issueCreate.issue.url}`,
  };
}

/** A unified diff of Linear's text against the draft's, hunks only. */
function diff(before: string, after: string): string {
  const dir = mkdtempSync(`${tmpdir()}/night-shift-diff.`);
  try {
    writeFileSync(`${dir}/linear`, `${before}\n`);
    writeFileSync(`${dir}/draft`, `${after}\n`);
    const r = run("git", ["diff", "--no-index", "--no-color", `${dir}/linear`, `${dir}/draft`]);
    return r.stdout.slice(r.stdout.indexOf("@@")).replace(/\n$/, "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function docFiling(d: Draft, projects: { id: string; name: string }[], allDocs: Doc[]): Filing | string {
  const extra = d.keys.find((k) => !DOC_KEYS.includes(k));
  if (extra !== undefined) return `a doc draft takes project, doc and updated, not ${extra}`;
  const title = d.fields.get("doc");
  if (!title) return "no doc title";
  const projectName = d.fields.get("project");
  if (!projectName) return "a doc draft needs project:";
  if (!d.body) return "no text";
  const matches = projects.filter((p) => p.name === projectName);
  if (matches.length !== 1) return `no single project '${projectName}'`;
  const project = matches[0]!;
  const docs = allDocs.filter((doc) => doc.project?.id === project.id && doc.title === title);
  if (docs.length > 1) return `more than one doc '${title}' in ${projectName}`;
  const updated = d.fields.get("updated");
  const existing = docs[0];
  if (!existing) {
    if (updated) return `no doc '${title}' in ${projectName} any more`;
    return {
      shown: `doc · ${projectName} · new`,
      title,
      preview: d.body,
      mutation: `mutation($i: DocumentCreateInput!) { documentCreate(input: $i) { success document { url ${DOC_FIELDS} } } }`,
      variables: { i: { projectId: project.id, title, content: d.body } },
      filed: (data) => `filed doc '${title}'  ${data.documentCreate.document.url}`,
      doc: (data) => data.documentCreate.document,
    };
  }
  if (!updated) return `${projectName} has a doc '${title}' already; start from its export, with updated:`;
  if (updated !== existing.updatedAt) {
    return `'${title}' changed in Linear at ${existing.updatedAt}, after the export this draft is from (${updated}); start from the new export`;
  }
  const content = (existing.content ?? "").replace(/\n+$/, "");
  if (content === d.body) return "no change from the doc in Linear";
  return {
    shown: `doc · ${projectName} · update`,
    title,
    preview: diff(content, d.body),
    mutation: `mutation($id: String!, $i: DocumentUpdateInput!) { documentUpdate(id: $id, input: $i) { success document { url ${DOC_FIELDS} } } }`,
    variables: { id: existing.id, i: { content: d.body } },
    filed: (data) => `filed doc '${title}'  ${data.documentUpdate.document.url}`,
    doc: (data) => data.documentUpdate.document,
  };
}

interface Found {
  path: string;
  repo: string;
}

/** Every draft in every repository under projects, each repository once. */
function findDrafts(env: Env): Found[] {
  const found: Found[] = [];
  const seen = new Set<string>();
  let entries: string[] = [];
  try {
    entries = readdirSync(env.projects).sort();
  } catch {
    // No projects directory: no drafts.
  }
  for (const name of entries) {
    const d = `${env.projects}/${name}`;
    if (name.startsWith(".") || !statSync(d, { throwIfNoEntry: false })?.isDirectory()) continue;
    if (git(d, "rev-parse", "--git-dir").status !== 0) continue;
    const common = commonDir(d);
    // A worktree checked out under projects shares its repository's drafts.
    if (!common || seen.has(common)) continue;
    seen.add(common);
    const dir = `${common}/linear-handoff`;
    const st = lstatSync(dir, { throwIfNoEntry: false });
    if (!st) continue;
    if (!st.isDirectory()) die(`${dir} is not a plain directory`);
    const files = readdirSync(dir).filter((f) => !f.startsWith(".")).sort();
    for (const f of files.filter((f) => f.endsWith(".filing"))) {
      warn(`${dir}/${f} was being filed when a run was cut off; check Linear, then delete it or rename it back to .md`);
    }
    for (const f of files.filter((f) => f.endsWith(".md"))) {
      found.push({ path: `${dir}/${f}`, repo: basename(dirname(common)) });
    }
  }
  return found;
}

function written(path: string): string {
  const t = statSync(path).mtime;
  const p = (n: number) => String(n).padStart(2, "0");
  return `${t.getFullYear()}-${p(t.getMonth() + 1)}-${p(t.getDate())} ${p(t.getHours())}:${p(t.getMinutes())}`;
}

/** Files each draft Nick confirms; returns the docs filed, as Linear answered. */
export async function fileDrafts(env: Env, linear: Linear): Promise<Doc[]> {
  const found = findDrafts(env);
  if (found.length === 0) {
    say(`no drafts in ${env.projects}/*/.git/linear-handoff/`);
    return [];
  }
  const drafts = found.map((f) => {
    const st = lstatSync(f.path);
    return st.isFile() ? parseDraft(readFileSync(f.path)) : "not a regular file";
  });
  const ws = await linear.gql<Omit<Workspace, "labels">>(WORKSPACE);
  const needLabels = drafts.some((d) => typeof d !== "string" && d.fields.has("labels"));
  const { labels } = needLabels ? await linear.gql<Pick<Workspace, "labels">>(LABELS) : { labels: { nodes: [] } };
  const needDocs = drafts.some((d) => typeof d !== "string" && d.keys.includes("doc"));
  const projects = needDocs ? await all<{ id: string; name: string }>(linear, PROJECTS, "projects") : [];
  const docs = needDocs ? await all<Doc>(linear, DOCS, "documents") : [];

  // Every draft is checked before any is offered, so a mistake files nothing.
  const filings = drafts.map((d, n) => {
    if (typeof d === "string") return d;
    return d.keys.includes("doc") ? docFiling(d, projects, docs) : issueFiling(d, found[n]!.repo, { ...ws, labels });
  });
  let bad = false;
  for (const [n, f] of filings.entries()) {
    if (typeof f !== "string") continue;
    warn(`${found[n]!.path}: ${f}`);
    bad = true;
  }
  if (bad) die("nothing filed; fix the drafts above");

  say(`Filing as ${ws.viewer.displayName}, one draft at a time.`);
  let filed = 0;
  const fresh: Doc[] = [];
  for (const [n, f] of (filings as Filing[]).entries()) {
    const path = found[n]!.path;
    say();
    say(`── ${path} (written ${written(path)})`);
    say(f.shown);
    say();
    say(f.title);
    say();
    say(f.preview);
    say();
    if (!/^[yY]$/.test(askTty("File this one? [y/N] "))) {
      say("kept");
      continue;
    }
    // Moved aside first: if Linear takes it but the answer is lost, a rerun
    // must not file it again.
    const filing = path.replace(/\.md$/, ".filing");
    renameSync(path, filing);
    try {
      const data = await linear.gql(f.mutation, f.variables);
      say(f.filed(data));
      if (f.doc) fresh.push(f.doc(data));
      rmSync(filing);
      filed++;
    } catch (e) {
      if (!(e instanceof LinearError)) throw e;
      warn(e.message);
      if (e.kind === "offline") {
        warn(`no answer from Linear, so it may be filed; check, then delete ${filing} or rename it back to .md`);
      } else {
        renameSync(filing, path);
        warn("Linear refused it; the draft is kept");
      }
    }
  }
  say(`filed ${filed} of ${found.length}`);
  return fresh;
}
