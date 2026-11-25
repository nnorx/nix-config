import { readFileSync } from "node:fs";

// Read the way jq reads it, so a brief of the wrong shape fails here as it
// would there, and a failure is `be there`.

function idx(v: unknown, key: string): unknown {
  if (v === null || v === undefined) return null;
  if (typeof v === "object" && !Array.isArray(v)) return (v as Record<string, unknown>)[key] ?? null;
  throw new Error(`cannot index with ${key}`);
}

function each(v: unknown): unknown[] {
  if (Array.isArray(v)) return v;
  if (v !== null && typeof v === "object") return Object.values(v);
  throw new Error("cannot iterate");
}

const truthy = (v: unknown) => v !== null && v !== undefined && v !== false;

/** `a // b`: a's errors count as no value. */
function or(a: () => unknown, b: unknown): unknown {
  try {
    const v = a();
    return truthy(v) ? v : b;
  } catch {
    return b;
  }
}

/**
 * The brief's word on deploying main to a host: be there, review or
 * routine, or unchanged when main changes nothing there but the revision.
 */
export function level(host: string, file: string): string {
  try {
    const b: unknown = JSON.parse(readFileSync(file, "utf8"));
    if (idx(idx(b, "verdict"), "level") === "unknown") return "be there";
    const state = or(() => {
      for (const c of each(idx(b, "configs"))) if (idx(c, "name") === host) return idx(c, "state");
      return null;
    }, "");
    if (state === "unchanged") return "unchanged";
    const findings = each(or(() => idx(idx(idx(b, "hosts"), host), "findings"), []));
    const levels = [...findings, ...each(idx(b, "plan"))].map((x) => idx(x, "level"));
    if (levels.includes("be there")) return "be there";
    if (levels.includes("review")) return "review";
    return "routine";
  } catch {
    return "be there";
  }
}
