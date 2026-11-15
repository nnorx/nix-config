// A GraphQL query's cost as Linear adds it up, for stubs/curl, which refuses
// one past 10,000 points as Linear does. Each object costs OBJECT and each
// scalar field SCALAR; a connection, a field whose selection holds nodes or
// pageInfo, multiplies its children's cost by its `first:`, or 50 without
// one; siblings add up. Rounded up, as Linear rounds.
//
//   node cost.ts <query> [<variables as JSON>]
//
// Linear documents a scalar at 0.1, which refuses drafts.ts's WORKSPACE as
// Linear does not; 0.08 takes it, and refuses it with LABELS joined, as Linear did.
const OBJECT = 1;
const SCALAR = 0.08;
const PAGE = 50;

const [query = "", vars = "{}"] = process.argv.slice(2);
const variables: Record<string, unknown> = JSON.parse(vars) ?? {};
const tokens = query.match(/"(?:\\.|[^"\\])*"|\$?\w+|\.\.\.|[{}():]/g) ?? [];
let i = 0;

/** The `first:` in an argument list, at tokens[i] == "(", leaving i past its ")". */
function args(): number | undefined {
  let depth = 0;
  let first: number | undefined;
  do {
    const t = tokens[i]!;
    if (t === "(" || t === "{") depth++;
    else if (t === ")" || t === "}") depth--;
    else if (depth === 1 && t === "first" && tokens[i + 1] === ":") {
      const v = tokens[i + 2]!;
      first = Number(v.startsWith("$") ? variables[v.slice(1)] : v);
    }
    i++;
  } while (depth > 0 && i < tokens.length);
  return first;
}

/** A selection set's children, summed, at tokens[i] == "{", leaving i past its "}". */
function selection(): { cost: number; connection: boolean } {
  let cost = 0;
  let connection = false;
  i++;
  while (i < tokens.length && tokens[i] !== "}") {
    if (tokens[i] === "...") {
      throw new Error("cost.ts: fragments are not scored");
    }
    let name = tokens[i++]!;
    if (tokens[i] === ":") {
      name = tokens[i + 1]!;
      i += 2;
    }
    const first = tokens[i] === "(" ? args() : undefined;
    if (tokens[i] !== "{") {
      cost += SCALAR;
      continue;
    }
    const sub = selection();
    cost += sub.connection ? (first ?? PAGE) * sub.cost : OBJECT + sub.cost;
    connection ||= name === "nodes" || name === "pageInfo";
  }
  i++;
  return { cost, connection };
}

// Past the operation's name and variables to its selection.
while (i < tokens.length && tokens[i] !== "{") {
  if (tokens[i] === "(") args();
  else i++;
}
const { cost } = selection();
process.stdout.write(`${Math.ceil(cost - 1e-9)}\n`);
