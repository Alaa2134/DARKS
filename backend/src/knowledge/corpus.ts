/**
 * corpus.ts — curated, defensive security knowledge used for grounded answers
 * (RAG). Each doc has a stable id used for citations. Content is educational
 * and remediation-focused only.
 */

export interface KnowledgeDoc {
  id: string;
  title: string;
  tags: string[];
  source: string;
  text: string;
}

export const KNOWLEDGE: KnowledgeDoc[] = [
  {
    id: "owasp-a01-access-control",
    title: "OWASP A01 — Broken Access Control",
    tags: ["owasp", "access control", "idor", "authorization", "web"],
    source: "OWASP Top 10 (2021)",
    text: "Broken access control lets users act outside intended permissions: IDOR (changing an id to access another user's object), missing function-level authorization, and forced browsing. Defend by enforcing authorization server-side on every request, denying by default, checking object ownership, centralizing access-control logic, and adding automated tests per role.",
  },
  {
    id: "owasp-a02-crypto",
    title: "OWASP A02 — Cryptographic Failures",
    tags: ["owasp", "crypto", "tls", "hashing", "passwords"],
    source: "OWASP Top 10 (2021)",
    text: "Sensitive data is exposed via weak or missing encryption. Enforce TLS with HSTS, disable weak ciphers, hash passwords with argon2id/bcrypt/scrypt (never MD5/SHA1 or plaintext), keep secrets out of source and logs, and encrypt sensitive data at rest.",
  },
  {
    id: "owasp-a03-injection",
    title: "OWASP A03 — Injection (SQLi, command, etc.)",
    tags: ["owasp", "injection", "sql", "sqli", "command injection", "web"],
    source: "OWASP Top 10 (2021)",
    text: "Injection happens when untrusted data is interpreted as code or query. SQL injection is fixed with parameterized queries / prepared statements and ORM bindings — never string concatenation. For OS commands, avoid the shell and pass argument arrays; validate input against allowlists and encode on output.",
  },
  {
    id: "owasp-a05-misconfig",
    title: "OWASP A05 — Security Misconfiguration",
    tags: ["owasp", "headers", "cors", "configuration", "hardening"],
    source: "OWASP Top 10 (2021)",
    text: "Misconfiguration includes default credentials, verbose errors, open storage, and missing security headers. Apply a baseline of headers (CSP, HSTS, X-Content-Type-Options, Referrer-Policy, Permissions-Policy), disable debug output in production, scope CORS to known origins, and remove unused services.",
  },
  {
    id: "owasp-a07-auth",
    title: "OWASP A07 — Authentication Failures",
    tags: ["owasp", "auth", "session", "mfa", "cookies", "brute force"],
    source: "OWASP Top 10 (2021)",
    text: "Weak credentials and broken session handling enable account takeover. Offer/require MFA, rotate session tokens on login, invalidate on logout, set cookies HttpOnly/Secure/SameSite, reject breached passwords, and add rate limiting plus lockout to resist brute force and credential stuffing.",
  },
  {
    id: "owasp-a10-ssrf",
    title: "OWASP A10 — Server-Side Request Forgery (SSRF)",
    tags: ["owasp", "ssrf", "web", "url fetch"],
    source: "OWASP Top 10 (2021)",
    text: "SSRF occurs when a server fetches a user-supplied URL, reaching internal resources or cloud metadata. Defend by allowlisting destinations, blocking private/metadata IP ranges (169.254.169.254, RFC1918), disabling unused URL schemes, and not following redirects to internal hosts.",
  },
  {
    id: "xss",
    title: "Cross-Site Scripting (XSS) and defenses",
    tags: ["xss", "web", "csp", "encoding", "dom"],
    source: "OWASP / CWE-79",
    text: "XSS injects attacker-controlled script into a page (stored, reflected, or DOM-based). Defend by contextual output encoding, treating data as text (textContent / JSX children) rather than HTML, sanitizing rich HTML with a vetted library (DOMPurify), avoiding innerHTML/document.write/eval, and deploying a strong Content-Security-Policy.",
  },
  {
    id: "csrf",
    title: "Cross-Site Request Forgery (CSRF)",
    tags: ["csrf", "web", "cookies", "tokens"],
    source: "OWASP / CWE-352",
    text: "CSRF tricks a logged-in user's browser into making an unwanted state-changing request. Defend with anti-CSRF tokens (synchronizer or double-submit), SameSite=Lax/Strict cookies, and verifying Origin/Referer for sensitive actions.",
  },
  {
    id: "secrets-management",
    title: "Secrets management",
    tags: ["secrets", "api key", "credentials", "config", "vault"],
    source: "Secure coding guidance",
    text: "Never hardcode secrets (API keys, passwords, tokens) in source — they leak via version control and bundles. Load them from environment variables or a secrets manager/vault, rotate any committed secret immediately, and add secret scanning to CI to prevent regressions.",
  },
  {
    id: "file-upload",
    title: "Insecure file upload",
    tags: ["upload", "web", "validation", "path traversal"],
    source: "OWASP File Upload Cheat Sheet",
    text: "Unrestricted file upload can lead to RCE or stored XSS. Validate file type by content (not just extension), restrict size, store outside the web root with generated names, never execute uploaded files, and scan where possible. Avoid using user input directly in file paths to prevent path traversal.",
  },
  {
    id: "dependency-mgmt",
    title: "Vulnerable and outdated components",
    tags: ["dependencies", "cve", "npm audit", "supply chain"],
    source: "OWASP A06",
    text: "Known-vulnerable libraries are a common breach vector. Run dependency scanning (npm audit, etc.) in CI, pin and monitor versions, remove unused dependencies, and patch promptly. Verify artifact integrity with lockfiles and signatures.",
  },
  {
    id: "logging-monitoring",
    title: "Security logging and monitoring",
    tags: ["logging", "monitoring", "detection", "blue team"],
    source: "OWASP A09",
    text: "Insufficient logging delays breach detection. Log authentication events, failures, and admin actions with context, exclude secrets, protect logs from tampering, centralize them, and alert on suspicious patterns such as brute-force bursts or privilege changes.",
  },
  {
    id: "ctf-web-method",
    title: "CTF web exploitation methodology",
    tags: ["ctf", "web", "methodology"],
    source: "CTF methodology",
    text: "For a CTF web challenge: map pages/endpoints/parameters and the tech stack, read client-side code and comments for hints, test input handling for injection/IDOR/auth-logic flaws, inspect cookies and JWTs and access control between roles, and document the path from observation to flag. Work only against the provided challenge.",
  },
  {
    id: "ctf-crypto-method",
    title: "CTF cryptography methodology",
    tags: ["ctf", "crypto", "rsa", "methodology"],
    source: "CTF methodology",
    text: "For a crypto challenge: identify the scheme (classical cipher, RSA, AES mode, hashing), look for misuse such as small keys, reused nonces, ECB patterns, or bad padding, apply known attacks (factorization via factordb, frequency analysis), and verify the recovered plaintext matches the flag format.",
  },
  {
    id: "secure-headers",
    title: "Recommended HTTP security headers",
    tags: ["headers", "csp", "hsts", "hardening", "web"],
    source: "OWASP Secure Headers Project",
    text: "Baseline security headers: Content-Security-Policy (mitigate XSS by controlling resource loading), Strict-Transport-Security (force HTTPS), X-Content-Type-Options: nosniff (stop MIME sniffing), Referrer-Policy: strict-origin-when-cross-origin, and Permissions-Policy to disable unused browser features. Prefer CSP frame-ancestors over X-Frame-Options.",
  },
  {
    id: "rate-limiting",
    title: "Rate limiting and abuse protection",
    tags: ["rate limiting", "brute force", "dos", "design"],
    source: "Secure design",
    text: "Critical flows (login, password reset, payment, URL fetch) need abuse protection: per-IP and per-account rate limits, exponential backoff or lockout after repeated failures, CAPTCHA where appropriate, and MFA. This resists brute force, credential stuffing, and resource exhaustion.",
  },
];
