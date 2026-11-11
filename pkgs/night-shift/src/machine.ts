import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import type { Env } from "./env.ts";
import { notify } from "./notify.ts";
import { warn } from "./util.ts";

// What a run asks of the machine it is on, as it ends: to stay awake while
// an agent works, and to say when runs keep failing.

export function running(env: Env): number {
  let files: string[] = [];
  try {
    files = readdirSync(env.stateDir).filter((f) => f.endsWith(".json"));
  } catch {
    return 0;
  }
  return files.filter((f) => JSON.parse(readFileSync(`${env.stateDir}/${f}`, "utf8")).phase === "running").length;
}

const read = (path: string) => {
  try {
    return readFileSync(path, "utf8").trim();
  } catch {
    return "";
  }
};

/** Whether forge runs on mains power. A machine with no battery counts. */
function onAc(env: Env): boolean {
  let battery = false;
  let supplies: string[] = [];
  try {
    supplies = readdirSync(env.powerDir);
  } catch {
    // None listed.
  }
  for (const s of supplies) {
    const type = read(`${env.powerDir}/${s}/type`);
    if (type === "Mains" && read(`${env.powerDir}/${s}/online`) === "1") return true;
    if (type === "Battery") battery = true;
  }
  return !battery;
}

/**
 * `_awake`, as every run ends, whether it got through or not: keeps the
 * machine from sleep while an agent works on AC, and only then. A sleeping
 * machine freezes every agent until someone wakes it.
 *
 * On forge, Plasma suspends after 15 idle minutes whatever runs: this starts
 * night-shift-awake.service, a power inhibition (hosts/forge/night-shift.nix),
 * and stops it once nothing runs or forge is on battery. Only idle sleep is
 * blocked; a closed lid still suspends. On a Mac, caffeinate -s, which holds
 * only on AC, until a minute past the next run, which asks again. It outlives
 * the run, in a process group of its own so the run's deadline leaves it be.
 */
export function awake(env: Env): void {
  const n = running(env);
  if (env.platform === "darwin") {
    if (n > 0) spawn("caffeinate", ["-s", "-t", String(env.interval + 60)], { detached: true, stdio: "ignore" }).unref();
    return;
  }
  const verb = n > 0 && onAc(env) ? "start" : "stop";
  if (spawnSync("systemctl", ["--user", verb, "night-shift-awake.service"], { stdio: "inherit" }).status !== 0) {
    warn(`could not ${verb} night-shift-awake.service`);
  }
}

/**
 * `_after`, forge's ExecStopPost, so it sees every way a run ends, a timeout
 * or a kill included, in systemd's $SERVICE_RESULT; on a Mac, _tick's. A run
 * that cannot reach Linear fails without touching any issue, so without this a
 * revoked key or a long outage is silence. One push once `failedRuns` runs in
 * a row have failed, so a Wi-Fi drop passes quietly, and no more until a run
 * succeeds. A push that does not go out is tried again after the next failure.
 */
export async function afterRun(env: Env): Promise<void> {
  const f = `${env.stateDir}/failed-runs`;
  mkdirSync(env.stateDir, { recursive: true });
  const result = process.env.SERVICE_RESULT;
  if (result === "success") {
    rmSync(f, { force: true });
    rmSync(`${f}.pushed`, { force: true });
    return;
  }
  const was = read(f);
  const n = (/^[0-9]+$/.test(was) ? Number(was) : 0) + 1;
  writeFileSync(f, `${n}\n`);
  const status = process.env.EXIT_STATUS;
  const why = `${result || "unknown"}${status ? ` ${status}` : ""}`;
  warn(`${n} run(s) in a row failed, the last with ${why}`);
  if (n < env.failedRuns || existsSync(`${f}.pushed`)) return;
  const where = env.platform === "linux"
    ? "journalctl --user -u night-shift on forge says why."
    : `${env.log ?? "The launchd log"} says why.`;
  const said = `The last ${n} runs failed, the last with ${why}, so nothing is taken from Linear or started. ${where}`;
  if (await notify(env, "Night shift is failing", said)) writeFileSync(`${f}.pushed`, "");
}
