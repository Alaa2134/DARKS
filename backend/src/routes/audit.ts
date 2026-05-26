import { Router } from "express";
import { evaluateTarget } from "../safety/safetyFilter";
import { OWASP_TOP_10, SECURITY_HEADERS } from "../data/owasp";

export const auditRouter = Router();

/** GET /api/audit/checklist — full OWASP Top 10 checklist data. */
auditRouter.get("/checklist", (_req, res) => {
  res.json({ items: OWASP_TOP_10 });
});

/** GET /api/audit/headers — recommended security headers. */
auditRouter.get("/headers", (_req, res) => {
  res.json({ headers: SECURITY_HEADERS });
});

/**
 * POST /api/audit/scope-check
 * body: { target: string, confirmedScope?: string[] }
 * Validates that a target is local/private or in confirmed ownership scope.
 */
auditRouter.post("/scope-check", (req, res) => {
  const target = typeof req.body?.target === "string" ? req.body.target : "";
  const confirmedScope: string[] = Array.isArray(req.body?.confirmedScope)
    ? req.body.confirmedScope.filter((s: any) => typeof s === "string")
    : [];

  if (!target.trim()) {
    return res.status(400).json({ error: "target is required" });
  }

  const result = evaluateTarget(target, confirmedScope);
  res.json(result);
});
