/**
 * codeReview.ts — lightweight, language-agnostic static heuristics that flag
 * common security issues in pasted code. These are intentionally conservative
 * pattern matches meant to teach and to seed a deeper review.
 */

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export interface CodeFinding {
  id: string;
  title: string;
  severity: Severity;
  line: number;
  snippet: string;
  why: string;
  fix: string;
}

interface Rule {
  id: string;
  title: string;
  severity: Severity;
  pattern: RegExp;
  why: string;
  fix: string;
}

const RULES: Rule[] = [
  {
    id: "sql-injection-concat",
    title: "Possible SQL injection (string-built query)",
    severity: "critical",
    pattern:
      /\b(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b[^;\n]*(\+\s*\w|\$\{|%\s*\(|\.format\s*\(|f["'])/i,
    why: "User input concatenated/interpolated into SQL can let an attacker alter the query.",
    fix: "Use parameterized queries / prepared statements (e.g. `db.query('... WHERE id = ?', [id])`).",
  },
  {
    id: "command-injection",
    title: "Possible command injection",
    severity: "critical",
    pattern: /\b(exec|execSync|spawnSync|system|popen|os\.system)\s*\(\s*[`'"]?[^)]*\+|\bexec\s*\(\s*`[^`]*\$\{/i,
    why: "Building shell commands from user input enables arbitrary command execution.",
    fix: "Avoid the shell; pass an argv array to spawn() with shell:false, and validate inputs.",
  },
  {
    id: "xss-innerhtml",
    title: "Potential XSS via innerHTML / dangerouslySetInnerHTML",
    severity: "high",
    pattern: /(innerHTML\s*=)|dangerouslySetInnerHTML|document\.write\s*\(/i,
    why: "Writing unsanitized data to the DOM can execute attacker-controlled script.",
    fix: "Render as text (textContent / JSX children) or sanitize with a vetted library (DOMPurify).",
  },
  {
    id: "eval-usage",
    title: "Use of eval / Function constructor",
    severity: "high",
    pattern: /\beval\s*\(|new\s+Function\s*\(/,
    why: "eval executes arbitrary code and is a common RCE/XSS vector.",
    fix: "Remove eval; use JSON.parse for data and explicit logic instead of dynamic code.",
  },
  {
    id: "hardcoded-secret",
    title: "Hardcoded secret / credential",
    severity: "high",
    pattern:
      /(api[_-]?key|secret|password|passwd|token|access[_-]?key)\s*[:=]\s*[`'"][A-Za-z0-9_\-\/+=]{8,}[`'"]/i,
    why: "Secrets in source code leak through version control and bundles.",
    fix: "Load secrets from environment variables / a secrets manager; rotate any committed secret.",
  },
  {
    id: "aws-key",
    title: "Possible AWS access key",
    severity: "critical",
    pattern: /\bAKIA[0-9A-Z]{16}\b/,
    why: "An AWS access key ID appears in the code.",
    fix: "Remove and rotate the key immediately; use IAM roles / env vars.",
  },
  {
    id: "weak-hash",
    title: "Weak hashing algorithm",
    severity: "medium",
    pattern: /createHash\s*\(\s*['"](md5|sha1)['"]\s*\)|\bMD5\b/i,
    why: "MD5/SHA1 are broken for security use (passwords, integrity).",
    fix: "Use SHA-256+ for integrity and argon2id/bcrypt/scrypt for passwords.",
  },
  {
    id: "cors-wildcard",
    title: "Over-permissive CORS",
    severity: "medium",
    pattern: /Access-Control-Allow-Origin['"]?\s*[:,]\s*['"]\*['"]|cors\(\s*\{\s*origin\s*:\s*['"]\*['"]/i,
    why: "Allowing any origin can expose authenticated endpoints to other sites.",
    fix: "Restrict origin to a known allowlist; avoid '*' with credentials.",
  },
  {
    id: "insecure-cookie",
    title: "Cookie missing security flags",
    severity: "medium",
    pattern: /set-?cookie|res\.cookie\s*\(/i,
    why: "Cookies without HttpOnly/Secure/SameSite are exposed to theft and CSRF.",
    fix: "Set { httpOnly: true, secure: true, sameSite: 'lax' } on session cookies.",
  },
  {
    id: "disabled-tls-verify",
    title: "TLS certificate verification disabled",
    severity: "high",
    pattern: /rejectUnauthorized\s*:\s*false|verify\s*=\s*False|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['"]?0/i,
    why: "Disabling certificate validation enables man-in-the-middle attacks.",
    fix: "Keep TLS verification on; trust a proper CA or pin certificates correctly.",
  },
  {
    id: "path-traversal",
    title: "Possible path traversal",
    severity: "high",
    pattern: /(readFile|sendFile|createReadStream|open)\s*\(\s*[^)]*(req\.(query|params|body)|request\.)/i,
    why: "Using request input directly in a file path can expose arbitrary files.",
    fix: "Resolve and confirm the path stays within an allowed base directory; allowlist filenames.",
  },
  {
    id: "insecure-random",
    title: "Insecure randomness for security use",
    severity: "low",
    pattern: /Math\.random\s*\(\)/,
    why: "Math.random is not cryptographically secure (tokens, IDs).",
    fix: "Use crypto.randomBytes / crypto.randomUUID for security-sensitive values.",
  },
];

export interface CodeReviewResult {
  findings: CodeFinding[];
  summary: { total: number; bySeverity: Record<Severity, number> };
}

export function reviewCode(code: string): CodeReviewResult {
  const findings: CodeFinding[] = [];
  const lines = (code ?? "").split(/\r?\n/);

  lines.forEach((lineText, idx) => {
    for (const rule of RULES) {
      if (rule.pattern.test(lineText)) {
        findings.push({
          id: `${rule.id}-${idx + 1}`,
          title: rule.title,
          severity: rule.severity,
          line: idx + 1,
          snippet: lineText.trim().slice(0, 200),
          why: rule.why,
          fix: rule.fix,
        });
      }
    }
  });

  const bySeverity: Record<Severity, number> = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
    info: 0,
  };
  for (const f of findings) bySeverity[f.severity]++;

  return { findings, summary: { total: findings.length, bySeverity } };
}
