import { die } from "./util.ts";

export type Mode = "forge" | "work";
export type Platform = "linux" | "darwin";

export interface Env {
  mode: Mode;
  platform: Platform;
  home: string;
  projects: string;
  stateDir: string;
  max: number;
  stallHours: number;
  /** Where Linear's API is. The tests point it at their stub. */
  linearUrl: string;
  keyFile?: string;
  keyCmd?: string;
  ntfyFile?: string;
  config?: string;
  settings?: string;
}

/** Forge's team states, in the order an issue moves through them. */
export const STATES = ["Queued", "Running", "Handoff ready", "Needs you"] as const;
export const QUEUED = STATES[0];

const set = (name: string): string | undefined => process.env[name] || undefined;

export function loadEnv(): Env {
  const mode = set("NIGHT_SHIFT_MODE") ?? "forge";
  const platform = set("NIGHT_SHIFT_PLATFORM") ?? "linux";
  if (mode !== "forge" && mode !== "work") die(`NIGHT_SHIFT_MODE is forge or work, not '${mode}'`);
  if (platform !== "linux" && platform !== "darwin") {
    die(`NIGHT_SHIFT_PLATFORM is linux or darwin, not '${platform}'`);
  }
  const home = set("HOME") ?? die("HOME is not set");
  return {
    mode,
    platform,
    home,
    projects: set("NIGHT_SHIFT_PROJECTS") ?? `${home}/projects`,
    stateDir: `${set("XDG_STATE_HOME") ?? `${home}/.local/state`}/night-shift`,
    max: Number(set("NIGHT_SHIFT_MAX") ?? 2),
    stallHours: Number(set("NIGHT_SHIFT_STALL_HOURS") ?? 4),
    linearUrl: set("NIGHT_SHIFT_LINEAR_URL") ?? "https://api.linear.app/graphql",
    keyFile: set("NIGHT_SHIFT_KEY_FILE"),
    keyCmd: set("NIGHT_SHIFT_KEY_CMD"),
    ntfyFile: set("NIGHT_SHIFT_NTFY_FILE"),
    config: set("NIGHT_SHIFT_CONFIG"),
    settings: set("NIGHT_SHIFT_SETTINGS"),
  };
}
