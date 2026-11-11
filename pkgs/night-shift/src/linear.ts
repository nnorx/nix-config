import { readFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { die, run } from "./util.ts";

/**
 * offline: no answer, so a write may or may not have happened. notFound: what
 * was asked for does not exist. refused: any other error, with nothing changed.
 * The exit codes match the shell dispatcher's gql.
 */
export type Failure = "offline" | "notFound" | "refused";
export const EXIT: Record<Failure, number> = { offline: 1, notFound: 2, refused: 3 };

export class LinearError extends Error {
  readonly kind: Failure;
  constructor(kind: Failure, message: string) {
    super(message);
    this.kind = kind;
  }
}

/**
 * The key acts as Nick. Held in memory only, never in the environment, so
 * no child process inherits it.
 */
export function loadKey(env: Env): string {
  if (env.keyCmd) {
    const r = run(env.bash, ["-c", env.keyCmd]);
    const key = r.stdout.replace(/\n+$/, "");
    if (r.status !== 0 || !key) {
      die(`no Linear key from '${env.keyCmd}'; docs/night-shift.md says how to store it`);
    }
    return key;
  }
  try {
    return readFileSync(env.keyFile ?? "", "utf8").replace(/\n+$/, "");
  } catch {
    die(`cannot read the Linear key at '${env.keyFile ?? ""}'`);
  }
}

export class Linear {
  readonly #key: string;
  readonly #url: string;

  constructor(key: string, url: string) {
    this.#key = key;
    this.#url = url;
  }

  async gql<T>(query: string, variables: Record<string, unknown> = {}): Promise<T> {
    let body: { data?: T; errors?: { message: string }[] };
    try {
      const res = await fetch(this.#url, {
        method: "POST",
        headers: { Authorization: this.#key, "Content-Type": "application/json" },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(30_000),
      });
      body = (await res.json()) as typeof body;
    } catch {
      throw new LinearError("offline", "Linear did not answer");
    }
    if (body.errors) {
      const messages = body.errors.map((e) => e.message);
      const kind = messages.every((m) => /not found/i.test(m)) ? "notFound" : "refused";
      throw new LinearError(kind, `Linear: ${messages.join("; ")}`);
    }
    return body.data as T;
  }
}

interface Page<T> {
  pageInfo: { hasNextPage: boolean; endCursor: string | null };
  nodes: T[];
}

/** Every node of a connection, a page at a time. The query takes `$after`. */
export async function* paged<T>(linear: Linear, query: string, field: string): AsyncGenerator<T> {
  let after: string | null = null;
  for (;;) {
    const data: Record<string, Page<T>> = await linear.gql(query, { after });
    const page = data[field]!;
    yield* page.nodes;
    if (!page.pageInfo.hasNextPage) return;
    after = page.pageInfo.endCursor;
  }
}

export async function all<T>(linear: Linear, query: string, field: string): Promise<T[]> {
  const out: T[] = [];
  for await (const node of paged<T>(linear, query, field)) out.push(node);
  return out;
}

export interface Doc {
  id: string;
  title: string;
  content: string | null;
  updatedAt: string;
  project: { id: string; name: string; status: { type: string } | null } | null;
}

// Paged at the top level: documents nested in projects multiply past
// Linear's query complexity cap.
/** What the export needs of a doc, from a list or from a create or update. */
export const DOC_FIELDS = "id title content updatedAt project { id name status { type } }";

export const DOCS = `query($after: String) {
  documents(first: 50, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ${DOC_FIELDS} } } }`;

export const PROJECTS = `query($after: String) {
  projects(first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { id name } } }`;
