import { die } from "./util.ts";

export type Mode = "forge" | "work";
export type Platform = "linux" | "darwin";

export interface Env {
  mode: Mode;
  platform: Platform;
  home: string;
  projects: string;
  stateDir: string;
  /** Agents at work at once, and hours of work with no result before one counts as quiet. Work mode's config may set both. */
  max: number;
  stallHours: number;
  /** Runs failed in a row before a push says so. */
  failedRuns: number;
  /** Seconds between runs, which caps what one run adds to an agent's working time. */
  interval: number;
  /** Where Linear's and GitHub's APIs are. The tests point them at their stub. */
  linearUrl: string;
  githubUrl: string;
  /** Paths hidden from preflight on an agent's branch, one per line. */
  hide: string;
  /** Where the machine's power supplies are listed, for whether it runs on AC. */
  powerDir: string;
  /** The dispatcher's own bash, for setup and the key command, whatever a config adds to PATH. */
  bash: string;
  keyFile?: string;
  keyCmd?: string;
  ntfyFile?: string;
  config?: string;
  settings?: string;
  /** A Mac's: the launchd log, and the job `night-shift resume` starts. */
  log?: string;
  launchdLabel?: string;
}

/** Forge's team states, in the order an issue moves through them. */
export const STATES = ["Queued", "Running", "Handoff ready", "Needs you"] as const;
export const [QUEUED, RUNNING, READY, NEEDS] = STATES;
/** The label on an issue Nick does himself, which forge never starts. */
export const HANDS_ON = "Hands on";

const set = (name: string): string | undefined => process.env[name] || undefined;

export function loadEnv(): Env {
  const mode = set("NIGHT_SHIFT_MODE") ?? "forge";
  const platform = set("NIGHT_SHIFT_PLATFORM") ?? "linux";
  if (mode !== "forge" && mode !== "work") die(`NIGHT_SHIFT_MODE is forge or work, not '${mode}'`);
  if (platform !== "linux" && platform !== "darwin") {
    die(`NIGHT_SHIFT_PLATFORM is linux or darwin, not '${platform}'`);
  }
  const interval = set("NIGHT_SHIFT_INTERVAL") ?? "600";
  if (!/^[1-9][0-9]*$/.test(interval)) die(`NIGHT_SHIFT_INTERVAL is a number of seconds, not '${interval}'`);
  const home = set("HOME") ?? die("HOME is not set");
  const whole = (name: string, fallback: string) => {
    const v = set(name) ?? fallback;
    if (!/^[0-9]+$/.test(v)) die(`${name} is a whole number, not '${v}'`);
    return Number(v);
  };
  return {
    mode,
    platform,
    home,
    projects: set("NIGHT_SHIFT_PROJECTS") ?? `${home}/projects`,
    stateDir: `${set("XDG_STATE_HOME") ?? `${home}/.local/state`}/night-shift`,
    max: whole("NIGHT_SHIFT_MAX", "2"),
    stallHours: whole("NIGHT_SHIFT_STALL_HOURS", "4"),
    failedRuns: whole("NIGHT_SHIFT_FAILED_RUNS", "3"),
    interval: Number(interval),
    linearUrl: set("NIGHT_SHIFT_LINEAR_URL") ?? "https://api.linear.app/graphql",
    githubUrl: set("NIGHT_SHIFT_GITHUB_URL") ?? "https://api.github.com",
    hide: set("NIGHT_SHIFT_HIDE") ?? "",
    powerDir: set("NIGHT_SHIFT_POWER") ?? "/sys/class/power_supply",
    bash: set("NIGHT_SHIFT_BASH") ?? "bash",
    keyFile: set("NIGHT_SHIFT_KEY_FILE"),
    keyCmd: set("NIGHT_SHIFT_KEY_CMD"),
    ntfyFile: set("NIGHT_SHIFT_NTFY_FILE"),
    config: set("NIGHT_SHIFT_CONFIG"),
    settings: set("NIGHT_SHIFT_SETTINGS"),
    log: set("NIGHT_SHIFT_LOG"),
    launchdLabel: set("NIGHT_SHIFT_LAUNCHD_LABEL"),
  };
}
