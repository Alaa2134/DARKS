import { Router } from "express";
import { reviewCode } from "../services/codeReview";
import { analyzeLogs } from "../services/logAnalyzer";
import { generateReport, type ReportInput } from "../services/reportGenerator";
import { evaluateText } from "../safety/safetyFilter";

export const analysisRouter = Router();

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
