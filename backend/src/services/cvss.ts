/**
 * cvss.ts — CVSS v3.1 Base Score calculator. Pure function implementation of
 * the FIRST.org specification. Used to score findings consistently.
 */

import type { Severity } from "./codeReview";

export interface CvssMetrics {
  AV: "N" | "A" | "L" | "P"; // Attack Vector
  AC: "L" | "H"; // Attack Complexity
  PR: "N" | "L" | "H"; // Privileges Required
  UI: "N" | "R"; // User Interaction
  S: "U" | "C"; // Scope
  C: "N" | "L" | "H"; // Confidentiality
  I: "N" | "L" | "H"; // Integrity
  A: "N" | "L" | "H"; // Availability
}

const AV = { N: 0.85, A: 0.62, L: 0.55, P: 0.2 };
const AC = { L: 0.77, H: 0.44 };
const PR_U = { N: 0.85, L: 0.62, H: 0.27 };
const PR_C = { N: 0.85, L: 0.68, H: 0.5 };
const UI = { N: 0.85, R: 0.62 };
const CIA = { N: 0, L: 0.22, H: 0.56 };

export interface CvssResult {
  baseScore: number;
  severity: Severity;
  vector: string;
}

function roundUp1(n: number): number {
  return Math.ceil(n * 10) / 10;
}

export function severityFromScore(score: number): Severity {
  if (score === 0) return "info";
  if (score < 4) return "low";
  if (score < 7) return "medium";
  if (score < 9) return "high";
  return "critical";
}

export function computeCvss(m: CvssMetrics): CvssResult {
  const iss = 1 - (1 - CIA[m.C]) * (1 - CIA[m.I]) * (1 - CIA[m.A]);
  const impact =
    m.S === "U"
      ? 6.42 * iss
      : 7.52 * (iss - 0.029) - 3.25 * Math.pow(iss - 0.02, 15);
  const pr = m.S === "C" ? PR_C[m.PR] : PR_U[m.PR];
  const exploitability = 8.22 * AV[m.AV] * AC[m.AC] * pr * UI[m.UI];

  let base: number;
  if (impact <= 0) {
    base = 0;
  } else if (m.S === "U") {
    base = roundUp1(Math.min(impact + exploitability, 10));
  } else {
    base = roundUp1(Math.min(1.08 * (impact + exploitability), 10));
  }

  const vector = `CVSS:3.1/AV:${m.AV}/AC:${m.AC}/PR:${m.PR}/UI:${m.UI}/S:${m.S}/C:${m.C}/I:${m.I}/A:${m.A}`;
  return { baseScore: base, severity: severityFromScore(base), vector };
}

const VECTOR_RE =
  /AV:([NALP]).*AC:([LH]).*PR:([NLH]).*UI:([NR]).*S:([UC]).*C:([NLH]).*I:([NLH]).*A:([NLH])/;

export function parseVector(vector: string): CvssMetrics | null {
  const m = vector.toUpperCase().match(VECTOR_RE);
  if (!m) return null;
  return {
    AV: m[1] as CvssMetrics["AV"],
    AC: m[2] as CvssMetrics["AC"],
    PR: m[3] as CvssMetrics["PR"],
    UI: m[4] as CvssMetrics["UI"],
    S: m[5] as CvssMetrics["S"],
    C: m[6] as CvssMetrics["C"],
    I: m[7] as CvssMetrics["I"],
    A: m[8] as CvssMetrics["A"],
  };
}
