// tests/worker.mjs: unit-drive the share Worker emitted from bin/share against
// in-memory bindings. Prints ok/FAIL lines like tests/share.sh; exit 1 on any FAIL.
// Rows covered: 17 (serving shapes), 18 (path/record/Host refusals), 19 (hits),
// 28 (the gated-record JWT check), the tenant rows 7 to 10 (PASS, ALIASES, the pass-through, the two-leg
// /healthz, against a stubbed origin fetch whose answers hold immutable headers), plus the WORKER_SHA/WORKER_VERSION self-checks
// and `node --check` on the emitted source.
// Integration mode, `node tests/worker.mjs --dir <dry bucket> --host <host> <path>...`:
// the same Worker over a BUCKET loaded from a SHARE_R2_DRY_DIR, one "<code> <path>" line per path.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const sharePath = join(repo, "bin/share");
let fails = 0;
const check = (label, want, got) => {
  const ok = want instanceof RegExp ? want.test(String(got)) : want === got;
  if (ok) console.log("  ok    " + label);
  else { console.log(`  FAIL  ${label}: expected '${want}', got '${got}'`); fails++; }
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
try { execFileSync(process.execPath, ["--check", srcFile]); check("node --check on the emitted Worker", 0, 0); }
catch (e) { check("node --check on the emitted Worker", 0, 1); }

// --- fakes ---
const enc = (s) => new TextEncoder().encode(s);
const bodyOf = async (resp) => new TextDecoder().decode(await resp.arrayBuffer());
class Bucket {
  constructor() { this.m = new Map(); }
  put(key, data, meta = {}) {
    const bytes = typeof data === "string" ? enc(data) : data;
    this.m.set(key, { bytes, etag: createHash("md5").update(bytes).digest("hex"), meta, last: Date.now() });
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
  return resp;
};
let modn = 0;
const loadWorker = async () => (await import("file://" + srcFile + "?m=" + ++modn)).default;

const ID = "a1b2c3", NONCE = "f00dcafe";
const rec = (over = {}) => ({ v: 1, id: ID, name: "f.txt", src: "/tmp/x", added: "2026-01-01", expires: 0, opts: "", prefix: `o/${ID}.${NONCE}/`, by: "mini", ...over });
const putRec = (b, over = {}) => b.put("m/" + ID, JSON.stringify(rec(over)));

if (process.argv[2] === "--dir") {
  const dir = process.argv[3], host = process.argv[5], bucket = new Bucket();
  const walk = (d) => readdirSync(d, { withFileTypes: true }).forEach((e) => {
    if (e.name.startsWith(".")) return;   // the dry seam's .cf, .fx, and .resume are not objects
    const f = join(d, e.name);
    if (e.isDirectory()) walk(f); else bucket.put(relative(dir, f), readFileSync(f));
  });
  walk(dir);
  const worker = await loadWorker(), env = envOf(bucket, { HOST: host });
  for (const path of process.argv.slice(6)) console.log(`${(await call(worker, env, "https://" + host + path)).status} ${path}`);
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
  const offline = async (label, resp) => {
    check(`r8 ${label}: the 503 offline page`, "503 60 the machine serving this link is offline; try again later",
      `${resp.status} ${resp.headers.get("retry-after")} ${await bodyOf(resp)}`);
    check(`r8 ${label}: no-store and noindex`, "no-store|noindex, nofollow", nsni(resp));
  };
  await offline("530", await via(530, {}, "error code: 1033"));
  await offline("502", await via(502, { server: "cloudflare" }, "<title>502</title>"));
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

console.log(fails ? `${fails} FAILED` : "PASS");
process.exit(fails ? 1 : 0);
