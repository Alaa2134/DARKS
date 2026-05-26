import { Router } from "express";
import {
  insertFinding,
  listFindings,
  deleteFinding,
  clearFindings,
  insertReport,
  listReports,
  getReport,
  listSafetyLog,
  safetyStats,
  type DbFinding,
} from "../db/database";
import { retrieve } from "../knowledge/retriever";

export const dataRouter = Router();

// ---- Findings persistence ----

dataRouter.get("/findings", (_req, res) => {
  res.json({ findings: listFindings() });
});

dataRouter.post("/findings", (req, res) => {
  const b = req.body ?? {};
  if (!b.title || !b.severity || !b.description) {
    return res.status(400).json({ error: "title, severity, description required" });
  }
  const f = insertFinding({
    title: String(b.title),
    severity: b.severity,
    description: String(b.description),
    impact: b.impact ?? null,
    remediation: b.remediation ?? null,
    evidence: b.evidence ?? null,
    source: b.source ?? "manual",
  } as Omit<DbFinding, "id" | "created_at">);
  res.json({ finding: f });
});

dataRouter.delete("/findings/:id", (req, res) => {
  deleteFinding(Number(req.params.id));
  res.json({ ok: true });
});

dataRouter.delete("/findings", (_req, res) => {
  clearFindings();
  res.json({ ok: true });
});

// ---- Reports persistence ----

dataRouter.get("/reports", (_req, res) => {
  res.json({ reports: listReports() });
});

dataRouter.get("/reports/:id", (req, res) => {
  const r = getReport(Number(req.params.id));
  if (!r) return res.status(404).json({ error: "not found" });
  res.json({ report: r });
});

dataRouter.post("/reports", (req, res) => {
  const b = req.body ?? {};
  if (!b.title || !b.markdown) {
    return res.status(400).json({ error: "title and markdown required" });
  }
  const r = insertReport({
    title: String(b.title),
    client: b.client ?? null,
    markdown: String(b.markdown),
    finding_count: Number(b.finding_count ?? 0),
  });
  res.json({ report: r });
});

// ---- Safety audit log ----

dataRouter.get("/safety/log", (_req, res) => {
  res.json({ entries: listSafetyLog(100), stats: safetyStats() });
});

// ---- Knowledge base search (RAG) ----

dataRouter.get("/kb/search", (req, res) => {
  const q = typeof req.query.q === "string" ? req.query.q : "";
  if (!q.trim()) return res.json({ results: [] });
  res.json({ results: retrieve(q, Number(req.query.k) || 5) });
});
