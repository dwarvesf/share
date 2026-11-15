// tests/worker.mjs: unit-drive the share Worker emitted from bin/share against
// in-memory bindings. Prints ok/FAIL lines like tests/share.sh; exit 1 on any FAIL.
// Rows covered: 17 (serving shapes), 18 (path/record/Host refusals), 19 (hits),
// 28 (the gated-record JWT check), the tenant rows 7 to 10 (PASS, ALIASES, the pass-through, the two-leg
// /healthz, against a stubbed origin fetch whose answers hold immutable headers), the Worker v5 rows of SPEC-009
// (`v5 <id>`: member pointers through a fake vpc_service binding, the redeem route against an R2 fake that honors
// onlyIf.etagMatches, and the named row of every answer), plus the WORKER_SHA/WORKER_VERSION self-checks
// and `node --check` on the emitted source. SHARE_WORKER_SRC=<file> reads the Worker from another bin/share (negative controls).
// Integration mode, `node tests/worker.mjs --dir <dry bucket> --host <host> <path>...`:
// the same Worker over a BUCKET loaded from a SHARE_R2_DRY_DIR, one "<code> <path>" line per path.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, unlinkSync, mkdirSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const sharePath = process.env.SHARE_WORKER_SRC || join(repo, "bin/share");
let fails = 0;
const check = (label, want, got) => {
  const ok = want instanceof RegExp ? want.test(String(got)) : want === got;
  if (ok) console.log("  ok    " + label);
  else { console.log(`  FAIL  ${label}: expected '${want}', got '${got}'`); fails++; }
};

// node's Response refuses status 101; workerd takes `new Response(null, { status: 101, webSocket })`. This stand-in lets the Worker's 101 path run here
const RealResponse = globalThis.Response;
globalThis.Response = class extends RealResponse {
  constructor(body, init) {
    if (init && init.status === 101) { super(null, { status: 200, headers: init.headers }); Object.defineProperty(this, "status", { value: 101 }); this.webSocket = init.webSocket; }
    else super(body, init);
  }
};

// the emitted Worker source, byte-identical to what `cat >file` writes
const awkProg = "/^  cat >\"\\$1\" <<.SHARE_WORKER_JS.$/{f=1;next} /^SHARE_WORKER_JS$/{f=0} f";
const src = execFileSync("awk", [awkProg, sharePath], { encoding: "utf8" });
const constOf = (name, text) => (text.match(new RegExp("^" + name + "=(\\S+)", "m")) || [])[1] || "";
const shareText = readFileSync(sharePath, "utf8");
const sha = createHash("sha256").update(src).digest("hex").slice(0, 12);
check("WORKER_SHA matches the emitted source", constOf("WORKER_SHA", shareText), sha);

let mainText = "";
try { mainText = execFileSync("git", ["-C", repo, "show", "origin/main:bin/share"], { encoding: "utf8" }); }
catch { if (process.env.CI === "true") check("origin/main fetched for the worker version check", "yes", "missing"); else console.log("  SKIP  origin/main not fetched; worker version check skipped"); }
if (mainText) {
  const mSha = constOf("WORKER_SHA", mainText), mVer = parseInt(constOf("WORKER_VERSION", mainText) || "0", 10);
  const thisVer = parseInt(constOf("WORKER_VERSION", shareText) || "0", 10);
  if (mSha !== sha) check("a source change carries a WORKER_VERSION bump", "above", thisVer > mVer ? "above" : `${thisVer} not above ${mVer}`);
  else check("worker source unchanged or version bumped", "ok", "ok");
}

const tmp = mkdtempSync(join(tmpdir(), "share-worker-"));
const srcFile = join(tmp, "worker.mjs");
writeFileSync(srcFile, src);
// the test copy adds named exports (the deployed source has none), so a row test reads decide() and each answer's row
const TEST_EXPORTS = "\nexport { route, decide, settleV3, decideRedeem, ROW, MISS, BAD_JSON, rowOf, NOT_FOUND };\n";
const testFile = join(tmp, "worker-test.mjs");
writeFileSync(testFile, src + TEST_EXPORTS);
try { execFileSync(process.execPath, ["--check", srcFile]); check("node --check on the emitted Worker", 0, 0); }
catch (e) { check("node --check on the emitted Worker", 0, 1); }

// --- fakes ---
const enc = (s) => new TextEncoder().encode(s);
const bodyOf = async (resp) => new TextDecoder().decode(await resp.arrayBuffer());
class Bucket {
  constructor() { this.m = new Map(); this.gets = 0; }
  put(key, data, meta = {}) {   // a test seed (meta: contentType), or the Worker's put: onlyIf.etagMatches answers null on a stale etag, as R2 does
    const bytes = typeof data === "string" ? enc(data) : data;
    const want = meta && meta.onlyIf && meta.onlyIf.etagMatches;
    if (want !== undefined) {
      const cur = this.m.get(key);
      if (!cur || cur.etag !== want) return null;
    }
    const etag = createHash("md5").update(bytes).digest("hex");
    this.m.set(key, { bytes, etag, meta: meta.onlyIf ? {} : meta, last: Date.now() });
    return { key, etag, size: bytes.length };
  }
  obj(key, rangeHdr) {
    const e = this.m.get(key);
    if (!e) return null;
    let bytes = e.bytes, range = null;
    const rh = rangeHdr && rangeHdr.get("range");
    const m = rh && rh.match(/^bytes=(\d*)-(\d*)$/), size = e.bytes.length;
    const unsat = () => { throw new Error("get: The requested range is not satisfiable (10039)"); };   // as live R2: a range past the end throws
    if (m && m[1] === "" && m[2] !== "") {   // a suffix range: the last n bytes, the whole object when n exceeds it
      const n = +m[2];
      if (n === 0) unsat();
      bytes = e.bytes.slice(Math.max(0, size - n));
      range = { offset: undefined, length: undefined, suffix: n };
    } else if (m && m[1] !== "") {
      const a = +m[1], b = m[2] ? +m[2] + 1 : size;
      if (a >= size) unsat();
      bytes = e.bytes.slice(a, Math.min(b, size));
      range = { offset: a, length: bytes.length, suffix: undefined };
    } else if (rangeHdr) range = { offset: 0, length: bytes.length, suffix: undefined };   // as live R2: any range option yields a range, Range header or not
    const body = new Blob([bytes]).stream();
    return {
      key, size: e.bytes.length, etag: e.etag, httpMetadata: e.meta, range,
      body,
      writeHttpMetadata(h) { if (e.meta.contentType) h.set("Content-Type", e.meta.contentType); },
      async text() { return new TextDecoder().decode(bytes); },
      async arrayBuffer() { return bytes.slice().buffer; },
      async json() { return JSON.parse(new TextDecoder().decode(bytes)); },
    };
  }
  async get(key, opts = {}) {
    this.gets++;
    const e = this.m.get(key);
    if (!e) return null;
    const oi = opts.onlyIf;
    if (oi) {
      const inm = oi.get("if-none-match"), im = oi.get("if-match");
      if ((inm && (inm === "*" || inm.includes(e.etag))) || (im && im !== "*" && !im.includes(e.etag))) {
        return { key, size: e.bytes.length, etag: e.etag, httpMetadata: e.meta, range: null, body: null, writeHttpMetadata() {} };
      }
    }
    return this.obj(key, opts.range);
  }
  async head(key) { const e = this.m.get(key); return e ? { key, size: e.bytes.length, etag: e.etag, httpMetadata: e.meta } : null; }
  async list({ prefix = "" } = {}) { return { objects: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((k) => ({ key: k })) }; }
  async delete(key) { this.m.delete(key); }
}
const hits = () => ({ points: [], writeDataPoint(p) { this.points.push(p); } });
const envOf = (bucket, over = {}) => ({ HOST: "f.test", VERSION: "1", SHA: "abc123def456", TEAM: "t.cloudflareaccess.com", SALT: "pepper", BUCKET: bucket, HITS: hits(), ...over });
const ctxOf = () => ({ waitUntil(p) { (this.ps ||= []).push(p); } });
const call = async (worker, env, url, opts = {}) => {
  const c = ctxOf();
  const resp = await worker.fetch(new Request(url, opts), env, c);
  await Promise.allSettled(c.ps || []);
  await note(worker, resp);
  return resp;
};
let modn = 0;
const modOf = new WeakMap();   // a loaded Worker's default export -> its whole test module (rowOf, decide, ...)
const loadMod = async (file = testFile) => {
  const mod = await import("file://" + file + "?m=" + ++modn);
  modOf.set(mod.default, mod);
  return mod;
};
const loadWorker = async () => (await loadMod()).default;
const answers = [];   // every answer of every row: its row id, status, and the body of a 404 (SV-26)
const note = async (worker, resp) => {
  const mod = modOf.get(worker);
  if (!mod || !(resp instanceof Response)) return;   // a 101 stub is no Response; the row file is checked on the rest
  const row = mod.rowOf.get(resp);
  const body404 = resp.status === 404 ? await resp.clone().text() : "";
  answers.push({ row, status: resp.status, body404, headers: [...resp.headers], ROW: mod.ROW, NF: mod.NOT_FOUND });
};

const ID = "a1b2c3", NONCE = "f00dcafe";
const rec = (over = {}) => ({ v: 1, id: ID, name: "f.txt", src: "/tmp/x", added: "2026-01-01", expires: 0, opts: "", prefix: `o/${ID}.${NONCE}/`, by: "mini", ...over });
const putRec = (b, over = {}) => b.put("m/" + ID, JSON.stringify(rec(over)));

if (process.argv[2] === "--dir") {
  // options after --dir <d> --host <h>: --bind M_<8hex>=127.0.0.1:<port> (a vpc_service binding that reaches a local listener, Host kept),
  // --post <path> <body> (one POST; prints "<code> <path>", then the body). The deployed PAUSED and MEMBERS come from <d>/.cf/script.json.
  // Every bucket change a call makes (the redeem's claim and delete) is written back to <d>, so the dry bucket sees it.
  const dir = process.argv[3], host = process.argv[5], bucket = new Bucket(), over = { HOST: host }, posts = [], paths = [], wss = [];
  const walk = (d) => readdirSync(d, { withFileTypes: true }).forEach((e) => {
    if (e.name.startsWith(".")) return;   // the dry seam's .cf, .fx, and .resume are not objects
    const f = join(d, e.name);
    if (e.isDirectory()) walk(f); else bucket.put(relative(dir, f), readFileSync(f));
  });
  walk(dir);
  const before = new Map([...bucket.m].map(([k, v]) => [k, v.etag]));
  try {
    for (const b of JSON.parse(readFileSync(join(dir, ".cf/script.json"), "utf8")).bindings || [])
      if (b.type === "plain_text" && (b.name === "PAUSED" || b.name === "MEMBERS")) over[b.name] = b.text;
  } catch {}
  const args = process.argv.slice(6);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--bind") {
      const [name, addr] = args[++i].split("="), [h, port] = addr.split(":");
      over[name] = { fetch: (req) => new Promise((res, rej) => {
        const u = new URL(req.url), hdrs = Object.fromEntries(req.headers);
        hdrs.host = u.host;
        const r = http.request({ host: h, port: +port, path: u.pathname + u.search, method: req.method, headers: hdrs }, (resp) => {
          const chunks = [];
          resp.on("data", (c) => chunks.push(c));
          resp.on("end", () => {
            const hs = new Headers();
            for (const [k, v] of Object.entries(resp.headers)) hs.set(k, Array.isArray(v) ? v.join(", ") : v);
            const nb = [101, 204, 205, 304].includes(resp.statusCode) || req.method === "HEAD";
            res(new Response(nb ? null : Buffer.concat(chunks), { status: resp.statusCode, headers: hs }));
          });
        });
        r.on("upgrade", (resp, socket) => {   // a WebSocket upgrade: the 101 and its socket go back as the binding's answer, as a Worker binding returns them
          const hs = new Headers();
          for (const [k, v] of Object.entries(resp.headers)) hs.set(k, Array.isArray(v) ? v.join(", ") : v);
          socket.on("error", () => {});
          res({ status: 101, headers: hs, body: null, webSocket: socket });
        });
        r.on("error", rej); r.end();
      }) };
    } else if (args[i] === "--post") { posts.push([args[i + 1], args[i + 2]]); i += 2; }
    else if (args[i] === "--ws") { wss.push(args[++i]); }
    else paths.push(args[i]);
  }
  const worker = await loadWorker(), env = envOf(bucket, over);
  for (const [path, body] of posts) {
    const r = await call(worker, env, "https://" + host + path, { method: "POST", body });
    console.log(`${r.status} ${path}`); console.log(await bodyOf(r));
  }
  for (const path of paths) console.log(`${(await call(worker, env, "https://" + host + path)).status} ${path}`);
  for (const path of wss) {   // --ws <path>: a WebSocket handshake through the Worker; on a 101 one masked text frame goes in and the echo prints
    const r = await call(worker, env, "https://" + host + path, { headers: { Upgrade: "websocket", Connection: "Upgrade", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==" } });
    let echo = "";
    if (r.status === 101 && r.webSocket) {
      const sock = r.webSocket, mask = Buffer.from([1, 2, 3, 4]), data = Buffer.from("ping-ws");
      const body = Buffer.from(data.map((c, i) => c ^ mask[i % 4]));
      sock.write(Buffer.concat([Buffer.from([0x81, 0x80 | data.length]), mask, body]));
      echo = await new Promise((resolve) => { const t = setTimeout(() => resolve("no echo"), 4000); sock.once("data", (b) => { clearTimeout(t); resolve(b.subarray(2).toString()); }); });
      sock.destroy();
    }
    console.log(`${r.status} ${path} ws${echo ? " " + echo : ""}`);
  }
  for (const [k, etag] of before) if (!bucket.m.has(k)) unlinkSync(join(dir, k));
  for (const [k, v] of bucket.m) if (before.get(k) !== v.etag) { mkdirSync(dirname(join(dir, k)), { recursive: true }); writeFileSync(join(dir, k), v.bytes); }
  process.exit(0);
}

// --- row 17: serving shapes ---
{
  const worker = await loadWorker();
  const b = new Bucket(), env = envOf(b);
  putRec(b); b.put(`o/${ID}.${NONCE}/f.txt`, "0123456789");
  let r = await call(worker, env, `https://f.test/${ID}/`);
  check("r17 /<id>/ missing index 404 (no index or README yet)", 404, r.status);
  b.put(`o/${ID}.${NONCE}/index.html`, "idx");
  r = await call(worker, env, `https://f.test/${ID}/`);
  check("r17 /<id>/ serves index.html", 200, r.status);
  check("r17 index body", "idx", await bodyOf(r));
  check("r17 index content-type", "text/html", r.headers.get("content-type"));
  b.delete(`o/${ID}.${NONCE}/index.html`); b.put(`o/${ID}.${NONCE}/README.html`, "readme");
  r = await call(worker, env, `https://f.test/${ID}/`);
  check("r17 README.html is the index fallback", "readme", await bodyOf(r));
  b.put(`o/${ID}.${NONCE}/sub/index.html`, "sub");
  r = await call(worker, env, `https://f.test/${ID}/sub`);
  check("r17 folder without slash 308", 308, r.status);
  check("r17 308 target", `https://f.test/${ID}/sub/`, r.headers.get("location"));
  r = await call(worker, env, `https://f.test/${ID}`);
  check("r17 /<id> 308", 308, r.status);
  check("r17 /<id> 308 target", `https://f.test/${ID}/`, r.headers.get("location"));
  r = await call(worker, env, `https://f.test/${ID}/missing.txt`);
  check("r17 missing file 404", 404, r.status);
  r = await call(worker, env, `https://f.test/${ID}/noindex/`);
  check("r17 subfolder with no index 404", 404, r.status);
  b.put(`o/${ID}.${NONCE}/My Notes/index.html`, "spaced"); b.put(`o/${ID}.${NONCE}/Ünï/README.html`, "uni");
  r = await call(worker, env, `https://f.test/${ID}/My%20Notes/`);
  check("r17 a folder name with a space serves its index", "200 spaced", `${r.status} ${await bodyOf(r)}`);
  r = await call(worker, env, `https://f.test/${ID}/My%20Notes`);
  check("r17 the same folder without slash 308", 308, r.status);
  r = await call(worker, env, `https://f.test/${ID}/%C3%9Cn%C3%AF/`);
  check("r17 a non-ASCII folder name serves its README", "200 uni", `${r.status} ${await bodyOf(r)}`);
  r = await call(worker, env, `https://f.test/${ID}/%zz/`);
  check("r17 a malformed escape in a folder path 400", 400, r.status);
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { method: "HEAD" });
  check("r17 HEAD status", 200, r.status);
  check("r17 HEAD empty body", "", await bodyOf(r));
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { range: "bytes=0-3" } });
  check("r17 Range 206", 206, r.status);
  check("r17 Range body", "0123", await bodyOf(r));
  check("r17 Range Content-Range", "bytes 0-3/10", r.headers.get("content-range"));
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { range: "bytes=-4" } });
  check("r17 suffix Range", "206 bytes 6-9/10 6789", `${r.status} ${r.headers.get("content-range")} ${await bodyOf(r)}`);
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { range: "bytes=-50" } });
  check("r17 a suffix longer than the object clamps to byte 0", "206 bytes 0-9/10 0123456789", `${r.status} ${r.headers.get("content-range")} ${await bodyOf(r)}`);
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { range: "bytes=20-30" } });
  check("r17 an unsatisfiable Range is 416 with the size", "416 bytes */10", `${r.status} ${r.headers.get("content-range")}`);
  check("r17 no-store on a 416", "no-store", r.headers.get("cache-control"));
  r = await call(worker, env, `https://f.test/${ID}/missing.txt`, { headers: { range: "bytes=20-30" } });
  check("r17 a Range on a missing file is still 404", 404, r.status);
  r = await call(worker, env, `https://f.test/${ID}/f.txt`);
  check("r17 a plain GET is 200, not 206", "200 null", `${r.status} ${r.headers.get("content-range")}`);
  r = await call(worker, env, `https://f.test/healthz`);
  check("r17 /healthz 200", 200, r.status);
  check("r17 /healthz body", "ok", await bodyOf(r));
  check("r17 X-Share-Worker pair", "1 abc123def456", r.headers.get("x-share-worker"));
  check("r17 X-Share-Gate on", "1", r.headers.get("x-share-gate"));
  r = await call(worker, env, `https://f.test/${ID}/f.txt`);
  check("r17 no-store", "no-store", r.headers.get("cache-control"));
  check("r17 noindex", "noindex, nofollow", r.headers.get("x-robots-tag"));
}

// --- row 18: path, record, and Host refusals ---
{
  const worker = await loadWorker();
  const b = new Bucket(), env = envOf(b);
  putRec(b); b.put(`o/${ID}.${NONCE}/f.txt`, "x"); b.put(`o/${ID}.${NONCE}/50%.v1.txt`, "pct");
  const st = async (u, o = {}) => (await call(worker, env, u, o)).status;
  const host = `https://f.test`;
  check("r18 /x/..%2F<id>/f", 400, await st(`${host}/x/..%2F${ID}/f.txt`));
  check("r18 /%2f<id>/f", 400, await st(`${host}/%2f${ID}/f.txt`));
  check("r18 /x/..%5C<id>/f", 400, await st(`${host}/x/..%5C${ID}/f.txt`));
  check("r18 /<id>/a%2Ehtml", 400, await st(`${host}/${ID}/a%2Ehtml`));
  check("r18 //<id>/f", 400, await st(`${host}//${ID}/f.txt`));
  check("r18 /<id>/%zz", 400, await st(`${host}/${ID}/%zz`));
  check("r18 /<id>/%01", 400, await st(`${host}/${ID}/%01`));
  check("r18 /<ID>/f uppercase 404", 404, await st(`${host}/A1B2C3/f.txt`));
  check("r18 /%61<id minus a>/f 404: the id segment is never decoded", 404, await st(`${host}/%61${ID.slice(1)}/f.txt`));
  check("r18 /<id>/50%25.v1.txt 200", 200, await st(`${host}/${ID}/50%25.v1.txt`));
  check("r18 query %2F ignored 200", 200, await st(`${host}/${ID}/f.txt?next=%2Fhome`));
  check("r18 Host f.test. 404", 404, await st(`https://f.test./${ID}/f.txt`));
  check("r18 other Host 404", 404, await st(`https://other.test/${ID}/f.txt`));
  check("r18 POST 405", 405, await st(`${host}/${ID}/f.txt`, { method: "POST" }));
  // bad records
  const bad = async (over) => { const b2 = new Bucket(), e2 = envOf(b2); b2.put("m/" + ID, JSON.stringify(rec(over))); return (await call(worker, e2, `${host}/${ID}/f.txt`)).status; };
  check("r18 prefix names another id", 404, await bad({ prefix: `o/ffffff.${NONCE}/` }));
  check("r18 record id differs from key", 404, await bad({ id: "ffffff" }));
  check("r18 expired record", 404, await bad({ expires: 1 }));
  check("r18 v above the worker's", 404, await bad({ v: 2 }));
  check("r18 bad prefix shape", 404, await bad({ prefix: `o/${ID}.${NONCE}` }));
  const r = await call(worker, env, `${host}/%2f${ID}/f.txt`);
  check("r18 no-store on a 400", "no-store", r.headers.get("cache-control"));
  check("r18 noindex on a 400", "noindex, nofollow", r.headers.get("x-robots-tag"));
}

// --- row 19: hit points ---
{
  const worker = await loadWorker();
  const b = new Bucket(), env = envOf(b);
  putRec(b); b.put(`o/${ID}.${NONCE}/f.txt`, "x");
  let r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { "cf-connecting-ip": "9.9.9.9" } });
  check("r19 one point for a 200", 1, env.HITS.points.length);
  const p = env.HITS.points[0] || {};
  check("r19 index1 is the id", ID, (p.indexes || [])[0]);
  check("r19 blob2 is 16 hex", /^[0-9a-f]{16}$/, (p.blobs || [])[1]);
  check("r19 blob2 is not the IP", false, (p.blobs || [])[1] === "9.9.9.9");
  await call(worker, env, `https://f.test/${ID}/missing`);
  await call(worker, env, `https://f.test/healthz`);
  check("r19 no point for a 404 or /healthz", 1, env.HITS.points.length);
}

// --- row 28: the gated-record JWT check ---
const TEAM = "t.cloudflareaccess.com";
const AUD = "a".repeat(64);
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const mkKeys = async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  jwk.kid = "k1"; jwk.alg = "RS256";
  return { pair, jwk };
};
const signJwt = async (priv, head, body) => {
  const h = b64url(enc(JSON.stringify(head))), b = b64url(enc(JSON.stringify(body)));
  const sig = await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, priv, enc(h + "." + b));
  return h + "." + b + "." + b64url(new Uint8Array(sig));
};
const jwtFor = (aud, over = {}) => ({ iss: "https://" + TEAM, aud, exp: Math.floor(Date.now() / 1000) + 300, ...over });
const serveCerts = (keys) => { globalThis.fetch = async () => ({ ok: true, json: async () => ({ keys }) }); };
const failCerts = () => { globalThis.fetch = async () => { throw new Error("down"); }; };
const gated = async (worker, env, headers = {}, path = `/${ID}/f.txt`) =>
  (await call(worker, env, `https://f.test${path}`, { headers })).status;
{
  const { pair, jwk } = await mkKeys();
  serveCerts([jwk]);
  const worker = await loadWorker();
  const b = new Bucket(), env = envOf(b);
  b.put("m/" + ID, JSON.stringify(rec({ opts: `access=00000000-0000-4000-8000-00000000a1b2`, aud: AUD })));
  b.put(`o/${ID}.${NONCE}/f.txt`, "secret");
  const good = async (claims = {}) => ({ "cf-access-jwt-assertion": await signJwt(pair.privateKey, { alg: "RS256", kid: "k1" }, jwtFor(AUD, claims)) });
  check("r28 no header", 404, await gated(worker, env));
  const other = await mkKeys();
  const wrongKey = await signJwt(other.pair.privateKey, { alg: "RS256", kid: "k9" }, jwtFor(AUD));
  check("r28 unknown key", 404, await gated(worker, env, { "cf-access-jwt-assertion": wrongKey }));
  check("r28 wrong aud", 404, await gated(worker, env, await good({ aud: "b".repeat(64) })));
  check("r28 expired", 404, await gated(worker, env, await good({ exp: Math.floor(Date.now() / 1000) - 5 })));
  check("r28 wrong iss", 404, await gated(worker, env, await good({ iss: "https://evil.cloudflareaccess.com" })));
  check("r28 valid", 200, await gated(worker, env, await good()));
  check("r28 valid array aud", 200, await gated(worker, env, await good({ aud: ["x".repeat(64), AUD] })));
  check("r28 nbf in the future", 404, await gated(worker, env, await good({ nbf: Math.floor(Date.now() / 1000) + 300 })));
  check("r28 nbf not a number", 404, await gated(worker, env, await good({ nbf: "0" })));
  check("r28 nbf in the past", 200, await gated(worker, env, await good({ nbf: Math.floor(Date.now() / 1000) - 5 })));
  check("r28 normalized backtrack path, no header", 404, await gated(worker, env, {}, `/x/..\\${ID}/f.txt`));
  check("r28 malformed token", 404, await gated(worker, env, { "cf-access-jwt-assertion": "not-a-jwt" }));
  const none = await signJwt(pair.privateKey, { alg: "none" }, jwtFor(AUD));
  check("r28 alg none", 404, await gated(worker, env, { "cf-access-jwt-assertion": none }));
  const hs = await signJwt(pair.privateKey, { alg: "HS256" }, jwtFor(AUD));
  check("r28 alg HS256", 404, await gated(worker, env, { "cf-access-jwt-assertion": hs }));
  check("r28 empty aud", 404, await gated(worker, env, await good({ aud: "" })));
  // a record gated by opts alone, no aud: a valid JWT still gets 404 (fail closed), never the bytes
  const w5 = await loadWorker(), e5 = envOf(new Bucket());
  e5.BUCKET.put("m/" + ID, JSON.stringify(rec({ opts: `access=00000000-0000-4000-8000-00000000a1b2` }))); e5.BUCKET.put(`o/${ID}.${NONCE}/f.txt`, "s");
  check("r28 access= in opts with no aud, valid JWT", 404, await gated(w5, e5, await good()));
  // TEAM empty
  const w2 = await loadWorker(), e2 = envOf(new Bucket(), { TEAM: "" });
  e2.BUCKET.put("m/" + ID, JSON.stringify(rec({ aud: AUD }))); e2.BUCKET.put(`o/${ID}.${NONCE}/f.txt`, "s");
  check("r28 TEAM empty", 404, await gated(w2, e2, await good()));
  // certs unreachable
  failCerts();
  const w3 = await loadWorker(), e3 = envOf(new Bucket());
  e3.BUCKET.put("m/" + ID, JSON.stringify(rec({ aud: AUD }))); e3.BUCKET.put(`o/${ID}.${NONCE}/f.txt`, "s");
  check("r28 certs unreachable", 404, await gated(w3, e3, await good()));
  // record aud malformed
  const w4 = await loadWorker(), e4 = envOf(new Bucket());
  e4.BUCKET.put("m/" + ID, JSON.stringify(rec({ aud: "short" }))); e4.BUCKET.put(`o/${ID}.${NONCE}/f.txt`, "s");
  check("r28 malformed record aud", 404, await gated(w4, e4, await good()));
}

// --- tenant rows 7 to 10: PASS (a route in front of the tunnel), ALIASES, the two-leg /healthz ---
// the stub stands in for the origin: it records every fetch and answers from a fixture whose headers are immutable, as a real fetch answer's are
const frozen = (resp) => {
  const h = resp.headers;
  const ro = new Proxy(h, { get(t, k) {
    if (k === "set" || k === "append" || k === "delete") return () => { throw new TypeError("immutable headers"); };
    const v = Reflect.get(t, k); return typeof v === "function" ? v.bind(t) : v;
  } });
  Object.defineProperty(resp, "headers", { value: ro });
  return resp;
};
let seen = [], answer = () => frozen(new Response("from origin", { status: 200, headers: { "cf-cache-status": "DYNAMIC" } }));
const stubOrigin = () => {
  globalThis.fetch = async (req, init = {}) => {
    const r = typeof req === "string" ? new Request(req, init) : req;
    seen.push({ url: r.url, method: r.method, body: ["GET", "HEAD"].includes(r.method) ? "" : await r.clone().text(), upgrade: r.headers.get("upgrade") || "", signal: !!init.signal });
    return answer(r, init);
  };
};
const tenantEnv = (bucket, over = {}) => envOf(bucket, { HOST: "s.test", PASS: "1", ALIASES: "", ...over });
const tget = async (worker, env, path, opts = {}, host = "s.test") => call(worker, env, `https://${host}${path}`, opts);
const nsni = (r) => `${r.headers.get("cache-control")}|${r.headers.get("x-robots-tag")}`;
const MID = "b1c2d3";
stubOrigin();
{
  const worker = await loadWorker();
  const b = new Bucket(), env = tenantEnv(b);
  putRec(b); b.put(`o/${ID}.${NONCE}/f.txt`, "cloud bytes");
  b.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "mac-mini", added: "2026-10-01", expires: 0, opts: "", type: "text" }));
  seen = [];
  let r = await tget(worker, env, `/${ID}/f.txt`);
  check("r7 a cloud record serves R2 bytes, no pass-through", "200 cloud bytes 0", `${r.status} ${await bodyOf(r)} ${seen.length}`);
  check("r7 the cloud answer carries no-store and noindex", "no-store|noindex, nofollow", nsni(r));
  const through = async (label, path) => {
    seen = [];
    const resp = await tget(worker, env, path);
    check(`r7 ${label} passes through`, `200 from origin 1 https://s.test${path}`, `${resp.status} ${await bodyOf(resp)} ${seen.length} ${(seen[0] || {}).url}`);
    check(`r7 ${label}: no-store and noindex on the rewrapped answer`, "no-store|noindex, nofollow", nsni(resp));
  };
  await through("a machine record", `/${MID}/f.txt`);
  await through("no record", "/c0ffee/f.txt");
  await through("a non-hex first segment", "/assets/app.js");
  await through("the root", "/");
  const thrower = new Bucket(); thrower.get = async () => { throw new Error("R2 down"); };
  const et = tenantEnv(thrower);
  seen = [];
  r = await tget(worker, et, `/${ID}/f.txt`);
  check("r7 the bucket throws: passes through", "200 1", `${r.status} ${seen.length}`);
  const expired = new Bucket(), ee = tenantEnv(expired);
  expired.put("m/" + ID, JSON.stringify(rec({ expires: 1 }))); expired.put(`o/${ID}.${NONCE}/f.txt`, "stale");
  seen = [];
  r = await tget(worker, ee, `/${ID}/f.txt`);
  check("r7 an expired cloud record is 404, never passed through", "404 0", `${r.status} ${seen.length}`);
  const other = new Bucket(), eo = tenantEnv(other);
  other.put("m/" + ID, JSON.stringify(rec({ prefix: `o/ffffff.${NONCE}/` }))); other.put(`o/ffffff.${NONCE}/f.txt`, "theirs");
  seen = [];
  r = await tget(worker, eo, `/${ID}/f.txt`);
  check("r7 a prefix naming another id is 404, never passed through", "404 0", `${r.status} ${seen.length}`);
  for (const [label, body] of [["not JSON", "{"], ["v:3", JSON.stringify(rec({ v: 3 }))], ["v:2 cloud storage", JSON.stringify(rec({ v: 2, storage: "cloud" }))],
    ["v:1 with a storage key", JSON.stringify(rec({ storage: "machine" }))]]) {
    const ob = new Bucket(), oe = tenantEnv(ob); ob.put("m/" + ID, body); ob.put(`o/${ID}.${NONCE}/f.txt`, "x");
    seen = [];
    r = await tget(worker, oe, `/${ID}/f.txt`);
    check(`r7 ${label} is 404, never passed through`, "404 0", `${r.status} ${seen.length}`);
  }
  r = await tget(worker, env, `/${ID}/f.txt`, { method: "POST", body: "x" });
  check("r7 a cloud record refuses other methods", 405, r.status);
  seen = [];
  for (const p of [`/x/..%2F${MID}/f.txt`, `//${MID}/f.txt`, `/%2F${MID}/f.txt`, `/${MID}/a%2Ehtml`]) {
    r = await tget(worker, env, p);
    check(`r7 ${p} is 400 in front of the tunnel`, 400, r.status);
  }
  check("r7 no encoded path reached the origin", 0, seen.length);
}

// --- row 8: what the pass-through hands back ---
{
  const worker = await loadWorker();
  const b = new Bucket(), env = tenantEnv(b);
  b.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "mac-mini", added: "2026-10-01", expires: 0, opts: "live", type: "site" }));
  const via = async (status, headers, body = "origin says") => {
    answer = () => frozen(new Response(status === 204 ? null : body, { status, headers }));
    seen = [];
    return tget(worker, env, `/${MID}/f.txt`);
  };
  let r = await via(200, { "cf-cache-status": "DYNAMIC", "x-origin": "1" }, "hello");
  check("r8 200 with a body goes back unchanged", "200 hello 1", `${r.status} ${await bodyOf(r)} ${r.headers.get("x-origin")}`);
  r = await via(404, { "cf-cache-status": "DYNAMIC" }, "nope");
  check("r8 the origin's 404 goes back unchanged", "404 nope", `${r.status} ${await bodyOf(r)}`);
  r = await via(503, { "cf-cache-status": "DYNAMIC" }, "caddy 503");
  check("r8 the origin's own 503 (cf-cache-status) goes back unchanged", "503 caddy 503", `${r.status} ${await bodyOf(r)}`);
  r = await via(502, { "cf-cache-status": "DYNAMIC" }, "dead port");
  check("r8 a dead live port's 502 (cf-cache-status) goes back unchanged, not the offline page", "502 dead port", `${r.status} ${await bodyOf(r)}`);
  r = await via(502, { server: "cloudflare" }, "<title>502</title>");
  check("r8 a 502 with no cf-cache-status also goes back unchanged (only 530/52x/503-no-cache mean offline)", "502 <title>502</title>", `${r.status} ${await bodyOf(r)}`);
  const offline = async (label, resp) => {
    check(`r8 ${label}: the 503 offline page`, "503 60 the machine serving this link is offline; try again later",
      `${resp.status} ${resp.headers.get("retry-after")} ${await bodyOf(resp)}`);
    check(`r8 ${label}: no-store and noindex`, "no-store|noindex, nofollow", nsni(resp));
  };
  await offline("530", await via(530, {}, "error code: 1033"));
  await offline("an edge 503 (no cf-cache-status)", await via(503, {}, "edge"));
  await offline("522", await via(522, {}, "timeout"));
  answer = () => { throw new Error("connect failed"); };
  seen = [];
  await offline("a thrown fetch", await tget(worker, env, `/${MID}/f.txt`));
  answer = () => frozen(new Response("posted", { status: 200, headers: { "cf-cache-status": "DYNAMIC" } }));
  seen = [];
  r = await tget(worker, env, `/${MID}/api`, { method: "POST", body: "payload-123" });
  check("r8 a POST is forwarded with its method and body", "200 POST payload-123", `${r.status} ${(seen[0] || {}).method} ${(seen[0] || {}).body}`);
  const ws = { status: 101, webSocket: {}, headers: new Headers({ upgrade: "websocket" }) };
  answer = () => ws;
  seen = [];
  r = await worker.fetch(new Request(`https://s.test/${MID}/ws`, { headers: { upgrade: "websocket" } }), env, ctxOf());
  check("r8 the upgrade is forwarded and its 101 returned untouched", "true websocket", `${r === ws} ${(seen[0] || {}).upgrade}`);
  check("r8 no Analytics Engine data point for any pass-through", 0, env.HITS.points.length);
}

// --- row 9: aliases and a PASS-less Worker ---
{
  const worker = await loadWorker();
  const b = new Bucket(), env = tenantEnv(b, { ALIASES: "f.test" });
  seen = [];
  let r = await tget(worker, env, "/ba6377/g/?a=1", {}, "f.test");
  check("r9 GET on the alias 301s to the same path and query on HOST", "301 https://s.test/ba6377/g/?a=1", `${r.status} ${r.headers.get("location")}`);
  r = await tget(worker, env, "/ba6377/g/?a=1", { method: "HEAD" }, "f.test");
  check("r9 HEAD on the alias 301s", 301, r.status);
  r = await tget(worker, env, "/ba6377/g/", { method: "POST", body: "x" }, "f.test");
  check("r9 POST on the alias is 405", 405, r.status);
  r = await tget(worker, env, "/healthz", {}, "f.test");
  check("r9 /healthz on the alias 301s", "301 https://s.test/healthz", `${r.status} ${r.headers.get("location")}`);
  r = await tget(worker, env, "/ba6377/g/", {}, "x.test");
  check("r9 another Host is 404", 404, r.status);
  check("r9 no alias answer reached the origin", 0, seen.length);
  check("r9 the alias 301 carries no-store and noindex", "no-store|noindex, nofollow", nsni(await tget(worker, env, "/a", {}, "f.test")));
  const np = tenantEnv(new Bucket(), { PASS: "" });
  seen = [];
  r = await tget(worker, np, "/c0ffee/f.txt");
  check("r9 PASS empty: a miss is 404 with no fetch call", "404 0", `${r.status} ${seen.length}`);
  np.BUCKET.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "m", added: "2026-10-01", expires: 0, opts: "", type: "text" }));
  r = await tget(worker, np, `/${MID}/f.txt`);
  check("r9 PASS empty: a machine pointer is 404 with no fetch call", "404 0", `${r.status} ${seen.length}`);
}

// --- row 10: the two-leg /healthz ---
{
  const worker = await loadWorker();
  const env = tenantEnv(new Bucket());
  const hz = async () => { seen = []; const r = await tget(worker, env, "/healthz"); return r; };
  answer = () => frozen(new Response("ok", { status: 200 }));
  let r = await hz();
  check("r10 origin up: 200 ok, X-Share-Tunnel 1, the pair", "200 ok 1 1 abc123def456 1",
    `${r.status} ${await bodyOf(r)} ${r.headers.get("x-share-tunnel")} ${r.headers.get("x-share-worker")} ${r.headers.get("x-share-gate")}`);
  check("r10 the probe fetched HOST's /healthz with a timeout signal", "https://s.test/healthz true", `${(seen[0] || {}).url} ${(seen[0] || {}).signal}`);
  check("r10 no-store and noindex", "no-store|noindex, nofollow", nsni(r));
  answer = () => frozen(new Response("error code: 1033", { status: 530 }));
  r = await hz();
  check("r10 origin 530: 503 tunnel down, X-Share-Tunnel 0, the pair", "503 tunnel down 0 1 abc123def456",
    `${r.status} ${await bodyOf(r)} ${r.headers.get("x-share-tunnel")} ${r.headers.get("x-share-worker")}`);
  answer = (req, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(new Error("aborted"))));
  const t0 = Date.now(), keep = setTimeout(() => {}, 6000);   // node unrefs AbortSignal.timeout's timer; this keeps the loop alive meanwhile
  r = await hz();
  clearTimeout(keep);
  check("r10 origin hangs: 503 X-Share-Tunnel 0 after the 3 s cap", "503 0 true", `${r.status} ${r.headers.get("x-share-tunnel")} ${Date.now() - t0 < 5000}`);
  const np = tenantEnv(new Bucket(), { PASS: "" });
  seen = [];
  r = await tget(worker, np, "/healthz");
  check("r10 PASS empty: SPEC-007's answer, no probe", "200 ok null 0", `${r.status} ${await bodyOf(r)} ${r.headers.get("x-share-tunnel")} ${seen.length}`);
}

// --- Worker v5 (SPEC-009 TASK-0d): member pointers, redeem, named rows ---
// The fake vpc_service binding records every request and answers from a fixture, throws, or hangs until its signal aborts.
const SFX = "aaaaaaa1", ORIG = "m-an-" + SFX, V3ID = "d00001";
const v3rec = (over = {}) => ({ v: 3, id: V3ID, storage: "machine", origin: ORIG, name: "f.txt", by: "an-mac", added: "2026-11-15", expires: 0, opts: "", type: "text", ...over });
const binding = (answer) => ({
  calls: [],
  async fetch(req, init = {}) {   // init.signal: the Worker's 10 s timer, passed as fetch's second argument as TASK-1a(d) sampled it
    this.calls.push({ url: req.url, method: req.method, headers: Object.fromEntries(req.headers), signal: init.signal instanceof AbortSignal && !init.signal.aborted });
    return answer(req, init);
  },
});
const caddy = (body = "member bytes", status = 200, headers = {}) => () => frozen(new Response(body, { status, headers: { "x-share-served": "caddy", "content-type": "text/plain; charset=utf-8", ...headers } }));
const v5env = (bucket, over = {}) => tenantEnv(bucket, { MEMBERS: "1", PAUSED: "[]", DEPLOY: "n0nce", ...over });
const rowOfResp = (worker, resp) => modOf.get(worker).rowOf.get(resp);
const rowIs = (label, worker, resp, row) => check(label + " (row)", row, rowOfResp(worker, resp));
{
  const mod = await loadMod(), worker = mod.default, R = mod.ROW;
  // SV-10: an expired v:2 pointer answers 404 without a pass (NC-3)
  {
    const b = new Bucket(), env = v5env(b);
    b.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "m", added: "2026-10-01", expires: 1000, opts: "", type: "text" }));
    seen = [];
    const r = await tget(worker, env, `/${MID}/f.txt`);
    check("v5 SV-10: an expired v:2 pointer answers 404 without a pass", "404 0", `${r.status} ${seen.length}`);
    rowIs("v5 SV-10", worker, r, R.V2_EXPIRED);
    b.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "m", added: "2026-10-01", expires: Math.floor(Date.now() / 1000) + 600, opts: "", type: "text" }));
    answer = () => frozen(new Response("from origin", { status: 200, headers: { "cf-cache-status": "DYNAMIC", "x-share-served": "caddy" } }));
    seen = [];
    const r2 = await tget(worker, env, `/${MID}/f.txt`);
    check("v5 SV-10: an unexpired v:2 pointer still passes", "200 1", `${r2.status} ${seen.length}`);
    rowIs("v5 SV-10 unexpired", worker, r2, R.PASS_V2);
    check("v5 OT-13: X-Share-Served on an origin pass is removed by the Worker", null, r2.headers.get("x-share-served"));
  }
  // SV-11: a bound, unexpired v:3 reaches the binding as http://HOST/path?q
  {
    const b = new Bucket(), m = binding(caddy("hello an")), env = v5env(b, { ["M_" + SFX]: m });
    b.put("m/" + V3ID, JSON.stringify(v3rec()));
    seen = [];
    const r = await tget(worker, env, `/${V3ID}/f.txt?q=1`);
    check("v5 SV-11: a bound v:3 is served by the member's machine", "200 hello an", `${r.status} ${await bodyOf(r)}`);
    check("v5 SV-11: the binding sees http://HOST/path?q with GET, and no origin pass", `http://s.test/${V3ID}/f.txt?q=1 GET 0`, `${(m.calls[0] || {}).url} ${(m.calls[0] || {}).method} ${seen.length}`);
    check("v5 SV-11: the binding fetch gets the 10 s timer's signal as its second argument", true, (m.calls[0] || {}).signal);
    rowIs("v5 SV-11", worker, r, R.V3_SERVED);
    check("v5 SV-11: no-store, noindex, nosniff, and no hit counted", "no-store|noindex, nofollow nosniff 0",
      `${nsni(r)} ${r.headers.get("x-content-type-options")} ${env.HITS.points.length}`);
    const h = await tget(worker, env, `/${V3ID}/f.txt`, { method: "HEAD" });
    check("v5 SV-11: HEAD reaches the binding as HEAD", "200 HEAD", `${h.status} ${(m.calls[1] || {}).method}`);
  }
  // SV-12 and SV-27: a paused member's link answers 503 with no binding call, whatever the name part says (NC-13)
  for (const [id, label, origin] of [["SV-12", "a paused member's link answers 503", ORIG], ["SV-27", "a forged name with the paused suffix answers 503", "m-zz-" + SFX]]) {
    const b = new Bucket(), m = binding(caddy()), env = v5env(b, { ["M_" + SFX]: m, PAUSED: JSON.stringify([SFX]) });
    b.put("m/" + V3ID, JSON.stringify(v3rec({ origin })));
    const r = await tget(worker, env, `/${V3ID}/f.txt`);
    check(`v5 ${id}: ${label}`, "503 this link is paused by the tenant admin 0 no-store", `${r.status} ${await bodyOf(r)} ${m.calls.length} ${r.headers.get("cache-control")}`);
    rowIs(`v5 ${id}`, worker, r, R.V3_PAUSED);
  }
  {
    const b = new Bucket(), m = binding(caddy()), env = v5env(b, { ["M_" + SFX]: m, PAUSED: "not json" });
    b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const r = await tget(worker, env, `/${V3ID}/f.txt`);
    check("v5 SV-12: a malformed PAUSED pauses (fails closed)", "503 0", `${r.status} ${m.calls.length}`);
  }
  // SV-13: no binding for the suffix is 404; FG-12: a forged origin is 404; SV-20: a POST is 405; V3_EXPIRED
  {
    const b = new Bucket(), m = binding(caddy()), env = v5env(b, { ["M_" + SFX]: m });
    b.put("m/" + V3ID, JSON.stringify(v3rec({ origin: "m-bo-bbbbbbb2" })));
    let r = await tget(worker, env, `/${V3ID}/f.txt`);
    check("v5 SV-13: a v:3 with no binding answers 404", "404 0", `${r.status} ${m.calls.length}`);
    rowIs("v5 SV-13", worker, r, R.V3_UNBOUND);
    env.M_bbbbbbb2 = { notFetch: true };
    r = await tget(worker, env, `/${V3ID}/f.txt`);
    check("v5 SV-13: a binding that is not fetchable answers 404", 404, r.status);
    for (const [label, origin] of [["m-x-../", "m-x-../"], ["a non-hex suffix", "m-an-zzzzzzzz"], ["no m- prefix", "an-" + SFX], ["a name too short", "m-a-" + SFX]]) {
      b.put("m/" + V3ID, JSON.stringify(v3rec({ origin })));
      r = await tget(worker, env, `/${V3ID}/f.txt`);
      check(`v5 FG-12: a forged origin (${label}) answers 404 with no binding call`, "404 0", `${r.status} ${m.calls.length}`);
      rowIs(`v5 FG-12 ${label}`, worker, r, R.BAD_RECORD);
    }
    for (const [label, over] of [["id differs", { id: "d00002" }], ["expires not a number", { expires: "0" }], ["storage not machine", { storage: "cloud" }]]) {
      b.put("m/" + V3ID, JSON.stringify(v3rec(over)));
      r = await tget(worker, env, `/${V3ID}/f.txt`);
      check(`v5 row 10: a v:3 with ${label} answers 404`, "404 0", `${r.status} ${m.calls.length}`);
    }
    b.put("m/" + V3ID, JSON.stringify(v3rec({ expires: 1000 })));
    r = await tget(worker, env, `/${V3ID}/f.txt`);
    check("v5 row 11: an expired v:3 answers 404 with no binding call", "404 0", `${r.status} ${m.calls.length}`);
    rowIs("v5 row 11", worker, r, R.V3_EXPIRED);
    b.put("m/" + V3ID, JSON.stringify(v3rec()));
    r = await tget(worker, env, `/${V3ID}/f.txt`, { method: "POST", body: "x" });
    check("v5 SV-20: a v:3 POST answers 405 with no binding call", "405 0", `${r.status} ${m.calls.length}`);
    rowIs("v5 SV-20", worker, r, R.V3_METHOD);
  }
  // SV-21: no Access credential, cookie, or authorization reaches a binding; Range and the content-negotiation headers do (NC-4)
  {
    const b = new Bucket(), m = binding(caddy("0123", 206, { "content-range": "bytes 0-3/10" })), env = v5env(b, { ["M_" + SFX]: m });
    b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const r = await tget(worker, env, `/${V3ID}/f.txt`, { headers: {
      "cf-access-jwt-assertion": "jwt", "cf-access-authenticated-user-email": "a@x.io", "cf-access-client-secret": "sec", authorization: "Bearer t",
      cookie: "a=1; CF_Authorization=x", range: "bytes=0-3", "if-none-match": "\"e\"", accept: "text/plain", "accept-language": "vi", "user-agent": "ua/1",
      "x-forwarded-for": "1.2.3.4" } });
    const sent = Object.keys((m.calls[0] || {}).headers || {}).sort().join(",");
    check("v5 SV-21: no Access credential reaches a binding", "accept,accept-language,if-none-match,range,user-agent", sent);
    check("v5 SV-21: the member's 206 and its Content-Range pass", "206 bytes 0-3/10 0123", `${r.status} ${r.headers.get("content-range")} ${await bodyOf(r)}`);
  }
  // TASK-3f: a v:3 pointer with the live opt forwards a WebSocket upgrade through the binding and returns the 101 untouched (LK-02)
  {
    const sock = { webSocket: true }, up101 = (extra = {}) => () => ({ status: 101, headers: new Headers({ upgrade: "websocket", connection: "Upgrade", "sec-websocket-accept": "x", "x-share-served": "caddy", ...extra }), body: null, webSocket: sock });
    const wsHeaders = { upgrade: "websocket", connection: "Upgrade", "sec-websocket-key": "k", "sec-websocket-version": "13", "sec-websocket-protocol": "p1",
      cookie: "a=1", authorization: "Bearer t", "cf-access-jwt-assertion": "jwt", "user-agent": "ua/1" };
    const mk = (opts, ans) => { const b = new Bucket(), m = binding(ans), env = v5env(b, { ["M_" + SFX]: m }); b.put("m/" + V3ID, JSON.stringify(v3rec({ opts }))); return { m, env }; };
    let { m, env } = mk("live", up101());
    let r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a live v:3 upgrade answers 101 with the binding's own socket", "101 true", `${r.status} ${r.webSocket === sock}`);
    rowIs("v5 LK-02 upgrade", worker, r, R.V3_SERVED);
    check("v5 LK-02: the binding sees only the handshake headers and the allowlist, GET, on http://HOST/<id>/", `GET http://s.test/${V3ID}/ connection,sec-websocket-key,sec-websocket-protocol,sec-websocket-version,upgrade,user-agent`,
      `${(m.calls[0] || {}).method} ${(m.calls[0] || {}).url} ${Object.keys((m.calls[0] || {}).headers || {}).sort().join(",")}`);
    ({ m, env } = mk("noindex live", up101()));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: live beside noindex still upgrades", 101, r.status);
    ({ m, env } = mk("", caddy("plain page", 200, { "content-type": "text/html" })));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a v:3 without live never forwards the handshake: a plain GET with no Upgrade header", "200 upgrade,connection gone", `${r.status} ${["upgrade", "connection", "sec-websocket-key"].some((h) => h in ((m.calls[0] || {}).headers || {})) ? "upgrade,connection kept" : "upgrade,connection gone"}`);
    ({ m, env } = mk("noindex", up101()));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a v:3 with noindex only is never answered 101, even by a machine that offers one: the 503 offline page", "503 false", `${r.status} ${r.status === 101}`);
    ({ m, env } = mk("live", caddy("app page", 200, { "content-type": "text/html; charset=utf-8", "x-app": "1" })));
    r = await tget(worker, env, `/${V3ID}/app.js`);
    check("v5 LK-02: a live GET keeps the app's own type, with nosniff and the sandbox", "200 text/html; charset=utf-8 nosniff csp", `${r.status} ${r.headers.get("content-type")} ${r.headers.get("x-content-type-options")} ${r.headers.get("content-security-policy") ? "csp" : "none"}`);
    ({ m, env } = mk("live", () => frozen(new Response(new Uint8Array([120]), { status: 200, headers: { "x-share-served": "caddy" } }))));
    r = await tget(worker, env, `/${V3ID}/blob`);
    check("v5 LK-02: a live answer with no type is octet-stream and sandboxed", "application/octet-stream csp", `${r.headers.get("content-type")} ${r.headers.get("content-security-policy") ? "csp" : "none"}`);
    ({ m, env } = mk("live", () => { throw new Error("down"); }));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: an upgrade to a machine that is down answers the 503 offline page", "503 the machine serving this link is offline; try again later", `${r.status} ${await bodyOf(r)}`);
    ({ m, env } = mk("live", up101({ "set-cookie": "x=1; Path=/; Domain=s.test", "strict-transport-security": "max-age=1", "sec-websocket-protocol": "p1", "x-app": "1" })));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: the 101 is a fresh one: only the chosen subprotocol rides along, no Set-Cookie, HSTS or other machine header", "101 p1 null null null", `${r.status} ${r.headers.get("sec-websocket-protocol")} ${r.headers.get("set-cookie")} ${r.headers.get("strict-transport-security")} ${r.headers.get("x-app")}`);
    ({ m, env } = mk("live", () => ({ status: 101, headers: new Headers({ upgrade: "websocket" }), body: null, webSocket: sock })));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a 101 Caddy did not mark (no X-Share-Served) is a machine that is not serving this link: 503", "503", String(r.status));
    ({ m, env } = mk("live", caddy("a", 200, { "content-type": "image/png, text/html" })));
    r = await tget(worker, env, `/${V3ID}/`);
    check("v5 LK-02: a live answer with a list of types is octet-stream and sandboxed (INERT tests only a prefix)", "application/octet-stream csp", `${r.headers.get("content-type")} ${r.headers.get("content-security-policy") ? "csp" : "none"}`);
    ({ m, env } = mk("live", caddy("a", 200, { "content-type": "image/png" })));
    r = await tget(worker, env, `/${V3ID}/`);
    check("v5 LK-02: a live image answer keeps its type and needs no sandbox", "image/png none", `${r.headers.get("content-type")} ${r.headers.get("content-security-policy") ? "csp" : "none"}`);
    ({ m, env } = mk("live", caddy("no upgrade", 400, {})));
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a refused handshake (a 400) passes as the machine's own answer, never a 101", "400", String(r.status));
    ({ m, env } = mk("live", up101()));
    r = await tget(worker, env, `/${V3ID}/`, { method: "POST", body: "x" });
    check("v5 LK-02: a POST to a live row is still 405 with no binding call", "405 0", `${r.status} ${m.calls.length}`);
    ({ m, env } = mk("live", up101()));
    env = v5env(env.BUCKET, { ["M_" + SFX]: m, PAUSED: JSON.stringify([SFX]) });
    r = await tget(worker, env, `/${V3ID}/`, { headers: wsHeaders });
    check("v5 LK-02: a paused member's live row answers 503 with no binding call", "503 0", `${r.status} ${m.calls.length}`);
  }
  // SV-22: an answer without X-Share-Served, a throw, and a hang each read as offline (NC-15)
  {
    const b = new Bucket(); b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const offline = async (label, m) => {
      const env = v5env(b, { ["M_" + SFX]: m });
      const r = await tget(worker, env, `/${V3ID}/f.txt`);
      check(`v5 SV-22: ${label}: the 503 offline page`, "503 60 the machine serving this link is offline; try again later no-store",
        `${r.status} ${r.headers.get("retry-after")} ${await bodyOf(r)} ${r.headers.get("cache-control")}`);
      rowIs(`v5 SV-22 ${label}`, worker, r, R.V3_DOWN);
    };
    await offline("a foreign listener (no X-Share-Served) is never served", binding(() => frozen(new Response("python says hi", { status: 200, headers: { "content-type": "text/html" } }))));
    await offline("a binding that throws", binding(() => { throw new Error("ProxyError: connection_refused"); }));
    // a listener that never answers: the test copy lowers the 10 s timer to 50 ms; the abort reads as offline
    const fast = join(tmp, "worker-fast.mjs");
    writeFileSync(fast, src.replace("const V3_WAIT_MS = 10000;", "const V3_WAIT_MS = 50;") + TEST_EXPORTS);
    const fm = await loadMod(fast), env = v5env(b, { ["M_" + SFX]: binding((req, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(new Error("aborted"))))) });
    const t0 = Date.now(), keep = setTimeout(() => {}, 3000);
    const r = await tget(fm.default, env, `/${V3ID}/f.txt`);
    clearTimeout(keep);
    check("v5 SV-22: a listener that never answers is offline once the timer fires", "503 true", `${r.status} ${Date.now() - t0 < 2000}`);
    check("v5 SV-22: the source's own timer is 10 s", true, src.includes("const V3_WAIT_MS = 10000;"));
  }
  // SV-23: the type comes from the path, nosniff always, the sandbox on every non-inert answer, cookies and off-path redirects dropped
  {
    const b = new Bucket(); b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const via = async (path, ans) => {
      const env = v5env(b, { ["M_" + SFX]: binding(ans) });
      return tget(worker, env, `/${V3ID}/${path}`);
    };
    const csp = (r) => r.headers.get("content-security-policy") === "sandbox allow-scripts allow-forms allow-popups allow-downloads" ? "csp" : "none";
    const cases = [
      ["page.html", "text/html", "text/html", "csp"],
      ["page.html", "text/html; charset=utf-8", "text/html", "csp"],
      ["doc.pdf", "application/pdf", "application/pdf", "none"],
      ["x.xhtml", "application/xhtml+xml", "application/octet-stream", "csp"],
      ["x.xml", "text/xml", "application/xml", "csp"],
      ["noext", "text/html", "application/octet-stream", "csp"],
      ["img.png", "image/png", "image/png", "none"],
      ["pic.svg", "image/svg+xml", "image/svg+xml", "csp"],
      ["notes.txt", "text/plain; charset=utf-8", "text/plain", "none"],
      ["notype.png", "", "image/png", "csp"],
    ];
    for (const [path, said, want, sb] of cases) {
      // bytes, not a string: a string body would get a default text/plain type from Response itself
      const r = await via(path, () => frozen(new Response(new Uint8Array([120]), { status: 200, headers: said ? { "x-share-served": "caddy", "content-type": said } : { "x-share-served": "caddy" } })));
      check(`v5 SV-23: ${path} answered '${said || "no type"}': type, nosniff, sandbox`, `${want} nosniff ${sb}`, `${r.headers.get("content-type")} ${r.headers.get("x-content-type-options")} ${csp(r)}`);
    }
    let r = await via("f.txt", caddy("x", 200, { "set-cookie": "s=1", "clear-site-data": "\"*\"", refresh: "0;url=https://evil.example/",
      "www-authenticate": "Basic realm=x", "strict-transport-security": "max-age=1; includeSubDomains", link: "<https://evil.example/>; rel=preload", etag: "\"e1\"" }));
    check("v5 SV-23: Set-Cookie, Clear-Site-Data, Refresh and X-Share-Served dropped", "null null null null",
      `${r.headers.get("set-cookie")} ${r.headers.get("clear-site-data")} ${r.headers.get("refresh")} ${r.headers.get("x-share-served")}`);
    check("v5 SV-23: an auth prompt, HSTS and Link dropped; ETag kept", "null null null \"e1\"",
      `${r.headers.get("www-authenticate")} ${r.headers.get("strict-transport-security")} ${r.headers.get("link")} ${r.headers.get("etag")}`);
    r = await via("go", caddy("", 302, { location: "https://evil.example/" }));
    check("v5 SV-23: a 302 to another host answers 502", "502 null", `${r.status} ${r.headers.get("location")}`);
    rowIs("v5 SV-23 off-path redirect", worker, r, R.V3_SERVED);
    for (const loc of ["//evil.example/x", `/ffffff/`, "../../x", "javascript:alert(1)", "/\\evil.example"]) {
      r = await via("a/b", caddy("", 302, { location: loc }));
      check(`v5 SV-23: a redirect to '${loc}' answers 502`, 502, r.status);
    }
    r = await via("f.txt", caddy("x", 200, { location: "https://evil.example/" }));
    check("v5 SV-23: a Location on a 200 is dropped (only a checked 3xx keeps one)", "200 null", `${r.status} ${r.headers.get("location")}`);
    for (const loc of ["sub/", `/${V3ID}/sub/`, "./c"]) {
      r = await via("a/b", caddy("", 302, { location: loc }));
      check(`v5 SV-23: a redirect to '${loc}' stays under /<id>/ and passes`, `302 ${loc}`, `${r.status} ${r.headers.get("location")}`);
    }
    // a cloud .html on a MEMBERS=1 tenant carries the sandbox too; without MEMBERS the cloud path is unchanged
    const cb = new Bucket(); putRec(cb); cb.put(`o/${ID}.${NONCE}/p.html`, "<p>x</p>"); cb.put(`o/${ID}.${NONCE}/p.pdf`, "%PDF");
    r = await tget(worker, v5env(cb), `/${ID}/p.html`);
    check("v5 SV-23: a cloud .html on a MEMBERS=1 tenant carries the sandbox and nosniff", "200 csp nosniff", `${r.status} ${csp(r)} ${r.headers.get("x-content-type-options")}`);
    rowIs("v5 SV-23 cloud", worker, r, R.CLOUD_OBJECT);
    r = await tget(worker, v5env(cb), `/${ID}/p.pdf`);
    check("v5 SV-23: a cloud .pdf on a MEMBERS=1 tenant is untouched", "200 none", `${r.status} ${csp(r)}`);
    r = await tget(worker, tenantEnv(cb), `/${ID}/p.html`);
    check("v5 SV-23: a cloud .html without MEMBERS is unchanged", "200 none null", `${r.status} ${csp(r)} ${r.headers.get("x-content-type-options")}`);
  }
  // SV-28: a folder link: Caddy's 308 to /<id>/ passes with its Location, and the listing is text/html with the sandbox
  {
    const b = new Bucket(); b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const m = binding((req) => new URL(req.url).pathname === `/${V3ID}`
      ? frozen(new Response(null, { status: 308, headers: { "x-share-served": "caddy", location: `/${V3ID}/` } }))
      : frozen(new Response("<ul></ul>", { status: 200, headers: { "x-share-served": "caddy", "content-type": "application/octet-stream" } })));
    const env = v5env(b, { ["M_" + SFX]: m });
    let r = await tget(worker, env, `/${V3ID}`);
    check("v5 SV-28: /<id> answered 308 to /<id>/ passes with its Location", `308 /${V3ID}/`, `${r.status} ${r.headers.get("location")}`);
    r = await tget(worker, env, `/${V3ID}/`);
    check("v5 SV-28: the folder listing is text/html with the sandbox", "200 text/html sandbox allow-scripts allow-forms allow-popups allow-downloads",
      `${r.status} ${r.headers.get("content-type")} ${r.headers.get("content-security-policy")}`);
  }
  // SV-24: BUCKET.get per request: v:1 2, v:2 1, v:3 1
  {
    const b = new Bucket(); putRec(b); b.put(`o/${ID}.${NONCE}/f.txt`, "x");
    b.put("m/" + MID, JSON.stringify({ v: 2, id: MID, storage: "machine", name: "f.txt", by: "m", added: "2026-10-01", expires: 0, opts: "", type: "text" }));
    b.put("m/" + V3ID, JSON.stringify(v3rec()));
    const env = v5env(b, { ["M_" + SFX]: binding(caddy()) });
    answer = () => frozen(new Response("o", { status: 200, headers: { "cf-cache-status": "DYNAMIC" } }));
    const counts = [];
    for (const p of [`/${ID}/f.txt`, `/${MID}/f.txt`, `/${V3ID}/f.txt`]) { b.gets = 0; await tget(worker, env, p); counts.push(b.gets); }
    check("v5 SV-24: BUCKET.get per request for v:1, v:2, v:3", "2 1 1", counts.join(" "));
  }
  // OT-07: a failed m/ read passes to the origin (a member id 404s there); OC-05: Worker v4 answers 404 for a v:3
  {
    const thrower = new Bucket(); thrower.get = async () => { throw new Error("R2 down"); };
    answer = () => frozen(new Response("origin 404", { status: 404, headers: { "cf-cache-status": "DYNAMIC" } }));
    seen = [];
    const r = await tget(worker, v5env(thrower, { ["M_" + SFX]: binding(caddy()) }), `/${V3ID}/f.txt`);
    check("v5 OT-07: a failed bucket read passes to the origin, which answers its own 404", "404 1 origin 404", `${r.status} ${seen.length} ${await bodyOf(r)}`);
    rowIs("v5 OT-07", worker, r, R.PASS_MISS);
    let v4 = "";
    try { v4 = execFileSync("git", ["-C", repo, "show", "f28cb13:bin/share"], { encoding: "utf8" }); } catch { v4 = ""; }
    if (v4) {
      const v4src = v4.split("\n").reduce((a, l) => { if (/^  cat >"\$1" <<.SHARE_WORKER_JS.$/.test(l)) a.on = true; else if (l === "SHARE_WORKER_JS") a.on = false; else if (a.on) a.out.push(l); return a; }, { on: false, out: [] }).out.join("\n") + "\n";
      const v4file = join(tmp, "worker-v4.mjs"); writeFileSync(v4file, v4src);
      const w4 = (await import("file://" + v4file + "?m=" + ++modn)).default;
      const b = new Bucket(); b.put("m/" + V3ID, JSON.stringify(v3rec()));
      seen = [];
      const r4 = await call(w4, v5env(b, { ["M_" + SFX]: binding(caddy()) }), `https://s.test/${V3ID}/f.txt`);
      check("v5 OC-05: Worker v4 answers 404 for a v:3 pointer and never passes it", "404 0", `${r4.status} ${seen.length}`);
    } else if (process.env.CI === "true") check("v5 OC-05: commit f28cb13 (Worker v4) fetched", "yes", "missing");
    else console.log("  SKIP  commit f28cb13 not fetched; OC-05 skipped");
  }
  // rows 3 and 3b: the redeem route against the R2 fake that honors onlyIf.etagMatches
  {
    const H = "a".repeat(64), now = Math.floor(Date.now() / 1000);
    const env0 = (b) => v5env(b);
    const envl = (over = {}) => JSON.stringify({ v: 1, member_id: ORIG, expires: now + 3600, sealed: "c2VhbGVk", mac: "b".repeat(64), ...over });
    const post = (worker, env, body = H, opts = {}) => tget(worker, env, "/_share/redeem", { method: "POST", body, ...opts });
    let b = new Bucket(); b.put("i/" + H, envl());
    let r = await post(worker, env0(b));
    check("v5 SV-14: a fresh redeem answers 200 with the envelope, no-store", `200 ${envl()} no-store`, `${r.status} ${await bodyOf(r)} ${r.headers.get("cache-control")}`);
    check("v5 SV-14: the object is gone", false, b.m.has("i/" + H));
    rowIs("v5 SV-14", worker, r, R.REDEEM_OK);
    r = await post(worker, env0(b));
    check("v5 SV-15: a second redeem answers 404", 404, r.status);
    rowIs("v5 SV-15", worker, r, R.REDEEM_UNKNOWN);
    // two redeems racing on one object: both read it, only the first claim lands
    b = new Bucket(); b.put("i/" + H, envl());
    const realGet = b.get.bind(b); let gate, held = 0;
    const both = new Promise((res) => { gate = res; });
    b.get = async (k, o) => { const v = await realGet(k, o); if (k === "i/" + H && ++held === 2) gate(); else if (k === "i/" + H) await both; return v; };
    const [ra, rb] = await Promise.all([post(worker, env0(b)), post(worker, env0(b))]);
    check("v5 SV-15: two concurrent redeems of one object: exactly one 200", "200,404", [ra.status, rb.status].sort().join(","));
    b = new Bucket(); b.put("i/" + H, envl({ expires: now - 5 }));
    r = await post(worker, env0(b));
    check("v5 SV-16: an expired invite answers 410 and the object is gone", "410 false", `${r.status} ${b.m.has("i/" + H)}`);
    rowIs("v5 SV-16", worker, r, R.REDEEM_EXPIRED);
    b = new Bucket(); b.put("i/" + H, envl()); b.put = () => null;   // the claim put loses (another redeem changed the etag)
    r = await post(worker, env0(b));
    check("v5 SV-17: a claim put answering null is 404 and the object stays", "404 true", `${r.status} ${b.m.has("i/" + H)}`);
    b = new Bucket(); b.put("i/" + H, envl()); b.delete = async () => { throw new Error("R2 delete failed"); };
    r = await post(worker, env0(b));
    const left = b.m.has("i/" + H) ? JSON.parse(new TextDecoder().decode(b.m.get("i/" + H).bytes)) : {};
    check("v5 SV-18: a delete that throws answers 503, never the envelope", "503 false", `${r.status} ${(await bodyOf(r)).includes("c2VhbGVk")}`);
    check("v5 SV-18: the object stays claimed: no sealed bytes, expires kept", `undefined ${now + 3600} true`, `${left.sealed} ${left.expires} ${typeof left.claimed === "number"}`);
    rowIs("v5 SV-18", worker, r, R.REDEEM_UNAVAILABLE);
    r = await post(worker, env0(b));
    check("v5 SV-18: a redeem of the claimed object answers 404", 404, r.status);
    b = new Bucket(); b.put("i/" + H, envl());
    r = await tget(worker, env0(b), "/_share/redeem");
    check("v5 SV-19: GET /_share/redeem answers 405", 405, r.status);
    rowIs("v5 SV-19 GET", worker, r, R.REDEEM_METHOD);
    for (const [label, body] of [["63 hex", "a".repeat(63)], ["uppercase", "A".repeat(64)], ["a trailing newline", H + "\n"], ["not hex", "z".repeat(64)], ["empty", ""]]) {
      r = await post(worker, env0(b), body);
      check(`v5 SV-19: a body of ${label} answers 400`, 400, r.status);
    }
    rowIs("v5 SV-19 body", worker, r, R.REDEEM_BAD_BODY);
    r = await post(worker, env0(b), H + " ".repeat(200));
    check("v5 SV-19: a body declared over 128 bytes answers 400 unread", 400, r.status);
    for (const p of ["/_share/x", "/_share/", "/_share", "/_share/redeem/x"]) {
      seen = [];
      r = await tget(worker, env0(b), p);
      check(`v5 SV-19: ${p} answers 404 with no pass`, "404 0", `${r.status} ${seen.length}`);
      rowIs(`v5 SV-19 ${p}`, worker, r, R.SHARE_PATH_UNKNOWN);
    }
    check("v5 SV-19: nothing above touched the object", true, b.m.has("i/" + H));
    for (const [label, over] of [["more than 30 days ahead", { expires: now + 31 * 86400 }], ["a bad member_id", { member_id: "m-x-../aaaaaaa1" }],
      ["no sealed bytes", { sealed: "" }], ["a short mac", { mac: "b".repeat(10) }], ["v:2", { v: 2 }]]) {
      b = new Bucket(); b.put("i/" + H, envl(over));
      r = await post(worker, env0(b));
      check(`v5 row 3: an envelope with ${label} answers 404 and stays`, "404 true", `${r.status} ${b.m.has("i/" + H)}`);
    }
    b = new Bucket(); b.put("i/" + H, "{not json");
    r = await post(worker, env0(b));
    check("v5 row 3: an envelope that is not JSON answers 404", 404, r.status);
    // OT-18: a scanner's random hashes: 404 each, one R2 read each
    b = new Bucket(); b.put("i/" + H, envl());
    for (let i = 0; i < 5; i++) {
      const h = createHash("sha256").update("scan" + i).digest("hex");
      b.gets = 0; r = await post(worker, env0(b), h);
      check(`v5 OT-18: random hash ${i}: 404 with one R2 read`, "404 1", `${r.status} ${b.gets}`);
    }
    b = new Bucket(); b.get = async () => { throw new Error("R2 down"); };
    r = await post(worker, env0(b));
    check("v5 row 3: a failed i/ read answers 503", 503, r.status);
  }
  // row 5: /healthz echoes the deploy nonce
  {
    answer = () => frozen(new Response("ok", { status: 200 }));
    let r = await tget(worker, v5env(new Bucket()), "/healthz");
    check("v5 row 5: /healthz carries X-Share-Deploy", "200 n0nce", `${r.status} ${r.headers.get("x-share-deploy")}`);
    answer = () => frozen(new Response("x", { status: 530 }));
    r = await tget(worker, v5env(new Bucket()), "/healthz");
    check("v5 row 5: the tunnel-down 503 carries it too", "503 n0nce", `${r.status} ${r.headers.get("x-share-deploy")}`);
    r = await tget(worker, tenantEnv(new Bucket()), "/healthz");
    check("v5 row 5: no DEPLOY binding, no header", null, r.headers.get("x-share-deploy"));
  }
  // SV-26: decide() is pure and names its row; the table below drives it with no I/O
  {
    const req = (p, m = "GET") => new Request("https://s.test" + p, { method: m });
    const env = v5env(new Bucket(), { ["M_" + SFX]: binding(caddy()), PAUSED: JSON.stringify(["bbbbbbb2"]) });
    const rows = [
      [mod.MISS, "PASS_MISS pass"], [mod.BAD_JSON, "BAD_JSON 404"], [null, "BAD_RECORD 404"], [7, "BAD_RECORD 404"],
      [{ v: 2, storage: "machine", expires: 0 }, "PASS_V2 pass"], [{ v: 2, storage: "machine", expires: 5 }, "V2_EXPIRED 404"],
      [v3rec(), "V3_SERVED bind"], [v3rec({ expires: 5 }), "V3_EXPIRED 404"], [v3rec({ origin: "m-bo-bbbbbbb2" }), "V3_PAUSED 503"],
      [v3rec({ origin: "m-cy-ccccccc3" }), "V3_UNBOUND 404"], [v3rec({ origin: "m-../" }), "BAD_RECORD 404"],
      [rec({ id: V3ID, prefix: `o/${V3ID}.${NONCE}/` }), "CLOUD_OBJECT serve"], [rec({ id: V3ID, prefix: `o/${V3ID}.${NONCE}/`, expires: 5 }), "BAD_RECORD 404"],
    ];
    for (const [r, want] of rows) {
      const d = mod.decide(req(`/${V3ID}/f.txt`), env, r, 1000);
      check(`v5 SV-26: decide(${typeof r === "symbol" ? String(r) : JSON.stringify(r)?.slice(0, 40)})`, want, `${d.row} ${d.status}`);
    }
    check("v5 SV-26: decide on a v:3 POST", "V3_METHOD 405", (({ row, status }) => `${row} ${status}`)(mod.decide(req(`/${V3ID}/f.txt`, "POST"), env, v3rec(), 1000)));
    check("v5 SV-26: decide without PASS: a miss and a v:2 answer 404", "PASS_MISS 404|PASS_V2 404",
      `${mod.decide(req(`/${V3ID}/f`), { HOST: "s.test" }, mod.MISS).row} ${mod.decide(req(`/${V3ID}/f`), { HOST: "s.test" }, mod.MISS).status}|` +
      `${mod.decide(req(`/${V3ID}/f`), { HOST: "s.test" }, { v: 2, storage: "machine" }).row} ${mod.decide(req(`/${V3ID}/f`), { HOST: "s.test" }, { v: 2, storage: "machine" }).status}`);
    const routes = [
      [["https://f.test/x", "GET"], { ALIASES: "f.test" }, "ALIAS_301 301"], [["https://f.test/x", "POST"], { ALIASES: "f.test" }, "ALIAS_301 405"],
      [["https://x.test/x", "GET"], {}, "WRONG_HOST 404"], [["https://s.test/_share/redeem", "GET"], {}, "REDEEM_METHOD 405"],
      [["https://s.test/_share/q", "GET"], {}, "SHARE_PATH_UNKNOWN 404"], [["https://s.test/a%2fb", "GET"], {}, "BAD_PATH 400"],
      [["https://s.test/abc123/f", "POST"], { PASS: "" }, "BAD_PATH 405"], [["https://s.test/healthz", "GET"], {}, "HEALTHZ 200"],
      [["https://s.test/healthz", "POST"], {}, "HEALTHZ 405"], [["https://s.test/assets/a.js", "GET"], {}, "PASS_NON_ID pass"],
      [["https://s.test/assets/a.js", "GET"], { PASS: "" }, "PASS_NON_ID 404"],
    ];
    for (const [[u, m], over, want] of routes) {
      const d = mod.route(new Request(u, { method: m }), { ...v5env(new Bucket()), ...over });
      check(`v5 SV-26: route(${m} ${u})`, want, `${d.row} ${d.status}`);
    }
    const rd = mod.route(new Request("https://s.test/abc123/f"), v5env(new Bucket()));
    check("v5 SV-26: route of a link names its one read", "m/abc123 abc123", `${rd.read} ${rd.id}`);
    check("v5 SV-26: settleV3 of a throw, a foreign answer, a Caddy answer", "V3_DOWN 503|V3_DOWN 503|V3_SERVED 206",
      [mod.settleV3(null, V3ID, "/x"), mod.settleV3(new Response("x"), V3ID, "/x"), mod.settleV3(new Response("x", { status: 206, headers: { "x-share-served": "caddy" } }), V3ID, "/x")]
        .map((d) => `${d.row} ${d.status}`).join("|"));
  }
}
// SV-26: every answer of every row above, old and new: a named row, the one 404 body, and no header that names the row
{
  const names = answers.length ? Object.values(answers[0].ROW) : [];
  const unnamed = answers.filter((a) => !names.includes(a.row));
  check(`v5 SV-26: every one of ${answers.length} answers carries a named row`, "0", `${unnamed.length}${unnamed.length ? " e.g. status " + unnamed[0].status : ""}`);
  const passRows = ["PASS_MISS", "PASS_V2", "PASS_NON_ID"];
  const odd404 = answers.filter((a) => a.status === 404 && !passRows.includes(a.row) && a.body404 !== a.NF);
  check("v5 SV-26: every Worker 404 answers the one body", "0", `${odd404.length}${odd404.length ? " e.g. " + odd404[0].row + " '" + odd404[0].body404 + "'" : ""}`);
  const leak = answers.filter((a) => a.headers.some(([k, v]) => names.includes(v) || /row/i.test(k)));
  check("v5 SV-26: no response header names the row", "0", String(leak.length));
  check("v5 SV-26: the 404 body is the spec's", "no such link (it may have expired or been removed)", answers.length ? answers[0].NF : "");
}

console.log(fails ? `${fails} FAILED` : "PASS");
process.exit(fails ? 1 : 0);
