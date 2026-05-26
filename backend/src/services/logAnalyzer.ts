/**
 * logAnalyzer.ts — defensive (blue-team) log heuristics. Detects suspicious
 * patterns in pasted logs and explains them so a defender can respond. No
 * offensive guidance is produced.
 */

import type { Severity } from "./codeReview";

export interface LogFinding {
  id: string;
  title: string;
  severity: Severity;
  count: number;
  examples: string[];
  explanation: string;
  recommendation: string;
}

interface LogRule {
  id: string;
  title: string;
  severity: Severity;
  pattern: RegExp;
  explanation: string;
  recommendation: string;
}

const RULES: LogRule[] = [
  {
    id: "sqli-probe",
    title: "SQL injection probing",
    severity: "high",
    pattern: /(\bunion\s+select\b|\bor\s+1=1\b|sleep\(\d+\)|information_schema|';--|\bxp_cmdshell\b)/i,
    explanation: "Requests contain classic SQL injection probe strings.",
    recommendation:
      "Confirm parameterized queries are used; consider blocking the source IP and reviewing affected endpoints.",
  },
  {
    id: "xss-probe",
    title: "XSS probing",
    severity: "medium",
    pattern: /(<script\b|onerror\s*=|onload\s*=|javascript:|%3Cscript)/i,
    explanation: "Requests contain script/HTML injection probe payloads.",
    recommendation:
      "Verify output encoding and CSP; review whether any payload was reflected/stored.",
  },
  {
    id: "path-traversal",
    title: "Path traversal attempts",
    severity: "high",
    pattern: /(\.\.\/|\.\.\\|%2e%2e%2f|\/etc\/passwd|boot\.ini)/i,
    explanation: "Requests try to escape the web root to read arbitrary files.",
    recommendation:
      "Confirm file access is sandboxed to an allowed directory; block the source and alert.",
  },
  {
    id: "auth-bruteforce",
    title: "Authentication brute force / credential stuffing",
    severity: "high",
    pattern: /(401|403)\b.*(login|signin|auth)|(login|signin|auth).*(401|403)|failed\s+(login|password|authentication)/i,
    explanation: "Repeated authentication failures suggest brute force or credential stuffing.",
    recommendation:
      "Enforce rate limiting, lockout, and MFA; alert on failure bursts per IP/account.",
  },
  {
    id: "scanner-ua",
    title: "Automated scanner activity",
    severity: "medium",
    pattern: /(sqlmap|nikto|nmap|acunetix|nessus|dirbuster|gobuster|wpscan|masscan|fuzz)/i,
    explanation: "User-agent or path indicates an automated vulnerability scanner.",
    recommendation:
      "Confirm the scan is authorized; otherwise rate-limit/block and review what was probed.",
  },
  {
    id: "cmd-injection",
    title: "Command injection attempts",
    severity: "high",
    pattern: /(;\s*(cat|ls|id|whoami|wget|curl)\b|\|\s*(bash|sh)\b|\$\(.*\)|`.*`)/i,
    explanation: "Requests contain shell metacharacters / command sequences.",
    recommendation:
      "Ensure no user input reaches a shell; block source and review affected handlers.",
  },
  {
    id: "server-errors",
    title: "Server error spike (5xx)",
    severity: "low",
    pattern: /\b50[0-9]\b/,
    explanation: "5xx responses can indicate instability or an exploitation attempt causing faults.",
    recommendation:
      "Correlate with request patterns; investigate stack traces and ensure errors aren't leaking details.",
  },
];

export interface LogAnalysisResult {
  findings: LogFinding[];
  totalLines: number;
  summary: { total: number; bySeverity: Record<Severity, number> };
}

export function analyzeLogs(logText: string): LogAnalysisResult {
  const lines = (logText ?? "").split(/\r?\n/).filter((l) => l.trim());
  const findings: LogFinding[] = [];

  for (const rule of RULES) {
    const matches = lines.filter((l) => rule.pattern.test(l));
    if (matches.length === 0) continue;
    findings.push({
      id: rule.id,
      title: rule.title,
      severity: rule.severity,
      count: matches.length,
      examples: matches.slice(0, 3).map((m) => m.trim().slice(0, 200)),
      explanation: rule.explanation,
      recommendation: rule.recommendation,
    });
  }

  const bySeverity: Record<Severity, number> = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
    info: 0,
  };
  for (const f of findings) bySeverity[f.severity]++;

  return {
    findings,
    totalLines: lines.length,
    summary: { total: findings.length, bySeverity },
  };
}
