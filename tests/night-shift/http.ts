// Linear, GitHub and ntfy over HTTP, for the dispatcher's TypeScript, which
// uses fetch where the shell uses curl. Each request is answered by
// stubs/curl, so both halves see one fake and log to one log.jsonl. Paths are
// /<case>/graphql, /<case>/github/<API path> and /<case>/ntfy, the case a
// directory under <work>.
//
//   node http.ts <work> <stubs/curl> <bash> <port file>
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";

const [work, stub, bash, portFile] = process.argv.slice(2) as [string, string, string, string];

const server = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c: Buffer) => chunks.push(c));
  req.on("end", () => {
    const m = /^\/([^/]+)\/(graphql|ntfy|github)(\/.*)?$/.exec(req.url ?? "");
    if (!m) {
      res.writeHead(404).end();
      return;
    }
    const [, name, what, rest] = m;
    const body = Buffer.concat(chunks).toString("utf8");
    const dir = mkdtempSync(`${tmpdir()}/night-shift-http.`);
    try {
      const config = `${dir}/config`;
      let args: string[];
      if (what === "graphql") {
        writeFileSync(config, `header = "Authorization: ${req.headers.authorization ?? ""}"\n`);
        args = ["-K", config, "--data-binary", body, "https://api.linear.app/graphql"];
      } else if (what === "github") {
        writeFileSync(config, "");
        args = ["-K", config, "-w", "\n%{http_code}", `https://api.github.com${rest ?? ""}`];
      } else {
        writeFileSync(config, `url = http://${req.headers.host}${req.url}\n`);
        args = ["-K", config, "-H", `Title: ${req.headers.title ?? ""}`, "--data-binary", body];
      }
      const r = spawnSync(bash, ["-euo", "pipefail", stub, ...args], {
        env: { ...process.env, NS_CASE: `${work}/${name}` },
        encoding: "utf8",
      });
      if (r.status === 0 && what === "github") {
        // The stub ends its answer with the status code, as curl -w writes it.
        const cut = r.stdout.lastIndexOf("\n");
        res.writeHead(Number(r.stdout.slice(cut + 1))).end(r.stdout.slice(0, cut));
      } else if (r.status === 0) res.writeHead(200).end(r.stdout);
      else if (what === "ntfy") res.writeHead(500).end(r.stderr);
      // As a host that does not answer.
      else req.socket.destroy();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(portFile, String((server.address() as { port: number }).port));
});
