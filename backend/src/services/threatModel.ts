/**
 * threatModel.ts — generates a STRIDE threat model from a described system.
 * Defensive design aid: maps components to likely threat categories with
 * mitigations. Heuristic + knowledge-driven (no attack instructions).
 */

import type { Severity } from "./codeReview";

export interface ThreatModelInput {
  system: string;
  components?: string[];
}

export interface Threat {
  category:
    | "Spoofing"
    | "Tampering"
    | "Repudiation"
    | "Information Disclosure"
    | "Denial of Service"
    | "Elevation of Privilege";
  component: string;
  threat: string;
  mitigation: string;
  severityHint: Severity;
}

const STRIDE: {
  category: Threat["category"];
  match: RegExp;
  threat: string;
  mitigation: string;
  severityHint: Severity;
}[] = [
  {
    category: "Spoofing",
    match: /login|auth|user|account|session|api|token|oauth|sso/i,
    threat: "An attacker impersonates a legitimate user or service identity.",
    mitigation: "Strong authentication + MFA, signed/short-lived tokens, mutual TLS for services.",
    severityHint: "high",
  },
  {
    category: "Tampering",
    match: /database|db|store|file|upload|config|message|queue|cache/i,
    threat: "Data in transit or at rest is modified without authorization.",
    mitigation: "Integrity checks, parameterized writes, signed messages, least-privilege access, TLS.",
    severityHint: "high",
  },
  {
    category: "Repudiation",
    match: /transaction|payment|admin|action|order|log/i,
    threat: "A user denies performing an action and there is no reliable record.",
    mitigation: "Tamper-evident audit logging of security-relevant actions with user/context.",
    severityHint: "medium",
  },
  {
    category: "Information Disclosure",
    match: /api|database|file|user|pii|secret|report|email|profile|search/i,
    threat: "Sensitive data is exposed to unauthorized parties.",
    mitigation: "Authorization on every read, encryption at rest/in transit, minimize data, scrub errors/logs.",
    severityHint: "high",
  },
  {
    category: "Denial of Service",
    match: /api|endpoint|upload|search|queue|public|gateway/i,
    threat: "A component is overwhelmed, degrading availability.",
    mitigation: "Rate limiting, quotas, timeouts, autoscaling, and input size limits.",
    severityHint: "medium",
  },
  {
    category: "Elevation of Privilege",
    match: /admin|role|permission|auth|api|account|access control/i,
    threat: "A lower-privileged actor gains higher privileges.",
    mitigation: "Server-side authorization, deny-by-default, RBAC, validate role on every sensitive op.",
    severityHint: "critical",
  },
];

export interface ThreatModelResult {
  system: string;
  components: string[];
  threats: Threat[];
  trustBoundaries: string[];
}

export function generateThreatModel(input: ThreatModelInput): ThreatModelResult {
  const text = `${input.system} ${(input.components ?? []).join(" ")}`;
  const components =
    input.components && input.components.length
      ? input.components
      : extractComponents(text);

  const threats: Threat[] = [];
  for (const comp of components) {
    for (const rule of STRIDE) {
      if (rule.match.test(comp) || rule.match.test(input.system)) {
        threats.push({
          category: rule.category,
          component: comp,
          threat: rule.threat,
          mitigation: rule.mitigation,
          severityHint: rule.severityHint,
        });
      }
    }
  }

  // De-duplicate identical (category, component) pairs.
  const seen = new Set<string>();
  const deduped = threats.filter((t) => {
    const k = `${t.category}|${t.component}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });

  return {
    system: input.system,
    components,
    threats: deduped,
    trustBoundaries: [
      "Untrusted client ↔ application (validate all input here)",
      "Application ↔ data store (authorize + parameterize)",
      "Application ↔ third-party/external services (verify + least privilege)",
    ],
  };
}

function extractComponents(text: string): string[] {
  const keywords = [
    "frontend", "client", "api", "backend", "database", "auth",
    "file upload", "payment", "admin", "cache", "queue", "gateway",
  ];
  const found = keywords.filter((k) => new RegExp(k, "i").test(text));
  return found.length ? found : ["frontend", "api", "database"];
}
