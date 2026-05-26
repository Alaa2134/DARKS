/**
 * scanEngines.ts
 * ----------------------------------------------------------------------------
 * Optional integration with real security scanners (semgrep, bandit, npm audit).
 * Each engine is detected at runtime; if it isn't installed Horus degrades
 * gracefully to its built-in heuristics. Engines run via spawn with shell:false
 * and a timeout, in the sandboxed workspace.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { config } from "../config";
import { reviewCode, type CodeFinding, type Severity } from "./codeReview";
import { scanSecrets } from "./secretsScanner";
import { mapCompliance } from "../data/compliance";

interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
  error?: string;
}

function run(bin: string, args: string[], cwd: string): Promise<RunResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let done = false;
    const child = spawn(bin, args, { cwd, shell: false, windowsHide: true });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      child.kill("SIGKILL");
      resolve({ code: null, stdout, stderr, error: "timeout" });
    }, config.engines.timeoutMs);
    child.stdout?.on("data", (d) => (stdout += d.toString()));
    child.stderr?.on("data", (d) => (stderr += d.toString()));
    child.on("error", (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code: null, stdout, stderr, error: e.message });
    });
    child.on("close", (c) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code: c, stdout, stderr });
    });
  });
}

async function which(bin: string): Promise<boolean> {
  const finder = process.platform === "win32" ? "where" : "which";
  const r = await run(finder, [bin], process.cwd());
  return r.code === 0 && r.stdout.trim().length > 0;
}

function mapSemgrepSeverity(s: string): Severity {
  switch ((s || "").toUpperCase()) {
    case "ERROR":
      return "high";
    case "WARNING":
      return "medium";
    default:
      return "low";
  }
}

function mapBanditSeverity(s: string): Severity {
  switch ((s || "").toUpperCase()) {
    case "HIGH":
      return "high";
    case "MEDIUM":
      return "medium";
    default:
      return "low";
  }
}

export interface EngineStatus {
  name: string;
  available: boolean;
  ran: boolean;
  note?: string;
  findingCount: number;
}

export interface ScanResult {
  findings: CodeFinding[];
  engines: EngineStatus[];
  summary: { total: number; bySeverity: Record<Severity, number> };
}

function extFor(language?: string): string {
  switch ((language || "").toLowerCase()) {
    case "python":
    case "py":
      return ".py";
    case "ts":
    case "typescript":
      return ".ts";
    case "tsx":
      return ".tsx";
    case "jsx":
      return ".jsx";
    default:
      return ".js";
  }
}

export async function deepScan(
  code: string,
  language?: string
): Promise<ScanResult> {
  // Built-in heuristics always run.
  const heuristic = reviewCode(code);
  const findings: CodeFinding[] = [...heuristic.findings];

  // Built-in secrets scanner always runs.
  const secrets = scanSecrets(code).map((f) => ({
    ...f,
    ...mapCompliance(f.title),
  }));
  findings.push(...secrets);

  const engines: EngineStatus[] = [
    {
      name: "horus-heuristics",
      available: true,
      ran: true,
      findingCount: heuristic.findings.length,
    },
    {
      name: "secrets-scanner",
      available: true,
      ran: true,
      findingCount: secrets.length,
    },
  ];

  if (!config.engines.enabled) {
    return finalize(findings, engines);
  }

  // Temp file in the workspace for the external scanners.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "horus-scan-"));
  const file = path.join(dir, `snippet${extFor(language)}`);
  fs.writeFileSync(file, code, "utf8");

  try {
    // ---- semgrep ----
    const hasSemgrep = await which("semgrep");
    if (hasSemgrep) {
      const r = await run("semgrep", ["--json", "--quiet", "--config", "auto", file], dir);
      let count = 0;
      try {
        const parsed = JSON.parse(r.stdout || "{}");
        for (const res of parsed.results ?? []) {
          count++;
          findings.push({
            id: `semgrep-${res.check_id}-${res.start?.line ?? 0}`,
            title: `semgrep: ${res.extra?.message ?? res.check_id}`,
            severity: mapSemgrepSeverity(res.extra?.severity),
            line: res.start?.line ?? 0,
            snippet: (res.extra?.lines ?? "").toString().trim().slice(0, 200),
            why: res.extra?.message ?? "Flagged by semgrep ruleset.",
            fix:
              res.extra?.metadata?.references?.[0] ??
              "See semgrep rule guidance for the secure fix.",
          });
        }
      } catch {
        /* ignore parse error */
      }
      engines.push({
        name: "semgrep",
        available: true,
        ran: true,
        findingCount: count,
      });
    } else {
      engines.push({
        name: "semgrep",
        available: false,
        ran: false,
        note: "Not installed — `pip install semgrep` to enable.",
        findingCount: 0,
      });
    }

    // ---- bandit (python only) ----
    const isPython = extFor(language) === ".py";
    if (isPython) {
      const hasBandit = await which("bandit");
      if (hasBandit) {
        const r = await run("bandit", ["-f", "json", file], dir);
        let count = 0;
        try {
          const parsed = JSON.parse(r.stdout || "{}");
          for (const res of parsed.results ?? []) {
            count++;
            findings.push({
              id: `bandit-${res.test_id}-${res.line_number}`,
              title: `bandit: ${res.test_name}`,
              severity: mapBanditSeverity(res.issue_severity),
              line: res.line_number ?? 0,
              snippet: (res.code ?? "").toString().trim().slice(0, 200),
              why: res.issue_text ?? "Flagged by bandit.",
              fix: res.more_info ?? "See bandit guidance for the secure fix.",
            });
          }
        } catch {
          /* ignore */
        }
        engines.push({ name: "bandit", available: true, ran: true, findingCount: count });
      } else {
        engines.push({
          name: "bandit",
          available: false,
          ran: false,
          note: "Not installed — `pip install bandit` to enable.",
          findingCount: 0,
        });
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }

  return finalize(findings, engines);
}

function finalize(findings: CodeFinding[], engines: EngineStatus[]): ScanResult {
  const bySeverity: Record<Severity, number> = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
    info: 0,
  };
  for (const f of findings) bySeverity[f.severity]++;
  return { findings, engines, summary: { total: findings.length, bySeverity } };
}

export interface DepAuditResult {
  available: boolean;
  ran: boolean;
  note?: string;
  vulnerabilities: { name: string; severity: string; title?: string }[];
  totals: Record<string, number>;
}

/** Run `npm audit --json` in the sandboxed workspace (if it has a package.json). */
export async function auditDependencies(): Promise<DepAuditResult> {
  const cwd = config.commandRunner.workspace;
  if (!fs.existsSync(path.join(cwd, "package.json"))) {
    return {
      available: true,
      ran: false,
      note: "No package.json in the workspace. Place a Node project in the workspace to audit its dependencies.",
      vulnerabilities: [],
      totals: {},
    };
  }
  const r = await run("npm", ["audit", "--json"], cwd);
  try {
    const parsed = JSON.parse(r.stdout || "{}");
    const vulns: { name: string; severity: string; title?: string }[] = [];
    for (const [name, info] of Object.entries<any>(parsed.vulnerabilities ?? {})) {
      vulns.push({
        name,
        severity: info.severity,
        title: Array.isArray(info.via)
          ? info.via.find((v: any) => typeof v === "object")?.title
          : undefined,
      });
    }
    return {
      available: true,
      ran: true,
      vulnerabilities: vulns,
      totals: parsed.metadata?.vulnerabilities ?? {},
    };
  } catch (e) {
    return {
      available: true,
      ran: false,
      note: `Could not parse npm audit output: ${e instanceof Error ? e.message : "error"}`,
      vulnerabilities: [],
      totals: {},
    };
  }
}
