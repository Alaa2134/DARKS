/**
 * database.ts
 * ----------------------------------------------------------------------------
 * Lightweight persistence using Node's built-in SQLite (node:sqlite), so there
 * are no native build dependencies. Stores findings, generated reports, and a
 * safety-decision audit log (every refusal is recorded for transparency).
 */

import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import fs from "node:fs";
import { config } from "../config";
import type { Severity } from "../services/codeReview";

const dbPath = config.db.path;
fs.mkdirSync(path.dirname(dbPath), { recursive: true });

export const db = new DatabaseSync(dbPath);

db.exec(`
  CREATE TABLE IF NOT EXISTS findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    severity TEXT NOT NULL,
    description TEXT NOT NULL,
    impact TEXT,
    remediation TEXT,
    evidence TEXT,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    client TEXT,
    markdown TEXT NOT NULL,
    finding_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS safety_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    decision TEXT NOT NULL,
    category TEXT,
    reason TEXT,
    excerpt TEXT,
    context TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

// ---- Findings ----

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

export function insertFinding(f: Omit<DbFinding, "id" | "created_at">): DbFinding {
  const stmt = db.prepare(
    `INSERT INTO findings (title, severity, description, impact, remediation, evidence, source)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  );
  const info = stmt.run(
    f.title,
    f.severity,
    f.description,
    f.impact ?? null,
    f.remediation ?? null,
    f.evidence ?? null,
    f.source
  );
  return getFinding(Number(info.lastInsertRowid))!;
}

export function getFinding(id: number): DbFinding | undefined {
  return db.prepare(`SELECT * FROM findings WHERE id = ?`).get(id) as
    | unknown as DbFinding | undefined;
}

export function listFindings(): DbFinding[] {
  return db
    .prepare(`SELECT * FROM findings ORDER BY id DESC`)
    .all() as unknown as DbFinding[];
}

export function deleteFinding(id: number): void {
  db.prepare(`DELETE FROM findings WHERE id = ?`).run(id);
}

export function clearFindings(): void {
  db.exec(`DELETE FROM findings`);
}

// ---- Reports ----

export interface DbReport {
  id: number;
  title: string;
  client?: string | null;
  markdown: string;
  finding_count: number;
  created_at: string;
}

export function insertReport(
  r: Omit<DbReport, "id" | "created_at">
): DbReport {
  const info = db
    .prepare(
      `INSERT INTO reports (title, client, markdown, finding_count) VALUES (?, ?, ?, ?)`
    )
    .run(r.title, r.client ?? null, r.markdown, r.finding_count);
  return db
    .prepare(`SELECT * FROM reports WHERE id = ?`)
    .get(Number(info.lastInsertRowid)) as unknown as DbReport;
}

export function listReports(): Omit<DbReport, "markdown">[] {
  return db
    .prepare(
      `SELECT id, title, client, finding_count, created_at FROM reports ORDER BY id DESC`
    )
    .all() as unknown as Omit<DbReport, "markdown">[];
}

export function getReport(id: number): DbReport | undefined {
  return db.prepare(`SELECT * FROM reports WHERE id = ?`).get(id) as
    | unknown as DbReport | undefined;
}

// ---- Safety audit log ----

export interface DbSafetyLog {
  id: number;
  decision: string;
  category?: string | null;
  reason?: string | null;
  excerpt?: string | null;
  context?: string | null;
  created_at: string;
}

export function logSafety(entry: {
  decision: string;
  category?: string;
  reason?: string;
  excerpt?: string;
  context?: string;
}): void {
  db.prepare(
    `INSERT INTO safety_log (decision, category, reason, excerpt, context) VALUES (?, ?, ?, ?, ?)`
  ).run(
    entry.decision,
    entry.category ?? null,
    entry.reason ?? null,
    (entry.excerpt ?? "").slice(0, 280),
    entry.context ?? null
  );
}

export function listSafetyLog(limit = 100): DbSafetyLog[] {
  return db
    .prepare(`SELECT * FROM safety_log ORDER BY id DESC LIMIT ?`)
    .all(limit) as unknown as DbSafetyLog[];
}

export function dashboardStats(): {
  findingsBySeverity: Record<string, number>;
  totalFindings: number;
  totalReports: number;
  refusals: number;
} {
  const rows = db
    .prepare(`SELECT severity, COUNT(*) c FROM findings GROUP BY severity`)
    .all() as unknown as { severity: string; c: number }[];
  const findingsBySeverity: Record<string, number> = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
    info: 0,
  };
  let totalFindings = 0;
  for (const r of rows) {
    findingsBySeverity[r.severity] = r.c;
    totalFindings += r.c;
  }
  const totalReports = (
    db.prepare(`SELECT COUNT(*) c FROM reports`).get() as unknown as { c: number }
  ).c;
  const refusals = (
    db
      .prepare(`SELECT COUNT(*) c FROM safety_log WHERE decision = 'refuse'`)
      .get() as unknown as { c: number }
  ).c;
  return { findingsBySeverity, totalFindings, totalReports, refusals };
}

export function safetyStats(): {
  total: number;
  refusals: number;
  byCategory: { category: string; count: number }[];
} {
  const total = (
    db.prepare(`SELECT COUNT(*) c FROM safety_log`).get() as unknown as { c: number }
  ).c;
  const refusals = (
    db
      .prepare(`SELECT COUNT(*) c FROM safety_log WHERE decision = 'refuse'`)
      .get() as unknown as { c: number }
  ).c;
  const byCategory = db
    .prepare(
      `SELECT category, COUNT(*) count FROM safety_log
       WHERE decision = 'refuse' AND category IS NOT NULL
       GROUP BY category ORDER BY count DESC`
    )
    .all() as unknown as { category: string; count: number }[];
  return { total, refusals, byCategory };
}
