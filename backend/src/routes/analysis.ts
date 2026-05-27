import { Router } from "express";
import { reviewCode } from "../services/codeReview";
import { analyzeLogs } from "../services/logAnalyzer";
import { generateReport, type ReportInput } from "../services/reportGenerator";
import { deepScan, auditDependencies } from "../services/scanEngines";
import { computeCvss, parseVector, type CvssMetrics } from "../services/cvss";
import { generateThreatModel } from "../services/threatModel";
import { evaluateText } from "../safety/safetyFilter";

export const analysisRouter = Router();

/** POST /api/analysis/cvss — body: { vector } or { metrics }. */
analysisRouter.post("/cvss", (req, res) => {
  const b = req.body ?? {};
  let metrics: CvssMetrics | null = null;
  if (typeof b.vector === "string") {
    metrics = parseVector(b.vector);
    if (!metrics) return res.status(400).json({ error: "invalid CVSS vector" });
  } else if (b.metrics && typeof b.metrics === "object") {
    metrics = b.metrics as CvssMetrics;
  }
  if (!metrics) return res.status(400).json({ error: "provide vector or metrics" });
  res.json(computeCvss(metrics));
});

/** POST /api/analysis/threat-model — body: { system, components? }. */
analysisRouter.post("/threat-model", (req, res) => {
  const system = typeof req.body?.system === "string" ? req.body.system : "";
  if (!system.trim()) return res.status(400).json({ error: "system is required" });
  const safety = evaluateText(system);
  if (!safety.allowed) {
    return res.status(400).json({ error: "Input failed the safety check.", safety });
  }
  const components = Array.isArray(req.body?.components)
    ? req.body.components.filter((c: unknown) => typeof c === "string")
    : undefined;
  res.json(generateThreatModel({ system, components }));
});

/** POST /api/analysis/scan — deep scan: heuristics + optional semgrep/bandit. */
analysisRouter.post("/scan", async (req, res) => {
  const code = typeof req.body?.code === "string" ? req.body.code : "";
  const language = typeof req.body?.language === "string" ? req.body.language : undefined;
  if (!code.trim()) {
    return res.status(400).json({ error: "code is required" });
  }
  res.json(await deepScan(code, language));
});

/** POST /api/analysis/audit-deps — run npm audit in the sandboxed workspace. */
analysisRouter.post("/audit-deps", async (_req, res) => {
  res.json(await auditDependencies());
});

/** POST /api/analysis/code-review — body: { code: string } */
analysisRouter.post("/code-review", (req, res) => {
  const code = typeof req.body?.code === "string" ? req.body.code : "";
  if (!code.trim()) {
    return res.status(400).json({ error: "code is required" });
  }
  res.json(reviewCode(code));
});

/** POST /api/analysis/logs — body: { log: string } */
analysisRouter.post("/logs", (req, res) => {
  const log = typeof req.body?.log === "string" ? req.body.log : "";
  if (!log.trim()) {
    return res.status(400).json({ error: "log is required" });
  }
  res.json(analyzeLogs(log));
});

/** POST /api/analysis/report — body: ReportInput */
analysisRouter.post("/report", (req, res) => {
  const body = req.body ?? {};
  if (!Array.isArray(body.findings)) {
    return res.status(400).json({ error: "findings array is required" });
  }

  // Defensive: the report is generated from structured data, but still scan
  // free-text fields so the tool can never be used to launder harmful content.
  const blob = JSON.stringify(body);
  const safety = evaluateText(blob);
  if (!safety.allowed) {
    return res.status(400).json({ error: "Report content failed the safety check.", safety });
  }

  const markdown = generateReport(body as ReportInput);
  res.json({ markdown });
});
