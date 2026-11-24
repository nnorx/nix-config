// The gutter's wrapping, which both night-shift file and pr-handoff show
// drafts and PR text through: what Nick reads there must be the text itself.
import assert from "node:assert/strict";
import { test } from "node:test";
import { gutter, wrap } from "../../pkgs/night-shift/src/style.ts";

const LINES = [
  "a short line",
  "The widget takes a second to draw, and on forge it takes two; make it take less than either.",
  `a${"b".repeat(120)} then words`,
  "漢字".repeat(30),
  "emoji 🎉 in 🎉 the 🎉 middle 🎉 of 🎉 a 🎉 line 🎉 long 🎉 enough 🎉 to 🎉 wrap",
  "\ttabbed\ttext\tthat\tgoes\ton\tand\ton\tand\ton",
  "é combining marks é stay é whole é when é the é line é wraps",
];

/** Columns a piece takes after the gutter, tabs to the next stop of eight. */
function width(piece: string): number {
  let col = 5;
  for (const { segment: g } of new Intl.Segmenter().segment(piece)) {
    col += g === "\t" ? 8 - (col % 8) : /\p{Emoji_Presentation}|[\u{4E00}-\u{9FFF}]/u.test(g) ? 2 : 1;
  }
  return col;
}

test("style: wrapped pieces join back to the line, each within the width", () => {
  for (const cols of [20, 40, 80]) {
    for (const line of LINES) {
      const pieces = wrap(line, cols);
      assert.equal(pieces.join(""), line, `${cols}: ${line}`);
      for (const p of pieces) assert.ok(width(p) <= cols, `${cols}: '${p}' takes ${width(p)}`);
    }
  }
});

test("style: a line breaks after a space, a word too long for a row anywhere", () => {
  assert.deepEqual(wrap("aaaa bbbb cccc", 15), ["aaaa bbbb ", "cccc"]);
  assert.deepEqual(wrap("a".repeat(25), 15), ["a".repeat(10), "a".repeat(10), "aaaaa"]);
});

test("style: a wrap goes on behind ┆, a newline behind │, and no width means no wrap", () => {
  assert.equal(gutter("aaaa bbbb cccc\n\nnext", undefined, 15), "   │ aaaa bbbb \n   ┆ cccc\n   │\n   │ next");
  assert.equal(gutter(LINES[1]!, undefined, Infinity), `   │ ${LINES[1]}`);
});
