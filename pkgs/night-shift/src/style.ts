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

const GUTTER = 5; // "   │ "
const graphemes = new Intl.Segmenter();
// Two columns on a terminal: emoji shown as emoji, and East Asian wide and
// fullwidth forms. Erring wide only wraps a little early.
const WIDE =
  /\p{Emoji_Presentation}|\u{FE0F}|[\u{1100}-\u{115F}\u{2E80}-\u{303E}\u{3041}-\u{33FF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{A000}-\u{A4CF}\u{AC00}-\u{D7A3}\u{F900}-\u{FAFF}\u{FE30}-\u{FE4F}\u{FF00}-\u{FF60}\u{FFE0}-\u{FFE6}\u{20000}-\u{3FFFD}]/u;

/** The terminal's width, or no limit when output is not a terminal. */
function columns(): number {
  return process.stdout.isTTY ? process.stdout.columns || Infinity : Infinity;
}

/**
 * line in pieces that each fit within cols once the gutter is before them,
 * broken after a space where there is one. The pieces join back to line.
 */
export function wrap(line: string, cols: number): string[] {
  const gs = Array.from(graphemes.segment(line), (s) => s.segment);
  const pieces: string[] = [];
  let start = 0;
  let col = GUTTER;
  let afterSpace = -1;
  for (let i = 0; i < gs.length; i++) {
    const g = gs[i]!;
    // A tab stops at the terminal's next multiple of eight, gutter included.
    const w = g === "\t" ? 8 - (col % 8) : WIDE.test(g) ? 2 : 1;
    if (col + w > cols && i > start) {
      const cut = afterSpace > start ? afterSpace : i;
      pieces.push(gs.slice(start, cut).join(""));
      start = cut;
      i = cut - 1;
      col = GUTTER;
      afterSpace = -1;
      continue;
    }
    col += w;
    if (g === " ") afterSpace = i + 1;
  }
  pieces.push(gs.slice(start).join(""));
  return pieces;
}

/**
 * Text behind a `│` gutter, so where it starts and ends is plain, and no line
 * of it can pass for the frame around it. A line too long for the terminal
 * goes on behind `┆`, so a wrap never looks like a newline in the text.
 * `color` picks a line's color, for all of it.
 */
export function gutter(text: string, color: (line: string) => (s: string) => string = () => (s) => s, cols = columns()): string {
  return text
    .split("\n")
    .map((line) => {
      if (!line) return `   ${dim("│")}`;
      const paint = color(line);
      return wrap(line, cols)
        .map((piece, n) => `   ${dim(n ? "┆" : "│")} ${paint(piece)}`)
        .join("\n");
    })
    .join("\n");
}

/** A diff's line color: additions green, removals red, hunk headers cyan. */
export function diffColor(line: string): (s: string) => string {
  if (line.startsWith("@@")) return cyan;
  if (line.startsWith("+")) return green;
  if (line.startsWith("-")) return red;
  return (s) => s;
}
