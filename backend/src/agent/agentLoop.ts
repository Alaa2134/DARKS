/**
 * agentLoop.ts
 * ----------------------------------------------------------------------------
 * The agentic core. Given a goal (and optional code/log/target payloads) it:
 *   1. Runs the safety filter on the goal.
 *   2. Plans a sequence of safe local tool calls.
 *   3. Executes each tool, accumulating findings.
 *   4. Grounds with the knowledge base (RAG) and synthesizes a final answer
 *      (LLM when a key is configured, otherwise a structured offline summary).
 *
 * Progress is reported through an event callback so the route can stream it
 * over SSE. This is a deterministic planner (reliable + testable); the optional
 * LLM is used for the final natural-language synthesis.
 */

import { evaluateText } from "../safety/safetyFilter";
import { tools, type ToolName } from "./tools";
import { buildContext } from "../knowledge/retriever";
import { chat } from "../services/llmService";
import { logSafety } from "../db/database";
import type { ReportFinding } from "../services/reportGenerator";

export interface AgentInput {
  goal: string;
  code?: string;
  language?: string;
  log?: string;
  target?: string;
  confirmedScope?: string[];
}

export type AgentEvent =
  | { type: "plan"; steps: string[] }
  | { type: "step"; tool: string; input: string; index: number }
  | { type: "tool_result"; tool: string; summary: string; ok: boolean; index: number }
  | { type: "token"; text: string }
  | { type: "sources"; sources: { id: string; title: string; source: string }[] }
  | { type: "refused"; reason: string; category?: string; safeAlternative?: string }
  | { type: "done"; findings: ReportFinding[] }
  | { type: "error"; message: string };

type Emit = (e: AgentEvent) => void | Promise<void>;

interface PlannedStep {
  tool: ToolName;
  label: string;
  input: Record<string, unknown>;
}

function plan(input: AgentInput): PlannedStep[] {
  const g = input.goal.toLowerCase();
  const steps: PlannedStep[] = [];

  // Always ground the answer in the knowledge base.
  steps.push({
    tool: "kb_search",
    label: `Search knowledge base for "${input.goal.slice(0, 50)}"`,
    input: { query: input.goal },
  });

  if (input.target) {
    steps.push({
      tool: "scope_check",
      label: `Confirm scope for ${input.target}`,
      input: { target: input.target, confirmedScope: input.confirmedScope ?? [] },
    });
  }

  const wantsAudit = /audit|owasp|web app|website|checklist|pentest/.test(g) || !!input.target;
  if (wantsAudit) {
    steps.push({ tool: "owasp_checklist", label: "Load OWASP Top 10 checklist", input: {} });
  }

  if (input.code || /review|code|sql injection|xss|vulnerab/.test(g)) {
    if (input.code) {
      steps.push({
        tool: "code_review",
        label: "Run secure code review (heuristics + engines)",
        input: { code: input.code, language: input.language },
      });
    }
  }

  if (input.log || /log|brute|waf|access log|auth log/.test(g)) {
    if (input.log) {
      steps.push({
        tool: "analyze_logs",
        label: "Analyze logs defensively",
        input: { log: input.log },
      });
    }
  }

  return steps;
}

export async function runAgent(input: AgentInput, emit: Emit): Promise<void> {
  // 1. Safety gate.
  const safety = evaluateText(`${input.goal}\n${input.code ?? ""}\n${input.log ?? ""}`);
  if (!safety.allowed) {
    logSafety({
      decision: "refuse",
      category: safety.category,
      reason: safety.reason,
      excerpt: input.goal,
      context: "agent",
    });
    await emit({
      type: "refused",
      reason: safety.reason ?? "Request refused by safety policy.",
      category: safety.category,
      safeAlternative: safety.safeAlternative,
    });
    return;
  }
  logSafety({ decision: "allow", excerpt: input.goal, context: "agent" });

  try {
    // 2. Plan.
    const planned = plan(input);
    await emit({ type: "plan", steps: planned.map((s) => s.label) });

    // 3. Execute tools.
    const collectedFindings: ReportFinding[] = [];
    const toolSummaries: string[] = [];
    let sources: { id: string; title: string; source: string }[] = [];
    const wantsReport = /report|write[- ]?up|document|summary/.test(input.goal.toLowerCase());

    for (let i = 0; i < planned.length; i++) {
      const step = planned[i];
      await emit({
        type: "step",
        tool: step.tool,
        input: JSON.stringify(step.input).slice(0, 120),
        index: i,
      });
      const result = await (tools[step.tool] as (a: unknown) => Promise<any>)(step.input);
      await emit({
        type: "tool_result",
        tool: step.tool,
        summary: result.summary,
        ok: result.ok,
        index: i,
      });
      toolSummaries.push(`- ${step.label}: ${result.summary}`);
      if (result.findings) collectedFindings.push(...result.findings);
      if (step.tool === "kb_search" && Array.isArray(result.data)) {
        sources = (result.data as any[]).map((d) => ({
          id: d.id,
          title: d.title,
          source: d.source,
        }));
      }
    }

    // Optionally compile a report from collected findings.
    if (wantsReport && collectedFindings.length > 0) {
      await emit({
        type: "step",
        tool: "generate_report",
        input: `${collectedFindings.length} findings`,
        index: planned.length,
      });
      const rep = await tools.generate_report({
        findings: collectedFindings,
        scope: input.confirmedScope,
      });
      await emit({
        type: "tool_result",
        tool: "generate_report",
        summary: rep.summary,
        ok: rep.ok,
        index: planned.length,
      });
      toolSummaries.push(`- Generate report: ${rep.summary}`);
    }

    if (sources.length > 0) await emit({ type: "sources", sources });

    // 4. Synthesize a grounded final answer.
    const { context } = buildContext(input.goal, 4);
    const text = await synthesize(input.goal, toolSummaries, context, collectedFindings);

    // Stream the synthesized text in chunks.
    for (const chunk of chunkText(text)) {
      await emit({ type: "token", text: chunk });
    }

    await emit({ type: "done", findings: collectedFindings });
  } catch (err) {
    await emit({
      type: "error",
      message: err instanceof Error ? err.message : "Agent error",
    });
  }
}

async function synthesize(
  goal: string,
  toolSummaries: string[],
  context: string,
  findings: ReportFinding[]
): Promise<string> {
  const grounding =
    `GOAL: ${goal}\n\nTOOL RESULTS:\n${toolSummaries.join("\n")}\n\n` +
    (context ? `KNOWLEDGE BASE (cite ids like [owasp-a03-injection]):\n${context}\n\n` : "") +
    (findings.length
      ? `FINDINGS:\n${findings
          .map((f) => `- [${f.severity}] ${f.title}: ${f.description}`)
          .join("\n")}\n\n`
      : "");

  const reply = await chat("chat", [
    {
      role: "user",
      content:
        `You are the Horus agent. Using ONLY the tool results and knowledge below, ` +
        `write a concise, actionable answer to the goal. Cite knowledge ids in [brackets]. ` +
        `End with prioritized next steps.\n\n${grounding}`,
    },
  ]);

  // In offline mode the LLM returns a template; prepend our deterministic
  // grounded summary so the answer is always substantive.
  if (reply.offline) {
    return offlineSynthesis(goal, toolSummaries, findings, context);
  }
  return reply.content;
}

function offlineSynthesis(
  goal: string,
  toolSummaries: string[],
  findings: ReportFinding[],
  context: string
): string {
  const sevOrder = ["critical", "high", "medium", "low", "info"] as const;
  const sorted = [...findings].sort(
    (a, b) => sevOrder.indexOf(a.severity) - sevOrder.indexOf(b.severity)
  );
  const findingsMd = sorted.length
    ? sorted
        .slice(0, 12)
        .map((f) => `- **[${f.severity.toUpperCase()}] ${f.title}** — ${f.description}\n  - _Fix:_ ${f.remediation ?? "see remediation guidance"}`)
        .join("\n")
    : "_No concrete findings from the executed tools._";

  const cited: string[] = Array.from(
    new Set(context.match(/\[[a-z0-9-]+\]/g) ?? [])
  ).slice(0, 4);

  return `## Agent result\n\n**Goal:** ${goal}\n\n### What I did\n${toolSummaries.join("\n")}\n\n### Findings & fixes\n${findingsMd}\n\n### Grounded guidance\nBased on the knowledge base${cited.length ? ` (${cited.join(", ")})` : ""}, prioritize fixing Critical/High issues first, apply the recommended security headers, use parameterized queries and output encoding, and re-test after changes.\n\n### Next steps\n1. Triage Critical/High findings.\n2. Apply the secure fixes above.\n3. Push the findings into a report (ask: "generate a report").\n4. Re-run the relevant tool to verify the fix.\n\n> _Offline template mode — add an ANTHROPIC_API_KEY to enable richer AI synthesis. Tools, findings and grounding above are produced locally and are fully real._`;
}

function chunkText(text: string, size = 24): string[] {
  const words = text.split(/(\s+)/);
  const chunks: string[] = [];
  let buf = "";
  for (const w of words) {
    buf += w;
    if (buf.length >= size) {
      chunks.push(buf);
      buf = "";
    }
  }
  if (buf) chunks.push(buf);
  return chunks;
}
