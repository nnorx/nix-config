// fleet-deploy: main, onto the Pis, by day, one host at a time, through each
// Pi's deploy login (modules/deploy-agent.nix). home/fleet-deploy.nix
// installs it, with FLEET_DEPLOY_KEY naming the deploy key.
//
//   fleet-deploy [host...]                   deploy main, by default to every Pi
//   fleet-deploy status|hold|release [host...]
//
// Run from a nix-config checkout. The brief is preflight's, run in a
// temporary worktree at main. status, hold and release read the Pis from the
// checkout as it is and touch neither GitHub nor main, so a hold works while
// either is broken.
//
// Hosts go in their nightly order, lifeline first as the canary. For each:
//
//   1. Its login's `status`. A held host, or one on main, is left alone.
//   2. preflight's brief against the revision it runs. `be there`, or no
//      brief, wants the host's name typed; anything else a y. main already
//      staged for its next boot gets the same question, for the reboot.
//   3. Its system in the cache, waiting while cache.yml runs for main, since
//      the upgrade substitutes or fails.
//   4. `upgrade`, which starts the nightly unit. A staged kernel outside the
//      reboot window is offered a reboot; inside it the upgrade reboots by
//      itself. Either way the host is seen to go down and come back.
//
// The first host not ending on main, running, with no newly failed units,
// stops the run, so a bad main reaches one resolver. A host skipped at its
// prompt does not. Ctrl-C stops this, never a host: what was asked for
// belongs to systemd on the Pi. gate is deployed by hand.
//
// Each step's line ends with how long it took, and a deploy ends with a table
// of them per host.

import { existsSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";
import { level } from "./brief.ts";
import { Answers, die, Exit, Fatal, indent, run, say, step, took, type Ran } from "./proc.ts";

const USAGE = "usage: fleet-deploy [host...] | fleet-deploy status|hold|release [host...]\n";
const REPO = "https://github.com/nnorx/nix-config";
const CACHE = "https://nnorx-nix-config.cachix.org";

class Usage extends Error {}

interface Pi {
  at?: unknown;
  toplevel?: string;
  window?: { lower?: unknown; upper?: unknown } | null;
  tz?: string | null;
}

const steps = ["status", "brief", "cache", "upgrade", "reboot"] as const;
interface Row {
  host: string;
  result?: string;
  ms: Partial<Record<(typeof steps)[number], number>>;
}

const key = process.env.FLEET_DEPLOY_KEY ?? "";
const answers = new Answers();
const rows: Row[] = [];
const started = performance.now();
let root = "";
let tmp = "";
let main = "";
let pis: Record<string, Pi> = {};

const since = (t: number) => performance.now() - t;
const short = (rev: string) => rev.slice(0, 12);

/** One fact from a status, by key, as awk would give it. */
function get(key: string, status: string): string {
  return status
    .split("\n")
    .map((l) => l.split("\t"))
    .filter((f) => f[0] === key)
    .map((f) => f[1] ?? "")
    .join("\n");
}

const words = (s: string) => s.split(/\s+/).filter(Boolean);

// sleep and date are commands, not timers, so the tests' stand-ins answer.
const sleep = (s: number) => run("sleep", [String(s)]);

/**
 * One request to a host's deploy login, given up after that long. timeout
 * covers a host that takes the session and then hangs, as one with a failing
 * root device does. -n, as ssh otherwise reads stdin.
 */
function agent(seconds: number, host: string, verb: string, out: Parameters<typeof run>[2] = {}): Promise<Ran> {
  return run(
    "timeout",
    [
      String(seconds),
      "ssh",
      "-n",
      "-i",
      key,
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=4",
      "--",
      `deploy@${host}`,
      verb,
    ],
    out,
  );
}

/** Every host in a flake that upgrades itself, with the facts named, each a Nix binding over its config `c`. */
async function hostsOf(flake: string, facts: string): Promise<Record<string, Pi>> {
  const apply = `
    cs: builtins.mapAttrs (_: c: { ${facts} }) (builtins.removeAttrs cs
      (builtins.filter (n: !cs.\${n}.config.system.autoUpgrade.enable) (builtins.attrNames cs)))
  `;
  const r = await run("nix", ["eval", "--json", "--accept-flake-config", `${flake}#nixosConfigurations`, "--apply", apply], {
    err: "keep",
  });
  try {
    if (r.status === 0) return JSON.parse(r.stdout) as Record<string, Pi>;
  } catch {
    // As a failed evaluation.
  }
  process.stderr.write(r.stderr);
  die(`could not evaluate ${flake}`);
}

// --- The brief ---------------------------------------------------------------

/**
 * preflight's JSON brief for main against a revision, made once per revision,
 * in a worktree at main so the brief's rules are main's. A failed run leaves
 * no file, so the next host on that revision runs it again.
 */
async function brief(rev: string): Promise<string | undefined> {
  const json = join(tmp, `brief-${rev}.json`);
  if (nonEmpty(json)) return json;
  const tree = join(tmp, "main");
  if (!existsSync(tree)) await run("git", ["-C", root, "worktree", "add", "--quiet", "--detach", tree, main], { out: "show" });
  step(`brief: what main changes against ${short(rev)} (a few minutes)`);
  const r = await run("nix", ["run", ".#preflight", "--", "--base", rev, "--head", main, "--flake-check", "skip", "--json", json], {
    cwd: tree,
    out: "show",
  });
  if (r.status === 0 && nonEmpty(json)) return json;
  rmSync(json, { force: true });
  return undefined;
}

function nonEmpty(file: string): boolean {
  try {
    return statSync(file).size > 0;
  } catch {
    return false;
  }
}

/** Briefs main for a host and asks, wanting its name typed for `be there` or no brief. */
async function goAhead(row: Row, rev: string, question: string): Promise<boolean> {
  const host = row.host;
  const t = performance.now();
  let word = host;
  let line: string;
  // A revision off main, a dirty tree's or a branch's, has nothing to brief against.
  const onMain =
    /^[0-9a-f]{40}$/.test(rev) && (await run("git", ["-C", root, "merge-base", "--is-ancestor", rev, main], { err: "none" })).status === 0;
  if (!onMain) {
    line = `!! ${host} runs ${short(rev)}, which is not a commit on main, so there is no brief for it.`;
  } else {
    const json = await brief(rev);
    if (json) {
      const lvl = level(host, json);
      line = `   the brief for ${host}: ${lvl}`;
      if (lvl !== "be there") word = "";
    } else {
      line = `!! preflight failed above, so what main changes on ${host} is unknown.`;
    }
  }
  row.ms.brief = since(t);
  say(`${line} (${took(row.ms.brief)})`);
  return confirm(question, word);
}

// --- The cache ---------------------------------------------------------------

/** 0 when the cache has a store path, 1 when it does not, 2 when it did not say. */
async function cached(path: string): Promise<0 | 1 | 2> {
  const url = `${CACHE}/${basename(path).slice(0, 32)}.narinfo`;
  const r = await run("curl", ["-sS", "-o", "/dev/null", "--max-time", "15", "-w", "%{http_code}", url], { err: "none" });
  const code = r.status === 0 ? r.stdout : "000";
  return code === "200" ? 0 : code === "404" ? 1 : 2;
}

/**
 * cache.yml's run for main, "<status> <conclusion>", `none` when GitHub lists
 * none, or `unknown` when it did not answer, its rate limit included: 60
 * calls an hour without a token, shared with everything on this address.
 */
async function cacheRun(): Promise<string> {
  const url = `https://api.github.com/repos/nnorx/nix-config/actions/workflows/cache.yml/runs?head_sha=${main}&per_page=1`;
  const r = await run("curl", ["-sS", "--max-time", "15", url], { err: "none" });
  if (r.status !== 0) return "unknown";
  const text = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v));
  try {
    const runs: unknown = (JSON.parse(r.stdout) as { workflow_runs?: unknown } | null)?.workflow_runs;
    if (!Array.isArray(runs)) return "unknown";
    if (runs.length === 0) return "none";
    const first = runs[0] as { status?: unknown; conclusion?: unknown };
    const c = first.conclusion;
    return `${text(first.status ?? null)} ${c === undefined || c === null || c === false ? "-" : text(c)}`;
  } catch {
    return "unknown";
  }
}

/** The cache asked every 30 seconds, GitHub every other minute, for its rate limit. */
async function waitForCache(host: string, path: string): Promise<void> {
  for (let polls = 0; ; polls++) {
    const status = await cached(path);
    if (status === 0) return;
    if (polls % 4 === 0) {
      const r = await cacheRun();
      const [state = "", ...rest] = r.split(" ");
      if (r.startsWith("completed")) {
        // Pushed between the two questions, or not at all.
        if ((await cached(path)) === 0) return;
        die(`cache.yml finished for main (${rest.length ? rest.join(" ") : r}) but ${host}'s system is not in the cache: ${REPO}/actions/workflows/cache.yml`);
      }
      // A push takes a moment to show up as a run.
      if (r === "none" && polls >= 10) die(`no cache.yml run for main after 5 minutes: ${REPO}/actions/workflows/cache.yml`);
      if (r === "unknown") say(`   ${host}'s system is not in the cache yet, and GitHub did not say how cache.yml is doing; asking again`);
      else say(`   ${host}'s system is not in the cache yet; cache.yml is ${state}, ${Math.floor(polls / 2)} min so far (Ctrl-C stops only this)`);
    }
    if (status === 2) say("   the cache did not answer; asking again");
    await sleep(30);
  }
}

// --- A host ------------------------------------------------------------------

/** A y, or the word typed back when one is given. */
async function confirm(question: string, word: string): Promise<boolean> {
  if (word) return (await answers.ask(`${question} Type ${word} to go ahead, anything else skips it: `)) === word;
  const answer = await answers.ask(`${question} [y/N] `);
  return answer === "y" || answer === "Y";
}

/**
 * Inside the host's reboot window, where the upgrade reboots for a new kernel
 * by itself. nixpkgs' comparison, on the host's clock.
 */
async function inWindow(host: string): Promise<boolean> {
  const pi = pis[host] ?? {};
  const str = (v: unknown) => (v === undefined || v === null || v === false ? "" : String(v));
  const lower = str(pi.window?.lower);
  const upper = str(pi.window?.upper);
  if (!lower || !upper) return false;
  const now = (await run("date", ["+%H:%M"], { env: { ...process.env, TZ: pi.tz || "UTC" } })).stdout.trim();
  return lower < upper ? now > lower && now < upper : now < upper || now > lower;
}

/**
 * Waits for a host to go down and answer again, and returns its status. Going
 * down is what says it rebooted: the old system answers while it stops, and a
 * request that never arrived looks to ssh like one cut off by the reboot.
 * Counted in polls, not by the clock, so the tests' sleep can run them out.
 */
async function rebooted(host: string): Promise<string> {
  let polls = 0;
  while ((await agent(15, host, "status", { out: "none", err: "none" })).status === 0) {
    if (++polls >= 36) die(`${host} still answers 3 minutes after its reboot was due, so it did not reboot; check on it`);
    await sleep(5);
  }
  say(`   ${host} is down; waiting for it to come back (up to 10 minutes)`);
  for (polls = 0; ; ) {
    const r = await agent(30, host, "status", { err: "none" });
    if (r.status === 0) return r.stdout;
    if (++polls >= 60) die(`${host} has not answered for 10 minutes since it went down; check on it`);
    await sleep(10);
  }
}

/** Running main, with no unit failed that had not failed before the deploy. */
function settled(host: string, status: string, before: string): boolean {
  const rev = get("revision", status);
  if (rev !== main) {
    say(`!! ${host} runs ${short(rev)}, not main (${short(main)}). If main moved during the deploy, the brief above was not for it.`);
    return false;
  }
  const was = new Set(words(before));
  const units = words(get("failed", status)).filter((u) => u !== "none");
  const old = units.filter((u) => was.has(u));
  const fresh = units.filter((u) => !was.has(u));
  if (old.length) say(`   still failed, as before the deploy: ${old.join(" ")}`);
  if (fresh.length) {
    say(`!! ${host} has units that failed during the deploy: ${fresh.join(" ")}`);
    return false;
  }
  return true;
}

/** Waits out a reboot asked for at t, and checks the boot. */
async function back(row: Row, t: number, before: string): Promise<void> {
  const status = await rebooted(row.host);
  row.ms.reboot = since(t);
  say(`   ${row.host} is back (${took(row.ms.reboot)})`);
  indent(status);
  if (!settled(row.host, status, before)) throw new Exit(1);
  row.result = "deployed";
}

async function rebootIntoMain(row: Row, before: string): Promise<void> {
  const host = row.host;
  const t = performance.now();
  const { status } = await agent(150, host, "reboot", { out: "indent", err: "indent" });
  // 255 is ssh's own: the reboot can close the session before the answer,
  // and so can a request that never got there. rebooted tells them apart.
  if (status === 75) die(`${host} refused to reboot while something ran that it would cut off; run fleet-deploy again when it ends`);
  if (status !== 0 && status !== 255) die(`${host} did not reboot`);
  await back(row, t, before);
}

async function deploy(host: string): Promise<void> {
  const row: Row = { host, ms: {} };
  rows.push(row);
  step(host);
  let t = performance.now();
  let s = await agent(60, host, "status");
  if (s.status !== 0) die(`${host} did not answer its deploy login`);
  row.ms.status = since(t);
  say(`   status (${took(row.ms.status)})`);
  indent(s.stdout);
  const rev = get("revision", s.stdout);
  const before = get("failed", s.stdout);

  if (get("hold", s.stdout) === "yes") {
    say(`   held, so left alone. 'fleet-deploy release ${host}' lets it upgrade again.`);
    row.result = "held";
    return;
  }
  const staged = `   main is staged for ${host}'s next boot: a new kernel, initrd or modules.`;
  const leftStaged = () => {
    say("   left staged; tonight's upgrade reboots it inside the window.");
    row.result = "left staged";
  };
  if (get("staged", s.stdout) === "yes" && get("next-boot", s.stdout) === main) {
    say(staged);
    if (await goAhead(row, rev, `Reboot ${host} into main now?`)) await rebootIntoMain(row, before);
    else leftStaged();
    return;
  }
  if (rev === main) {
    say("   already on main.");
    row.result = "already on main";
    return;
  }
  if (!(await goAhead(row, rev, `Deploy main to ${host}?`))) {
    say("   skipped.");
    row.result = "skipped";
    return;
  }

  t = performance.now();
  await waitForCache(host, pis[host]?.toplevel ?? "");
  row.ms.cache = since(t);
  say(`   ${host}'s system is in the cache (${took(row.ms.cache)})`);

  say("   upgrading; a substitute-only run takes minutes");
  t = performance.now();
  // The agent gives up on the upgrade after an hour.
  s = await agent(3700, host, "upgrade", { err: "keep" });
  row.ms.upgrade = since(t);
  if (s.status === 69) die(`${host} was held while this ran`);
  if (s.status !== 0) {
    if (s.stderr) indent(s.stderr);
    die(s.status === 75 ? `${host} was busy; run fleet-deploy again when its run ends` : `the upgrade on ${host} failed`);
  }
  say(`   upgraded (${took(row.ms.upgrade)})`);
  indent(s.stdout);

  if (get("staged", s.stdout) !== "yes") {
    if (!settled(host, s.stdout, before)) throw new Exit(1);
    row.result = "deployed";
    return;
  }
  const next = get("next-boot", s.stdout);
  if (next !== main) {
    say(`!! ${host} staged ${short(next)}, not main (${short(main)}). If main moved during the deploy, the brief above was not for it.`);
    throw new Exit(1);
  }
  say(staged);
  if (await inWindow(host)) {
    // Asking for a second reboot would race the one already scheduled.
    say("   inside the reboot window, so the upgrade has scheduled its own reboot a minute out");
    await back(row, performance.now(), before);
  } else if (await confirm(`Reboot ${host} into main now?`, "")) {
    await rebootIntoMain(row, before);
  } else {
    leftStaged();
  }
}

/** Each host's steps, timed; a host the run stopped at is `failed`, or `stopped` for Ctrl-C. */
function table(stopped: string): void {
  if (!rows.length) return;
  const cells = [
    ["host", "result", ...steps],
    ...rows.map((r) => [r.host, r.result ?? stopped, ...steps.map((s) => (r.ms[s] === undefined ? "-" : took(r.ms[s])))]),
  ];
  const widths = cells[0]!.map((_, i) => Math.max(...cells.map((c) => c[i]!.length)));
  say();
  for (const c of cells) say(`   ${c.map((v, i) => v.padEnd(widths[i]!)).join("  ")}`.trimEnd());
  say(`   in ${took(since(started))}`);
}

// --- The run -----------------------------------------------------------------

async function fleetDeploy(argv: string[]): Promise<void> {
  if (!key) die("FLEET_DEPLOY_KEY names no deploy key");
  let verb = "deploy";
  let asked = argv;
  if (["status", "hold", "release"].includes(argv[0] ?? "")) {
    verb = argv[0]!;
    asked = argv.slice(1);
  } else if (argv[0]?.startsWith("-")) {
    throw new Usage();
  }

  const top = await run("git", ["rev-parse", "--show-toplevel"], { err: "none" });
  if (top.status !== 0) {
    process.stderr.write("fleet-deploy: run it from a nix-config checkout\n");
    throw new Exit(64);
  }
  root = top.stdout.replace(/\n+$/, "");
  if (!(await run("git", ["-C", root, "remote", "get-url", "origin"], { err: "none" })).stdout.includes("nnorx/nix-config")) {
    process.stderr.write(`fleet-deploy: ${root} is not a nix-config checkout\n`);
    throw new Exit(64);
  }
  tmp = mkdtempSync(join(tmpdir(), "fleet-deploy."));

  const t = performance.now();
  if (verb === "deploy") {
    // What GitHub calls main, which is what the hosts' upgrade fetches.
    if ((await run("git", ["-C", root, "fetch", "--quiet", "origin", "main"])).status !== 0) die("could not fetch main");
    main = (await run("git", ["-C", root, "rev-parse", "FETCH_HEAD"])).stdout.trim();
    // From main on GitHub, as the hosts fetch it, so a Pi added or retimed
    // there is deployed as main has it and each toplevel is the path their
    // upgrade asks the cache for.
    pis = await hostsOf(
      `github:nnorx/nix-config/${main}`,
      `
    at = c.config.system.autoUpgrade.dates;
    toplevel = c.config.system.build.toplevel.outPath;
    window = c.config.system.autoUpgrade.rebootWindow;
    tz = c.config.time.timeZone;`,
    );
  } else {
    pis = await hostsOf(`git+file://${root}`, "at = c.config.system.autoUpgrade.dates;");
  }
  const at = (h: string) => String(pis[h]?.at ?? "");
  const order = Object.keys(pis).sort((a, b) => (at(a) < at(b) ? -1 : at(a) > at(b) ? 1 : 0));

  for (const h of asked) {
    if (!order.includes(h)) die(`${h} has no deploy login; only the Pis do (${order.join(" ")}). gate is deployed by hand.`);
  }
  const hosts = asked.length ? order.filter((h) => asked.includes(h)) : order;

  // Loaded once, so the logins never stop to ask for its passphrase; BatchMode
  // then makes anything else that would prompt a refusal rather than a hang.
  if ((await run("ssh-add", ["-T", `${key}.pub`], { out: "show", err: "none" })).status !== 0) {
    say("Loading the deploy key, which every login below uses:");
    if ((await run("ssh-add", [key], { stdin: "inherit", out: "show" })).status !== 0) die("the deploy key is not loaded");
  }

  if (verb !== "deploy") {
    let failed = 0;
    for (const host of hosts) {
      step(`${host} ${verb}`);
      // The agent's own deadline for hold and release is 2 minutes.
      if ((await agent(150, host, verb, { out: "indent", err: "indent" })).status !== 0) failed = 1;
    }
    throw new Exit(failed);
  }

  say(`main is ${short(main)}; deploying it to ${hosts.join(" ")}, one at a time (evaluated in ${took(since(t))})`);
  for (const host of hosts) await deploy(host);
  step("done");
  table("");
}

function cleanup(): void {
  if (!tmp) return;
  if (existsSync(join(tmp, "main"))) {
    spawnSync("git", ["-C", root, "worktree", "remove", "--force", join(tmp, "main")], { stdio: "ignore" });
  }
  rmSync(tmp, { recursive: true, force: true });
  tmp = "";
}

function stop(status: number): never {
  table("stopped");
  cleanup();
  process.exit(status);
}
process.on("SIGINT", () => stop(130));
process.on("SIGTERM", () => stop(143));

let status = 0;
try {
  await fleetDeploy(process.argv.slice(2));
} catch (e) {
  if (e instanceof Usage) {
    process.stderr.write(USAGE);
    status = 64;
  } else if (e instanceof Fatal) {
    table("failed");
    process.stderr.write(`fleet-deploy: ${e.message}\n`);
    status = 1;
  } else if (e instanceof Exit) {
    if (e.status !== 0) table("failed");
    status = e.status;
  } else {
    cleanup();
    throw e;
  }
}
cleanup();
process.exit(status);
