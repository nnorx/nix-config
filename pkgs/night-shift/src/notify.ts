import { readFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { run, warn } from "./util.ts";

/**
 * A push through ntfy, or on a Mac a desktop notification. Never name an
 * issue by its title: ntfy.sh is a third party, and a title can describe the
 * house. False when it did not go out.
 */
export async function notify(env: Env, title: string, message: string, url?: string): Promise<boolean> {
  if (env.platform === "darwin") {
    // The text reaches AppleScript as arguments, never as part of the script.
    const script = ["on run argv", "display notification (item 2 of argv) with title (item 1 of argv)", "end run"];
    const r = run("osascript", [...script.flatMap((line) => ["-e", line]), title, message]);
    if (r.status === 0) return true;
    warn(`notification failed for: ${title}`);
    return false;
  }
  let topic: string;
  try {
    topic = readFileSync(env.ntfyFile ?? "", "utf8").replace(/\n+$/, "");
  } catch {
    return true;
  }
  const headers: Record<string, string> = { Title: title, Tags: "robot" };
  if (url) headers.Click = url;
  try {
    const res = await fetch(topic, { method: "POST", headers, body: message, signal: AbortSignal.timeout(15_000) });
    if (res.ok) return true;
  } catch {
    // Reported below, as a refusal is.
  }
  warn(`ntfy failed for: ${title}`);
  return false;
}
