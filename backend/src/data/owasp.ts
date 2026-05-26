/**
 * owasp.ts — OWASP Top 10 (2021) knowledge base used to generate checklists
 * and audit guidance. Defensive / educational content only.
 */

export interface ChecklistItem {
  id: string;
  title: string;
  description: string;
  checks: string[];
  remediation: string[];
  severityHint: "critical" | "high" | "medium" | "low" | "info";
}

export const OWASP_TOP_10: ChecklistItem[] = [
  {
    id: "A01",
    title: "Broken Access Control",
    description:
      "Users can act outside their intended permissions — IDOR, missing function-level checks, forced browsing.",
    severityHint: "high",
    checks: [
      "Try accessing another user's resource by changing an ID in the URL/body (on your own test accounts).",
      "Confirm server-side authorization on every sensitive endpoint, not just the UI.",
      "Verify role checks cannot be bypassed by manipulating request fields.",
      "Check that direct object references map to the authenticated user.",
    ],
    remediation: [
      "Enforce authorization server-side on every request; deny by default.",
      "Use indirect references or ownership checks for object access.",
      "Centralize access-control logic; add automated tests for each role.",
    ],
  },
  {
    id: "A02",
    title: "Cryptographic Failures",
    description:
      "Sensitive data exposed due to weak/absent encryption, in transit or at rest.",
    severityHint: "high",
    checks: [
      "Confirm TLS is enforced (HSTS) and weak ciphers are disabled.",
      "Check that passwords are hashed with bcrypt/scrypt/argon2, never plaintext or MD5/SHA1.",
      "Verify secrets/keys are not hardcoded or logged.",
      "Confirm sensitive fields are encrypted at rest where required.",
    ],
    remediation: [
      "Enforce HTTPS everywhere with HSTS; disable legacy TLS.",
      "Use a modern password hash (argon2id/bcrypt) with per-user salt.",
      "Store secrets in a vault / environment, never in source.",
    ],
  },
  {
    id: "A03",
    title: "Injection",
    description:
      "Untrusted data is interpreted as code/queries — SQLi, NoSQLi, command, LDAP injection.",
    severityHint: "critical",
    checks: [
      "Test input fields with safe canary payloads on your own lab to spot reflected query errors.",
      "Confirm all DB access uses parameterized queries / prepared statements.",
      "Check that OS commands are never built from user input.",
      "Validate and allowlist input where structure is known.",
    ],
    remediation: [
      "Use parameterized queries / ORM bindings exclusively.",
      "Validate input against strict allowlists; encode on output.",
      "Avoid shelling out with user input; use safe APIs.",
    ],
  },
  {
    id: "A04",
    title: "Insecure Design",
    description:
      "Missing or ineffective security controls by design (no threat modeling, no rate limits).",
    severityHint: "medium",
    checks: [
      "Confirm critical flows (password reset, payment) have abuse protections.",
      "Check for rate limiting / lockout on auth endpoints.",
      "Review whether a threat model exists for the feature.",
    ],
    remediation: [
      "Threat model new features; define abuse cases and trust boundaries.",
      "Add rate limiting, lockouts, and secure defaults.",
    ],
  },
  {
    id: "A05",
    title: "Security Misconfiguration",
    description:
      "Default creds, verbose errors, open cloud storage, missing security headers.",
    severityHint: "high",
    checks: [
      "Check for missing security headers (CSP, X-Content-Type-Options, etc.).",
      "Confirm verbose stack traces are disabled in production.",
      "Look for default credentials and unnecessary open ports/services.",
      "Review CORS configuration for over-permissive origins.",
    ],
    remediation: [
      "Add a strict baseline of security headers (helmet).",
      "Disable debug output in production; harden defaults.",
      "Scope CORS to known origins; remove unused services.",
    ],
  },
  {
    id: "A06",
    title: "Vulnerable and Outdated Components",
    description: "Using libraries with known CVEs or no patch process.",
    severityHint: "medium",
    checks: [
      "Run `npm audit` / dependency scanning on your project.",
      "Confirm a process exists to track and update dependencies.",
      "Remove unused dependencies.",
    ],
    remediation: [
      "Patch known-vulnerable packages; pin and monitor versions.",
      "Automate dependency scanning in CI.",
    ],
  },
  {
    id: "A07",
    title: "Identification and Authentication Failures",
    description:
      "Weak credentials, broken session handling, missing MFA, credential stuffing exposure.",
    severityHint: "high",
    checks: [
      "Confirm session tokens rotate on login and invalidate on logout.",
      "Check password policy and breached-password rejection.",
      "Verify MFA is available for sensitive accounts.",
      "Confirm cookies use HttpOnly, Secure, SameSite.",
    ],
    remediation: [
      "Offer/require MFA; enforce strong session management.",
      "Set HttpOnly/Secure/SameSite on session cookies.",
      "Add rate limiting and lockout for auth.",
    ],
  },
  {
    id: "A08",
    title: "Software and Data Integrity Failures",
    description:
      "Insecure deserialization, unsigned updates, untrusted CI/CD or plugins.",
    severityHint: "medium",
    checks: [
      "Confirm updates/packages are integrity-checked (lockfiles, signatures).",
      "Review deserialization of untrusted data.",
      "Audit CI/CD pipeline trust and secrets handling.",
    ],
    remediation: [
      "Verify integrity of artifacts; use signed packages and lockfiles.",
      "Avoid deserializing untrusted data; use safe formats.",
    ],
  },
  {
    id: "A09",
    title: "Security Logging and Monitoring Failures",
    description: "Insufficient logging/alerting delays breach detection.",
    severityHint: "medium",
    checks: [
      "Confirm auth events, failures, and admin actions are logged.",
      "Check that logs exclude secrets and are tamper-resistant.",
      "Verify alerting exists for suspicious patterns.",
    ],
    remediation: [
      "Log security-relevant events with context; centralize and protect logs.",
      "Add alerting on anomalies (e.g. brute force, privilege change).",
    ],
  },
  {
    id: "A10",
    title: "Server-Side Request Forgery (SSRF)",
    description:
      "The server fetches a user-supplied URL, enabling access to internal resources.",
    severityHint: "high",
    checks: [
      "Identify features that fetch remote URLs from user input.",
      "Confirm internal/metadata endpoints are blocked from such fetches.",
      "Check URL validation and allowlisting.",
    ],
    remediation: [
      "Allowlist destinations; block private/metadata IP ranges.",
      "Disable unused URL schemes and follow-redirect behavior.",
    ],
  },
];

export const SECURITY_HEADERS = [
  {
    header: "Content-Security-Policy",
    purpose: "Mitigates XSS by controlling which resources can load.",
    example: "default-src 'self'; object-src 'none'; frame-ancestors 'none'",
  },
  {
    header: "Strict-Transport-Security",
    purpose: "Forces HTTPS for future requests.",
    example: "max-age=63072000; includeSubDomains; preload",
  },
  {
    header: "X-Content-Type-Options",
    purpose: "Stops MIME-sniffing.",
    example: "nosniff",
  },
  {
    header: "X-Frame-Options",
    purpose: "Prevents clickjacking (legacy; prefer CSP frame-ancestors).",
    example: "DENY",
  },
  {
    header: "Referrer-Policy",
    purpose: "Limits referrer leakage.",
    example: "strict-origin-when-cross-origin",
  },
  {
    header: "Permissions-Policy",
    purpose: "Disables unused browser features.",
    example: "geolocation=(), camera=(), microphone=()",
  },
];
