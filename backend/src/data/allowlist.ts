/**
 * allowlist.ts
 * ----------------------------------------------------------------------------
 * The command runner operates on a strict allowlist. ONLY the base commands
 * listed here can ever be executed, and even then dangerous argument patterns
 * are blocked. This is a deny-by-default design: anything not explicitly
 * allowed is refused.
 */

export interface AllowedCommand {
  /** The base executable name (argv[0]). */
  bin: string;
  /** Human readable description for the UI. */
  description: string;
  /** Optional sub-commands that are allowed (e.g. "status", "diff" for git). */
  allowedSubcommands?: string[];
}

export const ALLOWED_COMMANDS: AllowedCommand[] = [
  { bin: "npm", description: "Node package manager (install / run / test / build)" },
  { bin: "npx", description: "Run a local Node binary" },
  { bin: "node", description: "Run a local Node.js script" },
  { bin: "python", description: "Run a local Python script" },
  { bin: "python3", description: "Run a local Python 3 script" },
  { bin: "pip", description: "Python package installer" },
  { bin: "pip3", description: "Python 3 package installer" },
  {
    bin: "git",
    description: "Read-only git inspection",
    allowedSubcommands: ["status", "diff", "log", "branch", "show", "remote"],
  },
  { bin: "ls", description: "List files (Unix)" },
  { bin: "dir", description: "List files (Windows)" },
  { bin: "cat", description: "Print a file (Unix)" },
  { bin: "type", description: "Print a file (Windows)" },
  { bin: "pwd", description: "Print working directory" },
  { bin: "echo", description: "Print text" },
  { bin: "eslint", description: "Lint JavaScript / TypeScript" },
  { bin: "prettier", description: "Format code" },
  { bin: "tsc", description: "TypeScript compiler" },
];

/**
 * Argument-level deny patterns. Even on an allowed binary these patterns are
 * blocked because they represent destructive or unauthorized-scanning intent.
 */
export const BLOCKED_ARG_PATTERNS: { label: string; pattern: RegExp }[] = [
  { label: "recursive force delete", pattern: /\brm\s+-rf?\b/i },
  { label: "raw disk write", pattern: /\bdd\s+if=/i },
  { label: "filesystem format", pattern: /\bmkfs\b|\bformat\s+[a-z]:/i },
  { label: "fork bomb", pattern: /:\(\)\s*\{\s*:\|:&\s*\};:/ },
  { label: "privilege escalation", pattern: /\b(sudo|su|runas)\b/i },
  { label: "shell chaining", pattern: /(\|\||&&|;|\||`|\$\(|>\s*\/|<\s*\/)/ },
  { label: "remote download-exec", pattern: /\b(curl|wget|iwr|invoke-webrequest)\b/i },
  { label: "network scanner", pattern: /\b(nmap|masscan|zmap|rustscan)\b/i },
  { label: "exploitation framework", pattern: /\b(metasploit|msfconsole|msfvenom)\b/i },
  { label: "password attack tool", pattern: /\b(hydra|medusa|john|hashcat|patator)\b/i },
  { label: "sql injection tool", pattern: /\bsqlmap\b/i },
  { label: "credential dumper", pattern: /\b(mimikatz|secretsdump|lsassy)\b/i },
  { label: "reverse shell helper", pattern: /\b(nc|ncat|netcat|socat)\b.*-e/i },
];

/** Names that should be loudly rejected if anyone tries to run them as a bin. */
export const HARD_BLOCKED_BINS = [
  "nmap",
  "masscan",
  "zmap",
  "rustscan",
  "hydra",
  "medusa",
  "john",
  "hashcat",
  "sqlmap",
  "msfconsole",
  "msfvenom",
  "metasploit",
  "mimikatz",
  "nc",
  "ncat",
  "netcat",
  "socat",
  "setoolkit",
  "responder",
  "bettercap",
  "ettercap",
  "aircrack-ng",
];
