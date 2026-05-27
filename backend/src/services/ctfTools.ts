/**
 * ctfTools.ts — safe, local CTF/forensics utilities (a mini "CyberChef").
 * Pure data transforms and decoders. No network, no cracking of others'
 * credentials — only encode/decode/analyze helpers for learning and CTFs.
 */

export type CtfOp =
  | "base64-encode"
  | "base64-decode"
  | "hex-encode"
  | "hex-decode"
  | "url-encode"
  | "url-decode"
  | "rot13"
  | "binary-decode"
  | "reverse"
  | "caesar"
  | "vigenere-decode"
  | "hash-identify"
  | "jwt-decode";

export interface CtfResult {
  op: CtfOp;
  ok: boolean;
  output: string;
  note?: string;
}

function rot13(s: string): string {
  return s.replace(/[a-z]/gi, (c) => {
    const base = c <= "Z" ? 65 : 97;
    return String.fromCharCode(((c.charCodeAt(0) - base + 13) % 26) + base);
  });
}

function caesar(s: string, shift: number): string {
  const k = ((shift % 26) + 26) % 26;
  return s.replace(/[a-z]/gi, (c) => {
    const base = c <= "Z" ? 65 : 97;
    return String.fromCharCode(((c.charCodeAt(0) - base + k) % 26) + base);
  });
}

function vigenereDecode(s: string, key: string): string {
  if (!key) return s;
  const k = key.toLowerCase().replace(/[^a-z]/g, "");
  if (!k) return s;
  let ki = 0;
  return s.replace(/[a-z]/gi, (c) => {
    const base = c <= "Z" ? 65 : 97;
    const shift = k.charCodeAt(ki % k.length) - 97;
    ki++;
    return String.fromCharCode(((c.charCodeAt(0) - base - shift + 26) % 26) + base);
  });
}

function identifyHash(s: string): string {
  const h = s.trim();
  const checks: [RegExp, string][] = [
    [/^[a-f0-9]{32}$/i, "MD5 or NTLM (32 hex)"],
    [/^[a-f0-9]{40}$/i, "SHA-1 (40 hex)"],
    [/^[a-f0-9]{56}$/i, "SHA-224 (56 hex)"],
    [/^[a-f0-9]{64}$/i, "SHA-256 (64 hex)"],
    [/^[a-f0-9]{96}$/i, "SHA-384 (96 hex)"],
    [/^[a-f0-9]{128}$/i, "SHA-512 (128 hex)"],
    [/^\$2[aby]\$\d{2}\$/, "bcrypt"],
    [/^\$argon2(id|i|d)\$/, "Argon2"],
    [/^\$6\$/, "sha512crypt ($6$)"],
    [/^\$1\$/, "md5crypt ($1$)"],
    [/^[A-Za-z0-9+/]{20,}={0,2}$/, "Possibly Base64-encoded data"],
  ];
  const matches = checks.filter(([re]) => re.test(h)).map(([, name]) => name);
  return matches.length ? matches.join(" | ") : "Unrecognized format";
}

function jwtDecode(token: string): string {
  const parts = token.trim().split(".");
  if (parts.length < 2) return "Not a JWT (expected header.payload.signature).";
  const b64 = (s: string) =>
    Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
  try {
    const header = JSON.parse(b64(parts[0]));
    const payload = JSON.parse(b64(parts[1]));
    return `HEADER:\n${JSON.stringify(header, null, 2)}\n\nPAYLOAD:\n${JSON.stringify(
      payload,
      null,
      2
    )}\n\n(Signature not verified — decoding only. Never trust an unverified JWT.)`;
  } catch {
    return "Could not decode JWT segments as JSON.";
  }
}

export function runCtfOp(op: CtfOp, input: string, param?: string): CtfResult {
  try {
    let output = "";
    let note: string | undefined;
    switch (op) {
      case "base64-encode":
        output = Buffer.from(input, "utf8").toString("base64");
        break;
      case "base64-decode":
        output = Buffer.from(input.trim(), "base64").toString("utf8");
        break;
      case "hex-encode":
        output = Buffer.from(input, "utf8").toString("hex");
        break;
      case "hex-decode":
        output = Buffer.from(input.replace(/\s+/g, ""), "hex").toString("utf8");
        break;
      case "url-encode":
        output = encodeURIComponent(input);
        break;
      case "url-decode":
        output = decodeURIComponent(input);
        break;
      case "rot13":
        output = rot13(input);
        break;
      case "reverse":
        output = [...input].reverse().join("");
        break;
      case "binary-decode":
        output = input
          .trim()
          .split(/\s+/)
          .map((b) => String.fromCharCode(parseInt(b, 2)))
          .join("");
        break;
      case "caesar":
        output = caesar(input, Number(param ?? 3));
        note = `Shift ${Number(param ?? 3)}. Try all 25 shifts if unknown.`;
        break;
      case "vigenere-decode":
        output = vigenereDecode(input, param ?? "");
        note = param ? `Key: ${param}` : "Provide a key in the parameter field.";
        break;
      case "hash-identify":
        output = identifyHash(input);
        break;
      case "jwt-decode":
        output = jwtDecode(input);
        break;
      default:
        return { op, ok: false, output: "Unknown operation." };
    }
    return { op, ok: true, output, note };
  } catch (e) {
    return { op, ok: false, output: e instanceof Error ? e.message : "error" };
  }
}
