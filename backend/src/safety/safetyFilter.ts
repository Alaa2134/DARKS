/**
 * safetyFilter.ts
 * ----------------------------------------------------------------------------
 * The ethical guardrail at the center of Horus Cyber Agent.
 *
 * Every chat message, audit target, code snippet and command flows through this
 * module BEFORE it reaches an LLM or the command runner. The filter refuses
 * anything that maps to unauthorized hacking or malware development, while
 * deliberately ALLOWING legitimate educational, defensive and CTF work.
 *
 * Design goals:
 *  - Default to teaching, not attacking.
 *  - Block "build me a weapon" requests, allow "explain how this works".
 *  - Restrict active testing to assets the user owns (localhost / private lab).
 *  - Be transparent: always explain WHY something was refused and offer a safe
 *    alternative.
 */

export type SafetyDecision = "allow" | "refuse";

export interface SafetyResult {
  decision: SafetyDecision;
  allowed: boolean;
  /** Short machine readable category, e.g. "malware_development". */
  category?: string;
  /** Human readable explanation shown to the user. */
  reason?: string;
  /** A safe alternative the user can pursue instead. */
  safeAlternative?: string;
  /** The phrases that triggered the refusal (for transparency / logging). */
  matched?: string[];
}

interface RuleGroup {
  category: string;
  reason: string;
  safeAlternative: string;
  /** If ANY of these match AND the request looks like an action request. */
  patterns: RegExp[];
}

/**
 * Phrases that signal the user wants to LEARN / DEFEND rather than ATTACK.
 * When a harmful keyword appears strictly inside an educational frame we allow
 * it (e.g. "explain how XSS works"), but an explicit build/use request is still
 * refused even if framed as "educational".
 */
const EDUCATIONAL_FRAME = [
  /\b(explain|understand|learn(ing)?|teach|describe|what\s+is|how\s+does|how\s+do)\b/i,
  /\b(defend|defens(e|ive)|mitigat|prevent|protect|harden|detect|remediat|patch|fix)\b/i,
  /\b(concept(ual(ly)?)?|theory|theoretical|in\s+general|high[-\s]level|overview)\b/i,
  /\b(safe\s+demo|lab|dvwa|juice\s*shop|sandbox|writeup|methodology|checklist)\b/i,
];

/**
 * Explicit "make me a working weapon" intent. If one of these matches we refuse
 * even when an educational word is also present — the request crosses the line
 * from understanding into operational tooling.
 */
const OPERATIONAL_INTENT = [
  /\b(write|create|build|generate|make|code|develop|produce|give\s+me|craft|deploy|launch|run|execute)\b/i,
];

const RULES: RuleGroup[] = [
  {
    category: "malware_development",
    reason:
      "I can't help create malware, ransomware, worms, trojans, keyloggers or other malicious software.",
    safeAlternative:
      "I can explain how a given malware family works conceptually, how to detect it, and how to defend against it for a blue-team / training context.",
    patterns: [
      /\bransomware\b/i,
      /\b(computer\s+)?(worm|trojan|rootkit)\b/i,
      /\bkeylogg(er|ing)\b/i,
      /\b(remote\s+access\s+trojan|rat\s+malware)\b/i,
      /\b(crypto\s*locker|wiper\s+malware)\b/i,
      /\b(polymorphic|self[-\s]?replicating)\s+(virus|code|malware)\b/i,
      /\b(fud|fully\s+undetectable)\s+(payload|malware|crypter)\b/i,
    ],
  },
  {
    category: "phishing_and_fraud",
    reason:
      "I can't help build phishing pages, fake login portals, or social-engineering scripts intended to deceive people.",
    safeAlternative:
      "I can help you train users to RECOGNIZE phishing, build phishing-awareness content, or design email-security controls (SPF/DKIM/DMARC).",
    patterns: [
      /\b(phishing|spear[-\s]?phish|smish(ing)?|vish(ing)?)\b/i,
      /\bfake\s+(login|sign[-\s]?in|bank|paypal|microsoft|google)\s+(page|portal|site)\b/i,
      /\bclone\s+(this\s+)?(login|website)\s+to\s+(steal|capture|harvest)\b/i,
      /\b(scam|fraud)\s+(script|template|email|page)\b/i,
    ],
  },
  {
    category: "credential_theft",
    reason:
      "I can't help steal credentials, cookies, session tokens, or dump password stores.",
    safeAlternative:
      "I can explain how credential theft happens so you can defend against it: secure cookie flags, token rotation, MFA, and secrets management.",
    patterns: [
      /\b(steal|harvest|capture|dump|exfiltrate|grab)\s+(the\s+)?(credential|password|cookie|session|token|hash)/i,
      /\b(credential|password)\s+(stealer|dumper|harvest(er|ing))\b/i,
      /\b(mimikatz|lsass\s+dump|sam\s+dump|ntds\.dit)\b/i,
      /\bcookie\s+(stealer|grabber|hijack(er|ing))\b/i,
    ],
  },
  {
    category: "auth_bypass",
    reason:
      "I can't help bypass authentication, defeat MFA, or circumvent access controls on systems.",
    safeAlternative:
      "I can review YOUR auth flow for weaknesses and recommend hardening (rate limiting, MFA, session management, secure password storage).",
    patterns: [
      /\b(bypass|defeat|circumvent|disable|brute[-\s]?force)\s+(the\s+)?(login|auth(entication)?|mfa|2fa|otp|captcha|paywall|license)/i,
      /\b(crack|break)\s+(into|the)\s+(account|login|wifi|password)\b/i,
    ],
  },
  {
    category: "persistence_evasion",
    reason:
      "I can't help build backdoors, persistence mechanisms, or AV/EDR evasion tooling.",
    safeAlternative:
      "I can describe common persistence/evasion techniques (MITRE ATT&CK style) so your detection and response can catch them.",
    patterns: [
      /\b(backdoor|implant)\s+(into|on|for|the)\b/i,
      /\b(establish|maintain|gain)\s+persistence\b/i,
      /\b(av|edr|antivirus|defender)\s+(evasion|bypass)\b/i,
      /\b(obfuscate|crypt)\s+(my\s+)?(payload|shellcode|malware)\b/i,
      /\bdll\s+(injection|hijack(ing)?)\s+for\s+(persistence|evasion)/i,
    ],
  },
  {
    category: "remote_exploitation",
    reason:
      "I can't help build reverse shells, weaponized exploits, or payloads aimed at gaining unauthorized access.",
    safeAlternative:
      "For CTFs and your own lab I can explain a vulnerability class conceptually and the secure-coding fix. I won't produce weaponized payloads for live targets.",
    patterns: [
      /\b(reverse|bind)\s+shell\b/i,
      /\bmsfvenom\b/i,
      /\b(weaponi[sz]e|arm)\s+(this\s+)?(exploit|payload|cve)/i,
      /\b(meterpreter|empire\s+c2|cobalt\s+strike)\s+(payload|beacon|implant)\b/i,
      /\bgenerate\s+(a\s+)?(shellcode|payload)\s+(to|that)\s+(exploit|own|pop|attack)/i,
    ],
  },
  {
    category: "botnet_dos",
    reason:
      "I can't help build botnets, spam infrastructure, or denial-of-service tooling.",
    safeAlternative:
      "I can explain DDoS mitigation, rate limiting, and how to architect resilient, abuse-resistant services.",
    patterns: [
      /\b(botnet|c2\s+server|command\s+and\s+control)\s+(to|for)\b/i,
      /\b(ddos|dos)\s+(attack|tool|script|a\s+)/i,
      /\b(stress(er)?|booter|ip\s+stresser)\b/i,
      /\b(spam|mail\s*bomb)\s+(bot|script|campaign)\b/i,
      /\bflood\s+(the\s+)?(server|target|network|port)\b/i,
    ],
  },
  {
    category: "destructive_action",
    reason:
      "I can't help write destructive commands that wipe or sabotage systems or data.",
    safeAlternative:
      "I can help with safe backup, recovery, and least-privilege practices instead.",
    patterns: [
      /\brm\s+-rf\s+(\/|~|\*|\.\s|\.$)/i,
      /\b(dd\s+if=.*of=\/dev\/(sd|nvme|hd))/i,
      /\b(mkfs|format)\s+\/dev\//i,
      /\b:\(\)\s*\{\s*:\|:&\s*\}\s*;:/i, // fork bomb
      /\b(del|rmdir|format)\s+\/[sq]\s+c:\\?/i,
    ],
  },
];

/**
 * Returns true if the text contains an educational / defensive framing.
 */
function hasEducationalFrame(text: string): boolean {
  return EDUCATIONAL_FRAME.some((re) => re.test(text));
}

function hasOperationalIntent(text: string): boolean {
  return OPERATIONAL_INTENT.some((re) => re.test(text));
}

/**
 * Core text-level safety check. Used for chat messages and free-text input.
 */
export function evaluateText(input: string): SafetyResult {
  const text = (input ?? "").toString();
  if (!text.trim()) {
    return { decision: "allow", allowed: true };
  }

  const educational = hasEducationalFrame(text);
  const operational = hasOperationalIntent(text);

  for (const rule of RULES) {
    const matched = rule.patterns
      .map((re) => text.match(re)?.[0])
      .filter((m): m is string => Boolean(m));

    if (matched.length === 0) continue;

    // Destructive commands and explicitly weaponized intent are always refused.
    const alwaysRefuse =
      rule.category === "destructive_action" ||
      rule.category === "malware_development";

    // For other categories, allow a purely educational/defensive framing,
    // but refuse if the user is asking us to build/run an operational tool.
    if (!alwaysRefuse && educational && !operational) {
      continue;
    }

    return {
      decision: "refuse",
      allowed: false,
      category: rule.category,
      reason: rule.reason,
      safeAlternative: rule.safeAlternative,
      matched,
    };
  }

  return { decision: "allow", allowed: true };
}

// ---------------------------------------------------------------------------
// Target / scope safety
// ---------------------------------------------------------------------------

/**
 * Hosts that are always considered "owned lab" infrastructure and safe to
 * reference for active-style testing guidance.
 */
const PRIVATE_HOST_PATTERNS = [
  /^localhost$/i,
  /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, // loopback
  /^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, // 10.0.0.0/8
  /^192\.168\.\d{1,3}\.\d{1,3}$/, // 192.168.0.0/16
  /^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$/, // 172.16.0.0/12
  /^169\.254\.\d{1,3}\.\d{1,3}$/, // link-local
  /^::1$/, // IPv6 loopback
  /\.local$/i,
  /\.test$/i,
  /\.localhost$/i,
  /\.example$/i,
  /\.invalid$/i,
];

export interface TargetScopeResult {
  allowed: boolean;
  host: string | null;
  isPrivate: boolean;
  reason: string;
}

/**
 * Extract a hostname from a raw target string (URL, host, or host:port).
 */
export function extractHost(raw: string): string | null {
  if (!raw) return null;
  let value = raw.trim();
  try {
    if (!/^[a-z]+:\/\//i.test(value)) value = `http://${value}`;
    const url = new URL(value);
    return url.hostname.toLowerCase();
  } catch {
    // Fall back to a loose host:port split.
    const host = raw.trim().split("/")[0].split(":")[0].toLowerCase();
    return host || null;
  }
}

export function isPrivateHost(host: string | null): boolean {
  if (!host) return false;
  return PRIVATE_HOST_PATTERNS.some((re) => re.test(host));
}

/**
 * Validate a target against the active scope.
 *
 * @param raw          The user supplied URL / host.
 * @param confirmedScope  Hostnames the user has explicitly confirmed they own.
 */
export function evaluateTarget(
  raw: string,
  confirmedScope: string[] = []
): TargetScopeResult {
  const host = extractHost(raw);
  if (!host) {
    return {
      allowed: false,
      host: null,
      isPrivate: false,
      reason: "Could not parse a hostname from the target.",
    };
  }

  const isPrivate = isPrivateHost(host);
  const inScope = confirmedScope
    .map((h) => h.toLowerCase())
    .some((h) => h === host || host.endsWith(`.${h}`));

  if (isPrivate) {
    return {
      allowed: true,
      host,
      isPrivate: true,
      reason: "Target is a local / private lab host — safe for testing guidance.",
    };
  }

  if (inScope) {
    return {
      allowed: true,
      host,
      isPrivate: false,
      reason:
        "Target is in your confirmed ownership scope — proceeding with audit guidance.",
    };
  }

  return {
    allowed: false,
    host,
    isPrivate: false,
    reason:
      `"${host}" is a public target that is not in your confirmed scope. ` +
      "Horus only assists with local/private lab hosts or assets you have " +
      "explicitly confirmed you own. Add it to Target Scope with ownership " +
      "attestation, or use a local lab (DVWA, Juice Shop, etc.) instead.",
  };
}
