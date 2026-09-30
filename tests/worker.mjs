// tests/worker.mjs: unit-drive the share Worker emitted from bin/share against
// in-memory bindings. Prints ok/FAIL lines like tests/share.sh; exit 1 on any FAIL.
// Rows covered: 17 (serving shapes), 18 (path/record/Host refusals), 19 (hits),
// 28 (the gated-record JWT check), plus the WORKER_SHA/WORKER_VERSION self-checks
// and `node --check` on the emitted source.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
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
    const m = rh && rh.match(/^bytes=(\d+)-(\d*)$/);
    if (m) {
      const a = +m[1], b = m[2] ? +m[2] + 1 : e.bytes.length;
      bytes = e.bytes.slice(a, Math.min(b, e.bytes.length));
      range = { offset: a, length: bytes.length };
    }
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
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { method: "HEAD" });
  check("r17 HEAD status", 200, r.status);
  check("r17 HEAD empty body", "", await bodyOf(r));
  r = await call(worker, env, `https://f.test/${ID}/f.txt`, { headers: { range: "bytes=0-3" } });
  check("r17 Range 206", 206, r.status);
  check("r17 Range body", "0123", await bodyOf(r));
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
  check("r18 /%61bc123/f 404", 404, await st(`${host}/%61bc123/f.txt`));
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
  check("r28 normalized backtrack path, no header", 404, await gated(worker, env, {}, `/x/..\\${ID}/f.txt`));
  check("r28 malformed token", 404, await gated(worker, env, { "cf-access-jwt-assertion": "not-a-jwt" }));
  const none = await signJwt(pair.privateKey, { alg: "none" }, jwtFor(AUD));
  check("r28 alg none", 404, await gated(worker, env, { "cf-access-jwt-assertion": none }));
  const hs = await signJwt(pair.privateKey, { alg: "HS256" }, jwtFor(AUD));
  check("r28 alg HS256", 404, await gated(worker, env, { "cf-access-jwt-assertion": hs }));
  check("r28 empty aud", 404, await gated(worker, env, await good({ aud: "" })));
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

console.log(fails ? `${fails} FAILED` : "PASS");
process.exit(fails ? 1 : 0);
