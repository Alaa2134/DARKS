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
  cwe?: string;
  owasp?: string;
}

export interface DashboardStats {
  findingsBySeverity: Record<Severity, number>;
  totalFindings: number;
  totalReports: number;
  refusals: number;
}

export interface CvssResult {
  baseScore: number;
  severity: Severity;
  vector: string;
}

export interface Threat {
  category: string;
  component: string;
  threat: string;
  mitigation: string;
  severityHint: Severity;
}

export interface ThreatModelResult {
  system: string;
  components: string[];
  threats: Threat[];
  trustBoundaries: string[];
}

export interface CtfResult {
  op: string;
  ok: boolean;
  output: string;
  note?: string;
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

export interface EngineStatus {
  name: string;
  available: boolean;
  ran: boolean;
  note?: string;
  findingCount: number;
}

export interface ScanResult extends CodeReviewResult {
  engines: EngineStatus[];
}

export interface KbDoc {
  id: string;
  title: string;
  source: string;
  text: string;
  score: number;
}

export interface DbFinding {
  id: number;
  title: string;
  severity: Severity;
  description: string;
  impact?: string | null;
  remediation?: string | null;
  evidence?: string | null;
  source: string;
  created_at: string;
}

export interface SafetyLogEntry {
  id: number;
  decision: string;
  category?: string | null;
  reason?: string | null;
  excerpt?: string | null;
  context?: string | null;
  created_at: string;
}

export interface SafetyStats {
  total: number;
  refusals: number;
  byCategory: { category: string; count: number }[];
}

export type AgentEvent =
  | { type: "plan"; steps: string[] }
  | { type: "step"; tool: string; input: string; index: number }
  | { type: "tool_result"; tool: string; summary: string; ok: boolean; index: number }
  | { type: "token"; text: string }
  | { type: "sources"; sources: { id: string; title: string; source: string }[] }
  | { type: "refused"; reason: string; category?: string; safeAlternative?: string }
  | { type: "done"; findings: ReportFindingInput[] }
  | { type: "error"; message: string };

export interface AgentInput {
  goal: string;
  code?: string;
  language?: string;
  log?: string;
  target?: string;
  confirmedScope?: string[];
}

/** Stream the agent's progress over SSE (POST + ReadableStream). */
export async function streamAgent(
  input: AgentInput,
  onEvent: (e: AgentEvent) => void,
  signal?: AbortSignal
): Promise<void> {
  const res = await fetch(`${BASE}/agent/stream`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
    signal,
  });
  if (!res.ok || !res.body) {
    throw new Error(`Agent request failed (${res.status})`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split("\n\n");
    buffer = frames.pop() ?? "";
    for (const frame of frames) {
      const line = frame.split("\n").find((l) => l.startsWith("data: "));
      if (!line) continue;
      const json = line.slice(6).trim();
      if (!json) continue;
      try {
        onEvent(JSON.parse(json) as AgentEvent);
      } catch {
        /* ignore malformed frame */
      }
    }
  }
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
  deepScan: (code: string, language?: string) =>
    post<ScanResult>("/analysis/scan", { code, language }),
  auditDeps: () =>
    post<{ available: boolean; ran: boolean; note?: string; vulnerabilities: { name: string; severity: string; title?: string }[]; totals: Record<string, number> }>(
      "/analysis/audit-deps",
      {}
    ),

  kbSearch: (q: string, k = 5) =>
    get<{ results: KbDoc[] }>(`/kb/search?q=${encodeURIComponent(q)}&k=${k}`),

  listFindings: () => get<{ findings: DbFinding[] }>("/findings"),
  addFinding: (f: Omit<DbFinding, "id" | "created_at">) =>
    post<{ finding: DbFinding }>("/findings", f),
  deleteFinding: (id: number) =>
    fetch(`${BASE}/findings/${id}`, { method: "DELETE" }).then((r) => r.json()),
  clearFindings: () =>
    fetch(`${BASE}/findings`, { method: "DELETE" }).then((r) => r.json()),

  listReports: () =>
    get<{ reports: { id: number; title: string; client?: string | null; finding_count: number; created_at: string }[] }>(
      "/reports"
    ),
  getReport: (id: number) =>
    get<{ report: { id: number; title: string; markdown: string } }>(`/reports/${id}`),
  saveReport: (r: { title: string; client?: string; markdown: string; finding_count: number }) =>
    post<{ report: { id: number } }>("/reports", r),

  safetyLog: () =>
    get<{ entries: SafetyLogEntry[]; stats: SafetyStats }>("/safety/log"),

  stats: () => get<DashboardStats>("/stats"),

  cvss: (vector: string) => post<CvssResult>("/analysis/cvss", { vector }),
  cvssMetrics: (metrics: Record<string, string>) =>
    post<CvssResult>("/analysis/cvss", { metrics }),

  threatModel: (system: string, components?: string[]) =>
    post<ThreatModelResult>("/analysis/threat-model", { system, components }),

  ctfOps: () => get<{ ops: string[] }>("/ctf/ops"),
  ctfTransform: (op: string, input: string, param?: string) =>
    post<CtfResult>("/ctf/transform", { op, input, param }),

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
