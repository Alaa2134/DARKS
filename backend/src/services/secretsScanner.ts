/**
 * secretsScanner.ts — built-in secret detection (no external tool needed).
 * Combines high-signal provider patterns with a Shannon-entropy check for
 * generic high-entropy tokens. Educational/defensive: helps find secrets that
 * should be rotated and moved to a vault.
 */

import type { CodeFinding, Severity } from "./codeReview";

interface SecretRule {
  id: string;
  name: string;
  severity: Severity;
  pattern: RegExp;
}

// Patterns describe the SHAPE of provider tokens (not real secrets).
const RULES: SecretRule[] = [
  { id: "aws-akid", name: "AWS Access Key ID", severity: "critical", pattern: /\bAKIA[0-9A-Z]{16}\b/ },
  { id: "aws-secret", name: "AWS Secret Access Key", severity: "critical", pattern: /\baws_secret_access_key\b\s*[:=]\s*['"][A-Za-z0-9/+]{40}['"]/i },
  { id: "gcp-key", name: "Google API key", severity: "high", pattern: /\bAIza[0-9A-Za-z\-_]{35}\b/ },
  { id: "github-token", name: "GitHub token", severity: "critical", pattern: /\bgh[pousr]_[0-9A-Za-z]{30,}\b/ },
  { id: "slack-token", name: "Slack token", severity: "high", pattern: /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/ },
  { id: "stripe-key", name: "Stripe secret key", severity: "critical", pattern: /\bsk_(live|test)_[0-9A-Za-z]{16,}\b/ },
  { id: "private-key", name: "Private key block", severity: "critical", pattern: /-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/ },
  { id: "jwt", name: "JSON Web Token", severity: "medium", pattern: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/ },
  { id: "generic-assign", name: "Generic secret assignment", severity: "high", pattern: /\b(api[_-]?key|secret|token|passwd|password|access[_-]?key)\b\s*[:=]\s*['"][^'"\s]{12,}['"]/i },
  { id: "slack-webhook", name: "Slack webhook URL", severity: "high", pattern: /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/]+/ },
];

function shannonEntropy(s: string): number {
  const freq: Record<string, number> = {};
  for (const c of s) freq[c] = (freq[c] ?? 0) + 1;
  let e = 0;
  for (const c in freq) {
    const p = freq[c] / s.length;
    e -= p * Math.log2(p);
  }
  return e;
}

const HIGH_ENTROPY_TOKEN = /['"]([A-Za-z0-9+/=_-]{24,})['"]/g;

export function scanSecrets(code: string): CodeFinding[] {
  const findings: CodeFinding[] = [];
  const lines = (code ?? "").split(/\r?\n/);

  lines.forEach((lineText, idx) => {
    for (const rule of RULES) {
      const m = lineText.match(rule.pattern);
      if (m) {
        findings.push({
          id: `secret-${rule.id}-${idx + 1}`,
          title: `Exposed secret: ${rule.name}`,
          severity: rule.severity,
          line: idx + 1,
          snippet: redact(lineText.trim()).slice(0, 200),
          why: `A ${rule.name} appears hardcoded in source. Secrets in code leak via version control and bundles.`,
          fix: "Remove and rotate the secret immediately; load it from an environment variable or secrets manager, and add secret scanning to CI.",
        });
      }
    }

    // Generic high-entropy token heuristic (skip if a rule already fired here).
    if (!findings.some((f) => f.line === idx + 1)) {
      let match: RegExpExecArray | null;
      HIGH_ENTROPY_TOKEN.lastIndex = 0;
      while ((match = HIGH_ENTROPY_TOKEN.exec(lineText)) !== null) {
        const token = match[1];
        if (shannonEntropy(token) >= 4.0 && /[0-9]/.test(token) && /[A-Za-z]/.test(token)) {
          findings.push({
            id: `secret-entropy-${idx + 1}`,
            title: "Possible hardcoded high-entropy secret",
            severity: "medium",
            line: idx + 1,
            snippet: redact(lineText.trim()).slice(0, 200),
            why: "A high-entropy string that resembles a credential or key was found inline.",
            fix: "If this is a secret, move it to an environment variable / secrets manager and rotate it.",
          });
          break;
        }
      }
    }
  });

  return findings;
}

function redact(line: string): string {
  return line.replace(/(['"])([^'"\s]{8})[^'"\s]+(['"])/g, "$1$2…[redacted]$3");
}
