import type { Severity } from "./utils";

const BASE = import.meta.env.VITE_API_BASE ?? "/api";

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Request failed (${res.status}): ${text.slice(0, 200)}`);
  }
  return res.json() as Promise<T>;
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  if (!res.ok) throw new Error(`Request failed (${res.status})`);
  return res.json() as Promise<T>;
}

// ---- Types ----

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface SafetyInfo {
  decision: string;
  allowed: boolean;
  category?: string;
  reason?: string;
  safeAlternative?: string;
  matched?: string[];
}

export interface ChatResponse {
  refused: boolean;
  safety?: SafetyInfo;
  reply: {
    role: "assistant";
    content: string;
    provider?: string;
    model?: string;
    offline?: boolean;
  };
}

export interface CodeFinding {
  id: string;
  title: string;
  severity: Severity;
  line: number;
  snippet: string;
  why: string;
  fix: string;
}

export interface CodeReviewResult {
  findings: CodeFinding[];
  summary: { total: number; bySeverity: Record<Severity, number> };
}

export interface LogFinding {
  id: string;
  title: string;
  severity: Severity;
  count: number;
  examples: string[];
  explanation: string;
  recommendation: string;
}

export interface LogAnalysisResult {
  findings: LogFinding[];
  totalLines: number;
  summary: { total: number; bySeverity: Record<Severity, number> };
}

export interface ScopeResult {
  allowed: boolean;
  host: string | null;
  isPrivate: boolean;
  reason: string;
}

export interface ChecklistItem {
  id: string;
  title: string;
  description: string;
  checks: string[];
  remediation: string[];
  severityHint: Severity;
}

export interface SecurityHeader {
  header: string;
  purpose: string;
  example: string;
}

export interface CommandResult {
  allowed: boolean;
  ran: boolean;
  bin?: string;
  args?: string[];
  exitCode?: number | null;
  stdout?: string;
  stderr?: string;
  reason?: string;
  durationMs?: number;
}

export interface AllowlistInfo {
  enabled: boolean;
  workspace: string;
  allowed: { bin: string; description: string; allowedSubcommands?: string[] }[];
  blocked: string[];
}

export interface ReportFindingInput {
  title: string;
  severity: Severity;
  description: string;
  impact?: string;
  remediation?: string;
  evidence?: string;
}

// ---- API ----

export const api = {
  health: () => get<{ status: string; llmProvider: string }>("/health"),

  chat: (mode: string, messages: ChatMessage[]) =>
    post<ChatResponse>("/chat", { mode, messages }),

  scopeCheck: (target: string, confirmedScope: string[]) =>
    post<ScopeResult>("/audit/scope-check", { target, confirmedScope }),

  checklist: () => get<{ items: ChecklistItem[] }>("/audit/checklist"),
  headers: () => get<{ headers: SecurityHeader[] }>("/audit/headers"),

  codeReview: (code: string) =>
    post<CodeReviewResult>("/analysis/code-review", { code }),

  analyzeLogs: (log: string) =>
    post<LogAnalysisResult>("/analysis/logs", { log }),

  generateReport: (input: {
    title?: string;
    client?: string;
    author?: string;
    scope?: string[];
    findings: ReportFindingInput[];
    recommendations?: string[];
  }) => post<{ markdown: string }>("/analysis/report", input),

  allowlist: () => get<AllowlistInfo>("/command/allowlist"),
  runCommand: (command: string) =>
    post<CommandResult>("/command/run", { command }),
  validateCommand: (command: string) =>
    post<{ allowed: boolean; reason?: string }>("/command/validate", { command }),
};
