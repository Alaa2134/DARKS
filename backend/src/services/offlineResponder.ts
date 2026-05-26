/**
 * offlineResponder.ts
 * ----------------------------------------------------------------------------
 * Produces genuinely useful, structured Markdown responses with NO external
 * API. This keeps Horus fully functional for a hackathon demo when no LLM key
 * is configured, and as a graceful fallback when an API call fails.
 */

import { OWASP_TOP_10, SECURITY_HEADERS } from "../data/owasp";
import { CTF_CATEGORIES } from "../data/ctf";

function owaspChecklistMarkdown(): string {
  const lines = OWASP_TOP_10.map((item) => {
    const checks = item.checks.map((c) => `  - [ ] ${c}`).join("\n");
    return `### ${item.id} — ${item.title} _(severity hint: ${item.severityHint})_\n${item.description}\n${checks}`;
  });
  return lines.join("\n\n");
}

function headersMarkdown(): string {
  return SECURITY_HEADERS.map(
    (h) => `- **${h.header}** — ${h.purpose}\n  \`${h.example}\``
  ).join("\n");
}

function ctfMarkdown(query: string): string {
  const q = query.toLowerCase();
  const match =
    CTF_CATEGORIES.find((c) => q.includes(c.id) || q.includes(c.name.toLowerCase())) ??
    null;

  if (match) {
    return `## CTF Helper — ${match.name}\n${match.summary}\n\n**Methodology**\n${match.methodology
      .map((m, i) => `${i + 1}. ${m}`)
      .join("\n")}\n\n**Common tools:** ${match.commonTools.join(", ")}\n\n**Learn more:** ${match.learnMore.join(
      ", "
    )}\n\n_Reminder: only work against the challenge sandbox you've been given._`;
  }

  const list = CTF_CATEGORIES.map(
    (c) => `- **${c.name}** — ${c.summary}`
  ).join("\n");
  return `## CTF Helper\nPick a category and I'll give you a methodology + hints:\n\n${list}\n\nTell me the category (web, crypto, forensics, rev, pwn, osint) and what you've tried.`;
}

export function offlineResponse(mode: string, userText: string): string {
  switch (mode) {
    case "ctf":
      return ctfMarkdown(userText);

    case "webaudit":
      return `## Web Audit — OWASP Top 10 Checklist\nThis checklist assumes a **local/private lab host or an asset you've confirmed you own**.\n\n${owaspChecklistMarkdown()}\n\n## Recommended Security Headers\n${headersMarkdown()}\n\nPaste a code snippet or a log file and I'll go deeper, or generate a report from your findings.`;

    case "codereview":
      return `## Secure Code Review\nPaste the code you'd like reviewed and I'll check for:\n\n- SQL/NoSQL/command injection\n- XSS (stored/reflected/DOM)\n- Weak authentication & session handling\n- Insecure file upload\n- Exposed secrets / hardcoded credentials\n- Over-permissive CORS\n- Missing input validation\n\nFor each finding I'll give severity, location, why it's risky, and a secure fix. _(Use the Secure Code Review page to run the built-in static checks instantly.)_`;

    case "loganalysis":
      return `## Defensive Log Analysis\nPaste logs (access/auth/WAF/error) and I'll highlight suspicious patterns such as:\n\n- Brute-force / credential-stuffing bursts\n- Path traversal & injection probes\n- Scanner user-agents and enumeration\n- Unusual status-code spikes\n\nI'll explain each pattern defensively and recommend detections + mitigations. _(The Terminal Logs page runs these heuristics instantly.)_`;

    case "report":
      return `## Report Generator\nProvide your findings (title, severity, description) and scope, and I'll assemble a professional report:\n\n1. Executive Summary\n2. Scope\n3. Methodology\n4. Findings (severity, evidence placeholder, impact, remediation)\n5. Final Recommendations\n\n_(The Reports page builds and exports Markdown reports directly.)_`;

    default:
      return `## Horus Cyber Agent\nI'm your safe, ethical cybersecurity workspace. I can help with:\n\n- **CTF Helper** — methodology and hints for web, crypto, forensics, rev, pwn, OSINT\n- **Web Audit** — OWASP Top 10 checklist for your own/lab targets\n- **Secure Code Review** — find and fix injection, XSS, auth, secrets issues\n- **Log Analysis** — defensive detection of suspicious patterns\n- **Reports** — professional pentest-style write-ups\n\nWhat would you like to work on? _(No API key is configured, so I'm running in built-in template mode — every feature still works.)_\n\nTry: "Create an OWASP checklist for my local web app" or "Review this code for SQL injection".`;
  }
}
