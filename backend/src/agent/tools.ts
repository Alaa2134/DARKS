/**
 * tools.ts — the safe, local tools the agent can invoke. Every tool maps to an
 * existing Horus capability; none performs active network attacks.
 */

import { evaluateTarget } from "../safety/safetyFilter";
import { reviewCode } from "../services/codeReview";
import { analyzeLogs } from "../services/logAnalyzer";
import { deepScan } from "../services/scanEngines";
import { generateReport, type ReportFinding } from "../services/reportGenerator";
import { retrieve } from "../knowledge/retriever";
import { OWASP_TOP_10 } from "../data/owasp";
import type { Severity } from "../services/codeReview";

export interface ToolResult {
  ok: boolean;
  summary: string;
  data?: unknown;
  findings?: ReportFinding[];
}

export const tools = {
  async scope_check(input: { target: string; confirmedScope?: string[] }): Promise<ToolResult> {
    const r = evaluateTarget(input.target, input.confirmedScope ?? []);
    return {
      ok: r.allowed,
      summary: r.allowed
        ? `Target ${r.host} is in scope (${r.isPrivate ? "private/lab" : "confirmed owned"}).`
        : `Target ${r.host ?? input.target} is OUT OF SCOPE — ${r.reason}`,
      data: r,
    };
  },

  async owasp_checklist(): Promise<ToolResult> {
    return {
      ok: true,
      summary: `Loaded OWASP Top 10 checklist (${OWASP_TOP_10.length} categories).`,
      data: OWASP_TOP_10,
    };
  },

  async code_review(input: { code: string; language?: string }): Promise<ToolResult> {
    const scan = await deepScan(input.code, input.language);
    const findings: ReportFinding[] = scan.findings.map((f) => ({
      title: f.title,
      severity: f.severity,
      description: `${f.why} (line ${f.line})`,
      remediation: f.fix,
      evidence: f.snippet,
    }));
    return {
      ok: true,
      summary: `Code review found ${scan.summary.total} issue(s): ${describeSeverity(scan.summary.bySeverity)}. Engines: ${scan.engines
        .map((e) => `${e.name}${e.ran ? "" : "(skipped)"}`)
        .join(", ")}.`,
      data: scan,
      findings,
    };
  },

  async analyze_logs(input: { log: string }): Promise<ToolResult> {
    const r = analyzeLogs(input.log);
    const findings: ReportFinding[] = r.findings.map((f) => ({
      title: f.title,
      severity: f.severity,
      description: `${f.explanation} (observed ${f.count}×)`,
      remediation: f.recommendation,
      evidence: f.examples[0],
    }));
    return {
      ok: true,
      summary: `Log analysis scanned ${r.totalLines} line(s) and flagged ${r.summary.total} pattern(s).`,
      data: r,
      findings,
    };
  },

  async kb_search(input: { query: string; k?: number }): Promise<ToolResult> {
    const docs = retrieve(input.query, input.k ?? 4);
    return {
      ok: docs.length > 0,
      summary:
        docs.length > 0
          ? `Retrieved ${docs.length} knowledge passage(s): ${docs.map((d) => d.id).join(", ")}.`
          : "No relevant knowledge found.",
      data: docs,
    };
  },

  async generate_report(input: {
    findings: ReportFinding[];
    title?: string;
    scope?: string[];
  }): Promise<ToolResult> {
    const markdown = generateReport({
      title: input.title,
      scope: input.scope,
      findings: input.findings,
    });
    return {
      ok: true,
      summary: `Generated a report with ${input.findings.length} finding(s).`,
      data: { markdown },
    };
  },
};

export type ToolName = keyof typeof tools;

function describeSeverity(b: Record<Severity, number>): string {
  return (["critical", "high", "medium", "low"] as Severity[])
    .filter((s) => b[s] > 0)
    .map((s) => `${b[s]} ${s}`)
    .join(", ") || "none";
}
