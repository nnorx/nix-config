import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { all, DOCS, type Doc, type Linear } from "./linear.ts";
import { now } from "./util.ts";

// A Claude session cannot reach Linear and is deliberately given no key: one
// acting as Nick could create and queue issues the dispatcher would take as
// his. These snapshots are how a session reads Linear instead. Nick's plan
// text, so they stay in the state directory, outside every repo.

interface Issue {
  identifier: string;
  title: string;
  description: string | null;
  priority: number;
  priorityLabel: string;
  updatedAt: string;
  state: { name: string; type: string };
  project: { name: string } | null;
  labels: { nodes: { name: string; parent: { name: string } | null }[] };
}

const ISSUES = `query($after: String) {
  issues(first: 50, after: $after, filter: {state: {type: {nin: ["completed", "canceled"]}}}) {
    pageInfo { hasNextPage endCursor }
    nodes { identifier title description priority priorityLabel updatedAt
      state { name type } project { name } labels { nodes { name parent { name } } } } } }`;

const STAGE: Record<string, number> = { started: 0, unstarted: 1, backlog: 2, triage: 3 };
const stage = (i: Issue) => STAGE[i.state.type] ?? 4;
const rank = (i: Issue) => (i.priority === 0 ? 5 : i.priority);
const number = (i: Issue) => Number(/(\d+)$/.exec(i.identifier)?.[1] ?? 0);
const cmp = (a: string | number, b: string | number) => (a < b ? -1 : a > b ? 1 : 0);

export function renderBacklog(issues: Issue[], at: string): string {
  const sorted = [...issues].sort(
    (a, b) =>
      cmp(stage(a), stage(b)) ||
      cmp(a.state.name, b.state.name) ||
      cmp(rank(a), rank(b)) ||
      cmp(number(a), number(b)),
  );
  const lines = [
    "# Open issues in Linear",
    "",
    `Written by night-shift at ${at}: ${issues.length} issues not done or canceled,`,
    "by state, then priority. A snapshot to read; change issues in Linear.",
  ];
  let group = "";
  for (const [n, issue] of sorted.entries()) {
    if (issue.state.name !== group) {
      group = issue.state.name;
      const size = sorted.slice(n).findIndex((i) => i.state.name !== group);
      lines.push("", `## ${group} (${size === -1 ? sorted.length - n : size})`);
    }
    const repo = issue.labels.nodes.find((l) => l.parent?.name === "repo")?.name ?? "none";
    const labels = issue.labels.nodes.filter((l) => l.parent?.name !== "repo").map((l) => l.name);
    // Quoted, so a heading in a description cannot pass for one of these.
    const quoted = (issue.description ?? "(no description)")
      .replace(/\n$/, "")
      .split("\n")
      .map((l) => (l === "" ? ">" : `> ${l}`));
    lines.push(
      "",
      `### ${issue.identifier}: ${issue.title}`,
      "",
      `- Priority: ${issue.priorityLabel}. Repo: ${repo}. Project: ${issue.project?.name ?? "none"}.` +
        (labels.length ? ` Labels: ${labels.join(", ")}.` : ""),
      `- Updated: ${issue.updatedAt.slice(0, 10)}`,
      "",
      ...quoted,
    );
  }
  return `${lines.join("\n")}\n`;
}

/** Every open issue, by state, then priority, in backlog.md. */
export async function writeBacklog(env: Env, linear: Linear): Promise<void> {
  const issues = await all<Issue>(linear, ISSUES, "issues");
  mkdirSync(env.stateDir, { recursive: true });
  const out = `${env.stateDir}/backlog.md`;
  // Nick's plan text, so his alone; and a name of its own, since `file` and a
  // run can write at once.
  const tmp = `${out}.${process.pid}.tmp`;
  writeFileSync(tmp, renderBacklog(issues, now()), { mode: 0o600 });
  renameSync(tmp, out);
}

export function slug(name: string): string {
  return (
    name
      .normalize("NFKD")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "untitled"
  );
}

/** A front matter value that parseDraft reads back unchanged. */
function field(value: string): string {
  return value !== value.trim() || /^(".*"|'.*')$/.test(value) ? `"${value}"` : value;
}

/** A document as a draft for `night-shift file`, which takes it back as an update. */
export function renderDoc(project: string, doc: Doc): string {
  return `---\nproject: ${field(project)}\ndoc: ${field(doc.title)}\nupdated: ${doc.updatedAt}\n---\n\n${doc.content ?? ""}\n`;
}

function unique(name: string, taken: Set<string>): string {
  let s = slug(name);
  for (let n = 2; taken.has(s); n++) s = `${slug(name)}-${n}`;
  taken.add(s);
  return s;
}

/**
 * Each open project's documents, as projects/<project>/<doc>.md. Replaced
 * whole, so a doc deleted in Linear leaves no file behind. Closed projects'
 * docs are fetched and skipped here: few enough not to filter on Linear's side.
 */
export async function writeProjectDocs(env: Env, linear: Linear): Promise<void> {
  const byProject = new Map<string, { name: string; docs: Doc[] }>();
  for (const doc of await all<Doc>(linear, DOCS, "documents")) {
    const p = doc.project;
    if (!p || (p.status && ["completed", "canceled"].includes(p.status.type))) continue;
    const entry = byProject.get(p.id) ?? { name: p.name, docs: [] };
    entry.docs.push(doc);
    byProject.set(p.id, entry);
  }
  mkdirSync(env.stateDir, { recursive: true });
  const dest = `${env.stateDir}/projects`;
  const tmp = mkdtempSync(`${dest}.`);
  try {
    const dirs = new Set<string>();
    for (const { name, docs } of [...byProject.values()].sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const dir = `${tmp}/${unique(name, dirs)}`;
      mkdirSync(dir);
      const files = new Set<string>();
      for (const doc of docs) {
        writeFileSync(`${dir}/${unique(doc.title, files)}.md`, renderDoc(name, doc), { mode: 0o600 });
      }
    }
    // `file` and a run can both get here; whichever lands second keeps the
    // other's copy, which is as fresh.
    try {
      renameSync(dest, `${tmp}.old`);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    }
    try {
      renameSync(tmp, dest);
    } catch (e) {
      if (!["ENOTEMPTY", "EEXIST"].includes((e as NodeJS.ErrnoException).code ?? "")) throw e;
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
    rmSync(`${tmp}.old`, { recursive: true, force: true });
  }
}
