/**
 * ctf.ts — CTF methodology knowledge base. Conceptual guidance only; helps
 * players learn categories and approaches without attacking real systems.
 */

export interface CtfCategory {
  id: string;
  name: string;
  summary: string;
  methodology: string[];
  commonTools: string[];
  learnMore: string[];
}

export const CTF_CATEGORIES: CtfCategory[] = [
  {
    id: "web",
    name: "Web Exploitation",
    summary:
      "Find logic and input-handling flaws in a provided web challenge.",
    methodology: [
      "Map the app: pages, endpoints, parameters, and tech stack.",
      "Read client-side code and comments for hints.",
      "Test input handling for injection, IDOR, and auth logic flaws.",
      "Inspect cookies/JWTs and access control between roles.",
      "Document the path from observation to flag.",
    ],
    commonTools: ["Browser dev tools", "Burp Suite (lab)", "curl", "jwt_tool"],
    learnMore: ["OWASP Testing Guide", "PortSwigger Web Security Academy"],
  },
  {
    id: "crypto",
    name: "Cryptography",
    summary: "Break or analyze weak/misused cryptographic schemes.",
    methodology: [
      "Identify the scheme (classical cipher, RSA, AES mode, hashing).",
      "Look for misuse: small keys, reused nonces, ECB patterns, bad padding.",
      "Apply known math/attacks (factorization, frequency analysis).",
      "Validate the recovered plaintext format matches the flag.",
    ],
    commonTools: ["Python + pycryptodome", "SageMath", "CyberChef", "factordb"],
    learnMore: ["CryptoHack", "Cryptopals challenges"],
  },
  {
    id: "forensics",
    name: "Forensics",
    summary: "Recover hidden information from files, memory, or captures.",
    methodology: [
      "Identify the artifact type (pcap, disk image, memory dump, media file).",
      "Inspect metadata and file structure for anomalies.",
      "Carve embedded/hidden files; follow streams in captures.",
      "Reconstruct the story to find the flag.",
    ],
    commonTools: ["Wireshark", "binwalk", "foremost", "Volatility", "exiftool"],
    learnMore: ["DFIR write-ups", "Volatility documentation"],
  },
  {
    id: "rev",
    name: "Reverse Engineering",
    summary: "Understand a binary's logic to derive the required input.",
    methodology: [
      "Triage with strings/file; identify language and packing.",
      "Disassemble/decompile and locate the check function.",
      "Reason about constraints the input must satisfy.",
      "Reconstruct the key/flag from the logic.",
    ],
    commonTools: ["Ghidra", "radare2", "gdb/pwndbg", "strings", "ltrace"],
    learnMore: ["crackmes.one", "Ghidra tutorials"],
  },
  {
    id: "pwn",
    name: "Binary Exploitation (pwn)",
    summary:
      "Exploit memory-safety bugs in a provided binary within the CTF sandbox.",
    methodology: [
      "Identify the vulnerability class (overflow, UAF, format string).",
      "Examine protections (NX, ASLR, canary, PIE).",
      "Develop the exploit locally against the provided binary only.",
      "Explain the root cause and the secure-coding fix.",
    ],
    commonTools: ["pwntools", "gdb/pwndbg", "checksec", "ROPgadget"],
    learnMore: ["pwn.college", "ROP Emporium"],
  },
  {
    id: "osint",
    name: "OSINT",
    summary:
      "Find publicly available information relevant to the challenge — using only public, lawful sources.",
    methodology: [
      "Start from the provided seed (handle, image, domain).",
      "Pivot across public records, metadata, and archives.",
      "Cross-reference findings; respect privacy and legality.",
      "Document the chain of evidence to the flag.",
    ],
    commonTools: ["Search engines", "WHOIS", "exif viewers", "Wayback Machine"],
    learnMore: ["OSINT Framework", "Trace Labs guidelines"],
  },
];
