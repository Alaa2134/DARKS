# Horus Cyber Agent

> A safe, ethical AI cybersecurity workspace for students, CTF players, and
> authorized security professionals.

Horus is a Manus-style cybersecurity assistant that helps people **learn**,
**defend**, and **test assets they own or are authorized to test**. It plans
audits, reviews code, analyzes logs, and generates professional reports — while
a built-in **safety guardrail system** refuses anything that maps to malware,
phishing, credential theft, or unauthorized attacks.

It is **not** malware, not WormGPT, not a phishing kit, not an exploit bot.
Every request passes through a server-side safety filter that is **always on**.

---

## Table of contents

- [Features](#features)
- [Safety model](#safety-model)
- [Tech stack](#tech-stack)
- [Folder structure](#folder-structure)
- [Installation (Windows)](#installation-windows)
- [Installation (macOS / Linux)](#installation-macos--linux)
- [Configuration (.env)](#configuration-env)
- [Running](#running)
- [Command runner allowlist](#command-runner-allowlist)
- [Example prompts](#example-prompts)
- [Demo scenario](#demo-scenario)
- [Hackathon pitch](#hackathon-pitch)
- [API reference](#api-reference)
- [Disclaimer](#disclaimer)

---

## Features

| # | Feature | Where |
|---|---------|-------|
| 1 | Chat interface for cybersecurity tasks | **Cyber Chat Agent** |
| 2 | Task planner that breaks work into legal steps | Chat + mode prompts |
| 3 | Recon helper for user-owned / local targets only | **Target Scope** |
| 4 | Vulnerability checklist generator (OWASP Top 10) | **Web Audit** |
| 5 | CTF helper mode | **CTF Helper** |
| 6 | Web security audit mode | **Web Audit** |
| 7 | Secure code review mode | **Secure Code Review** |
| 8 | Log analyzer (defensive) | **Terminal Logs** |
| 9 | Report generator | **Reports** |
| 10 | Remediation / fix generator | Built into reviews & audits |
| 11 | Safety filter that refuses illegal/harmful requests | `safetyFilter.ts` (server-side) |

**Pages:** Dashboard · Cyber Chat Agent · Target Scope · CTF Helper · Web Audit ·
Secure Code Review · Terminal Logs · Reports · Settings.

**Agent modes:** CTF · Web Audit · Secure Code Review · Log Analysis · Report.

---

## Safety model

The safety guardrail is the heart of the project. It lives in
[`backend/src/safety/safetyFilter.ts`](backend/src/safety/safetyFilter.ts) and
runs **server-side before any LLM call or command execution**.

**Always refused** (any framing):

- Malware, ransomware, worms, trojans, keyloggers
- Phishing pages / fake login portals / fraud scripts
- Credential, cookie, session-token theft / password dumping
- Bypassing authentication, MFA, or access controls
- Backdoors, persistence, AV/EDR evasion
- Reverse shells & weaponized exploits against live targets
- Botnets, spam, denial-of-service tooling
- Destructive commands (`rm -rf /`, disk wipes, fork bombs)
- Testing systems the user does not own / is not authorized to test

**Always allowed** (education & defense):

- Conceptual explanations of vulnerability classes + how to defend
- OWASP Top 10 checklists and secure-code reviews
- CTF methodology, hints, and write-ups
- Defensive log analysis and threat explanation
- Security headers, hardening, remediation
- Professional report writing

**Design principle:** *teach, don't attack.* The filter distinguishes
`"explain how XSS works"` (allowed) from `"write me a worm"` (refused), and
restricts active-testing guidance to `localhost`, private RFC1918 ranges,
`*.local` / `*.test`, and hosts the user has explicitly attested they own in
**Target Scope**.

---

## Tech stack

**Frontend:** React · Vite · TypeScript · Tailwind CSS · shadcn/ui-style
components · lucide-react · react-router-dom · react-markdown

**Backend:** Node.js · Express · TypeScript · helmet · cors · morgan

**Optional:** local workspace command runner (allowlist only), Markdown report
exporter, Docker.

LLM is **optional** — Horus runs fully in built-in template mode with no API
key, and supports Anthropic (Claude) or OpenAI when a key is provided.

---

## Folder structure

```
DARKS/
├── README.md
├── backend/
│   ├── package.json
│   ├── tsconfig.json
│   ├── .env.example
│   └── src/
│       ├── server.ts                # Express app + routes
│       ├── config.ts                # env-driven config
│       ├── safety/
│       │   ├── safetyFilter.ts      # ★ ethical guardrails + scope checks
│       │   └── safetyFilter.test.ts # safety unit tests
│       ├── services/
│       │   ├── commandRunner.ts     # ★ allowlist-only, no-shell runner
│       │   ├── llmService.ts        # Anthropic/OpenAI + offline fallback
│       │   ├── offlineResponder.ts  # template responses (no API key)
│       │   ├── codeReview.ts        # static security heuristics
│       │   ├── logAnalyzer.ts       # defensive log heuristics
│       │   └── reportGenerator.ts   # pentest-style Markdown reports
│       ├── routes/
│       │   ├── chat.ts              # POST /api/chat (safety-filtered)
│       │   ├── command.ts           # /api/command/*
│       │   ├── audit.ts             # /api/audit/*
│       │   └── analysis.ts          # /api/analysis/*
│       ├── data/
│       │   ├── allowlist.ts         # ★ command allow/deny lists
│       │   ├── owasp.ts             # OWASP Top 10 knowledge base
│       │   └── ctf.ts               # CTF methodology knowledge base
│       └── prompts/
│           └── systemPrompts.ts     # mode-aware system prompts
└── frontend/
    ├── package.json
    ├── vite.config.ts               # dev proxy /api -> :5174
    ├── tailwind.config.js
    ├── index.html
    ├── .env.example
    └── src/
        ├── main.tsx
        ├── App.tsx                  # routes + providers
        ├── index.css                # dark cyber theme
        ├── lib/
        │   ├── api.ts               # typed API client
        │   ├── utils.ts             # cn() + severity metadata
        │   ├── scopeStore.tsx       # confirmed-ownership scope
        │   └── findingsStore.tsx    # findings -> report pipeline
        ├── components/
        │   ├── ui/                  # button, card, badge, tabs, …
        │   ├── Sidebar.tsx
        │   ├── ChatPanel.tsx
        │   ├── SeverityBadge.tsx
        │   ├── Markdown.tsx
        │   └── PageHeader.tsx
        └── pages/
            ├── Dashboard.tsx
            ├── CyberChat.tsx
            ├── TargetScope.tsx
            ├── CtfHelper.tsx
            ├── WebAudit.tsx
            ├── SecureCodeReview.tsx
            ├── TerminalLogs.tsx
            ├── Reports.tsx
            └── Settings.tsx
```

★ = security-critical files.

---

## Installation (Windows)

1. **Install Node.js (LTS, v18+)** from <https://nodejs.org>. Verify in
   PowerShell / CMD:

   ```powershell
   node -v
   npm -v
   ```

2. **Clone / open the project** and go to the folder:

   ```powershell
   cd DARKS
   ```

3. **Install the backend:**

   ```powershell
   cd backend
   npm install
   copy .env.example .env
   ```

4. **Install the frontend** (new terminal):

   ```powershell
   cd frontend
   npm install
   copy .env.example .env
   ```

5. **Run both** (see [Running](#running)).

---

## Installation (macOS / Linux)

```bash
# Backend
cd backend
npm install
cp .env.example .env

# Frontend (new terminal)
cd frontend
npm install
cp .env.example .env
```

---

## Configuration (.env)

`backend/.env` (all optional — defaults work out of the box):

```ini
PORT=5174
CORS_ORIGIN=http://localhost:5173

# LLM is optional. Leave as "offline" to use built-in templates (no key needed).
LLM_PROVIDER=offline           # anthropic | openai | offline
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=claude-sonnet-4-6
OPENAI_API_KEY=
OPENAI_MODEL=gpt-4o-mini

# Command runner (allowlist-only)
ENABLE_COMMAND_RUNNER=true
COMMAND_WORKSPACE=./workspace
COMMAND_TIMEOUT_MS=20000
```

To enable live AI, set `LLM_PROVIDER=anthropic` and add `ANTHROPIC_API_KEY`.
The safety filter applies **whether or not** a key is present.

---

## Running

Two terminals:

```bash
# Terminal 1 — backend API on http://localhost:5174
cd backend
npm run dev

# Terminal 2 — frontend on http://localhost:5173
cd frontend
npm run dev
```

Open <http://localhost:5173>. The Vite dev server proxies `/api` to the backend
automatically.

**Backend scripts:** `npm run dev` · `npm run build` · `npm start` ·
`npm run typecheck` · `npm test` (safety unit tests).
**Frontend scripts:** `npm run dev` · `npm run build` · `npm run preview`.

---

## Command runner allowlist

The runner executes commands **with no shell** (argv array passed to `spawn`,
`shell: false`), locked to a workspace directory, with a hard timeout. It is
**deny-by-default**.

**Allowed:** `npm` · `npx` · `node` · `python` / `python3` · `pip` / `pip3` ·
`git` (status, diff, log, branch, show, remote) · `ls` / `dir` · `cat` /
`type` · `pwd` · `echo` · `eslint` · `prettier` · `tsc`.

**Always blocked:** `nmap`, `masscan`, `hydra`, `sqlmap`, `metasploit`/`msfvenom`,
`mimikatz`, `nc`/`netcat`/`socat`, and any string containing `rm -rf`, raw disk
writes, fork bombs, `sudo`/`su`, shell chaining (`| && ; \``), or remote
download-exec (`curl`/`wget` piping). See
[`backend/src/data/allowlist.ts`](backend/src/data/allowlist.ts).

---

## Example prompts

Allowed:

- "Review this code for SQL injection"
- "Create an OWASP checklist for my website"
- "Help me write a pentest report template"
- "Explain how XSS works in a safe demo"
- "Make a CTF methodology guide"
- "Analyze this log file defensively"
- "Suggest security headers for my React app"
- "Create a local DVWA-style lab explanation without real-world abuse"

Refused (with a safe alternative offered):

- "Write me ransomware" → offered: how it works + how to defend
- "Build a phishing page for PayPal" → offered: phishing-awareness training
- "Generate a reverse shell to attack 1.2.3.4" → offered: conceptual + secure fix

---

## Demo scenario

> **User:** "I own this test web app. Help me audit it using OWASP Top 10."

1. **Confirm ownership / scope** — go to **Target Scope**, add the host (or use a
   local one like `http://localhost:3000`), and attest ownership. The scope
   checker confirms it's in scope.
2. **Create a safe testing plan** — open **Web Audit**, confirm the target to
   *unlock* the checklist.
3. **Generate the checklist** — the OWASP Top 10 checklist renders with checks,
   severity hints, and remediation; tick items as you verify them.
4. **Review pasted code or logs** — in **Secure Code Review**, click *Load
   sample* and *Run secure review* to surface SQL injection (Critical), a
   hardcoded secret (High), path traversal, XSS, etc. In **Terminal Logs →
   Log Analyzer**, *Load sample* and *Analyze* to flag SQLi/XSS/brute-force.
5. **Produce a professional report** — push findings *To report*, open
   **Reports**, *Generate report*, preview, and *Export .md*.
6. **Recommend fixes** — every finding ships with a concrete remediation /
   secure-code fix, included in the report.

Try the guardrail live: ask the Cyber Chat Agent to "write me ransomware" — it
refuses and offers a defensive alternative.

---

## Hackathon pitch

> **Horus Cyber Agent** is a safe AI-powered cybersecurity workspace for
> students, CTF players, and ethical hackers. It helps users plan audits, review
> code, analyze logs, and generate professional reports — while preventing
> harmful or unauthorized activity through a built-in safety guardrail system.
>
> Most "hacker AI" tools online are unsafe by design. Horus flips that: the
> safety filter is the core feature, not an afterthought. It runs server-side on
> every request, refuses malware/phishing/credential-theft/unauthorized testing,
> and restricts active guidance to assets you own or run locally. Everything
> else — learning, defending, CTFs, owned-target audits — is fully supported.
>
> The result is a serious, dark cyber-ops dashboard that teaches good security
> practice end-to-end: scope → checklist → review → report → remediation. It
> works with zero API keys (built-in template mode) and plugs into Claude or
> OpenAI when you want live AI. Ethical by construction, useful in practice.

*(~60 seconds spoken.)*

---

## API reference

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET  | `/api/health` | Status + config |
| POST | `/api/chat` | Safety-filtered chat (`{ mode, messages }`) |
| GET  | `/api/audit/checklist` | OWASP Top 10 data |
| GET  | `/api/audit/headers` | Recommended security headers |
| POST | `/api/audit/scope-check` | Validate a target against scope |
| POST | `/api/analysis/code-review` | Static security review of code |
| POST | `/api/analysis/logs` | Defensive log analysis |
| POST | `/api/analysis/report` | Generate Markdown report |
| GET  | `/api/command/allowlist` | Allowed/blocked commands |
| POST | `/api/command/validate` | Dry-run command safety check |
| POST | `/api/command/run` | Execute an allowlisted command |

---

## Disclaimer

Horus is for **education, CTFs, local labs, and assets you own or are
explicitly authorized to test**. It is not a tool for attacking systems. You are
responsible for using it lawfully and ethically. The authors provide it as-is,
without warranty.
