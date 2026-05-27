/**
 * codeReview.ts — lightweight, language-agnostic static heuristics that flag
 * common security issues in pasted code. These are intentionally conservative
 * pattern matches meant to teach and to seed a deeper review.
 */

import { mapCompliance } from "../data/compliance";

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export interface CodeFinding {
  id: string;
  title: string;
  severity: Severity;
  line: number;
  snippet: string;
  why: string;
  fix: string;
  cwe?: string;
  owasp?: string;
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
  // ---- Python ----
  {
    id: "py-subprocess-shell",
    title: "Python: shell=True with subprocess",
    severity: "high",
    pattern: /subprocess\.(run|call|Popen|check_output)\s*\([^)]*shell\s*=\s*True/i,
    why: "shell=True with interpolated input enables command injection.",
    fix: "Pass an argument list and shell=False; validate inputs.",
  },
  {
    id: "py-pickle",
    title: "Python: insecure deserialization (pickle)",
    severity: "high",
    pattern: /\b(pickle|cPickle)\.(loads?|load)\s*\(/,
    why: "Unpickling untrusted data can execute arbitrary code.",
    fix: "Use JSON or a safe schema; never unpickle untrusted input.",
  },
  {
    id: "py-yaml-load",
    title: "Python: unsafe yaml.load",
    severity: "high",
    pattern: /yaml\.load\s*\((?![^)]*Loader\s*=\s*yaml\.SafeLoader)/,
    why: "yaml.load without SafeLoader can instantiate arbitrary objects.",
    fix: "Use yaml.safe_load() or specify Loader=yaml.SafeLoader.",
  },
  {
    id: "py-flask-debug",
    title: "Python: Flask debug mode enabled",
    severity: "medium",
    pattern: /app\.run\s*\([^)]*debug\s*=\s*True/i,
    why: "Flask debug mode exposes an interactive debugger (RCE) in production.",
    fix: "Disable debug in production; gate it behind an env flag.",
  },
  // ---- PHP ----
  {
    id: "php-superglobal-sink",
    title: "PHP: tainted superglobal in dangerous sink",
    severity: "critical",
    pattern: /\b(eval|system|exec|include|require|passthru|shell_exec)\s*\(\s*\$_(GET|POST|REQUEST|COOKIE)/i,
    why: "User-controlled superglobals flowing into code/command/file sinks enable RCE/LFI.",
    fix: "Never pass request input to these sinks; validate and allowlist.",
  },
  // ---- Java ----
  {
    id: "java-runtime-exec",
    title: "Java: Runtime.exec with concatenation",
    severity: "high",
    pattern: /Runtime\.getRuntime\(\)\.exec\s*\([^)]*\+/,
    why: "Building a command string from input enables command injection.",
    fix: "Use ProcessBuilder with an argument list; validate inputs.",
  },
  {
    id: "java-statement-concat",
    title: "Java: SQL built via Statement + concatenation",
    severity: "critical",
    pattern: /(createStatement\(\)|executeQuery\s*\()[^;]*\+\s*\w/,
    why: "String-built SQL with Statement is injectable.",
    fix: "Use PreparedStatement with bound parameters.",
  },
  // ---- Go ----
  {
    id: "go-sprintf-sql",
    title: "Go: SQL built with fmt.Sprintf",
    severity: "high",
    pattern: /fmt\.Sprintf\s*\(\s*"[^"]*(SELECT|INSERT|UPDATE|DELETE)[^"]*%/i,
    why: "Formatting user input into SQL is injectable.",
    fix: "Use parameterized queries (db.Query with $1/? placeholders).",
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
        const compliance = mapCompliance(`${rule.title} ${rule.id}`);
        findings.push({
          id: `${rule.id}-${idx + 1}`,
          title: rule.title,
          severity: rule.severity,
          line: idx + 1,
          snippet: lineText.trim().slice(0, 200),
          why: rule.why,
          fix: rule.fix,
          cwe: compliance.cwe,
          owasp: compliance.owasp,
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
