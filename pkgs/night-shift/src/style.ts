// Color and framing for what night-shift itself prints, on a terminal alone,
// and off with NO_COLOR (no-color.org). Text from a draft or from Linear is
// never colored inside: escapes go around whole lines, so the bytes shown are
// still the bytes filed.

const on = process.stdout.isTTY === true && !process.env.NO_COLOR;
const sgr = (code: string) => (s: string) => (on ? `\x1b[${code}m${s}\x1b[0m` : s);

export const bold = sgr("1");
export const dim = sgr("2");
export const red = sgr("31");
export const green = sgr("32");
export const yellow = sgr("33");
export const cyan = sgr("36");

/** A full-width rule that opens an item: `━━ <label> ━━━…`. */
export function rule(label: string): string {
  const width = Math.min(process.stdout.columns || 72, 80);
  return cyan(`━━ ${label} ${"━".repeat(Math.max(3, width - label.length - 4))}`);
}

/**
 * Text behind a `│` gutter, so where it starts and ends is plain, and no line
 * of it can pass for the frame around it. `color` picks a line's color, whole.
 */
export function gutter(text: string, color: (line: string) => (s: string) => string = () => (s) => s): string {
  return text
    .split("\n")
    .map((line) => `   ${dim("│")}${line ? ` ${color(line)(line)}` : ""}`)
    .join("\n");
}

/** A diff's line color: additions green, removals red, hunk headers cyan. */
export function diffColor(line: string): (s: string) => string {
  if (line.startsWith("@@")) return cyan;
  if (line.startsWith("+")) return green;
  if (line.startsWith("-")) return red;
  return (s) => s;
}
