import { test } from "node:test";
import assert from "node:assert/strict";
import { computeCvss, parseVector, severityFromScore } from "./cvss";
import { runCtfOp } from "./ctfTools";
import { scanSecrets } from "./secretsScanner";
import { generateThreatModel } from "./threatModel";
import { reviewCode } from "./codeReview";

test("CVSS: known critical vector scores 9.8", () => {
  const v = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H";
  const m = parseVector(v)!;
  const r = computeCvss(m);
  assert.equal(r.baseScore, 9.8);
  assert.equal(r.severity, "critical");
});

test("CVSS: no-impact vector scores 0", () => {
  const r = computeCvss(parseVector("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N")!);
  assert.equal(r.baseScore, 0);
});

test("CVSS severity bands", () => {
  assert.equal(severityFromScore(3.9), "low");
  assert.equal(severityFromScore(6.9), "medium");
  assert.equal(severityFromScore(8.9), "high");
  assert.equal(severityFromScore(9.0), "critical");
});

test("CTF base64 round-trip", () => {
  const enc = runCtfOp("base64-encode", "hello horus");
  assert.equal(enc.ok, true);
  const dec = runCtfOp("base64-decode", enc.output);
  assert.equal(dec.output, "hello horus");
});

test("CTF rot13 is its own inverse", () => {
  const once = runCtfOp("rot13", "Attack at dawn").output;
  const twice = runCtfOp("rot13", once).output;
  assert.equal(twice, "Attack at dawn");
});

test("CTF hash identify recognizes SHA-256 length", () => {
  const r = runCtfOp("hash-identify", "a".repeat(64));
  assert.match(r.output, /SHA-256/);
});

test("CTF jwt decode reads payload", () => {
  // header {"alg":"none"} . payload {"sub":"1","admin":true} . sig
  const header = Buffer.from('{"alg":"none"}').toString("base64url");
  const payload = Buffer.from('{"sub":"1","admin":true}').toString("base64url");
  const r = runCtfOp("jwt-decode", `${header}.${payload}.x`);
  assert.match(r.output, /"admin": true/);
});

test("secrets scanner flags an AWS access key id", () => {
  const code = `const k = "${"AKIA" + "ABCDEFGHIJKLMNOP"}";`;
  const f = scanSecrets(code);
  assert.ok(f.some((x) => /AWS Access Key/.test(x.title)));
});

test("secrets scanner flags a private key block", () => {
  const f = scanSecrets("-----BEGIN RSA PRIVATE KEY-----");
  assert.ok(f.some((x) => /Private key/.test(x.title)));
});

test("threat model produces STRIDE threats with mitigations", () => {
  const tm = generateThreatModel({
    system: "Web app with login, API and database",
    components: ["api", "database", "auth"],
  });
  assert.ok(tm.threats.length > 0);
  assert.ok(tm.threats.every((t) => t.mitigation.length > 0));
  assert.ok(tm.threats.some((t) => t.category === "Elevation of Privilege"));
});

test("code review tags compliance (CWE/OWASP) on SQLi", () => {
  const r = reviewCode('const q = "SELECT * FROM t WHERE id=" + id;');
  const sqli = r.findings.find((f) => /sql injection/i.test(f.title));
  assert.ok(sqli);
  assert.equal(sqli!.cwe, "CWE-89");
});

test("code review detects Python pickle and flask debug", () => {
  const r = reviewCode("data = pickle.loads(x)\napp.run(debug=True)");
  assert.ok(r.findings.some((f) => /pickle/i.test(f.title)));
  assert.ok(r.findings.some((f) => /debug/i.test(f.title)));
});
