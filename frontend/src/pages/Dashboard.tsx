import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  Eye,
  MessagesSquare,
  Flag,
  ShieldCheck,
  FileCode2,
  Terminal,
  FileText,
  Crosshair,
  ShieldAlert,
  Activity,
  CheckCircle2,
  XCircle,
} from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { api } from "@/lib/api";

const MODES = [
  {
    to: "/chat",
    icon: MessagesSquare,
    title: "Cyber Chat Agent",
    desc: "Ask anything security-related. Safety-filtered, mode-aware assistant.",
  },
  {
    to: "/ctf",
    icon: Flag,
    title: "CTF Helper",
    desc: "Methodology and hints for web, crypto, forensics, rev, pwn, OSINT.",
  },
  {
    to: "/audit",
    icon: ShieldCheck,
    title: "Web Audit",
    desc: "OWASP Top 10 checklist for your own / lab targets, with remediation.",
  },
  {
    to: "/code-review",
    icon: FileCode2,
    title: "Secure Code Review",
    desc: "Find injection, XSS, weak auth, secrets — and get secure fixes.",
  },
  {
    to: "/logs",
    icon: Terminal,
    title: "Logs & Runner",
    desc: "Defensive log analysis and an allowlist-only command runner.",
  },
  {
    to: "/reports",
    icon: FileText,
    title: "Reports",
    desc: "Generate professional pentest-style reports and export Markdown.",
  },
];

const GUARDRAILS = [
  "Malware, ransomware, worms, trojans",
  "Phishing & fake login pages",
  "Credential / cookie / token theft",
  "Auth & MFA bypass",
  "Backdoors, persistence, evasion",
  "Reverse shells & live exploitation",
  "Botnets, spam, DoS tooling",
  "Destructive commands",
];

export function Dashboard() {
  const [health, setHealth] = useState<{ status: string; llmProvider: string } | null>(
    null
  );
  const [err, setErr] = useState(false);

  useEffect(() => {
    api
      .health()
      .then(setHealth)
      .catch(() => setErr(true));
  }, []);

  return (
    <div>
      <div className="mb-8 overflow-hidden rounded-2xl border border-border bg-gradient-to-br from-card via-card to-neon-purple/5 p-8">
        <div className="flex items-center gap-4">
          <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-gradient-to-br from-neon-blue to-neon-purple shadow-neon">
            <Eye className="h-7 w-7 text-background" />
          </div>
          <div>
            <h1 className="text-3xl font-bold tracking-tight">
              Horus <span className="neon-text">Cyber Agent</span>
            </h1>
            <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
              A safe, ethical AI cybersecurity workspace for students, CTF
              players, and authorized testers. Plan audits, review code, analyze
              logs, and generate reports — with guardrails always on.
            </p>
          </div>
        </div>

        <div className="mt-6 flex flex-wrap items-center gap-3">
          <StatusPill
            ok={!err && health?.status === "ok"}
            label={
              err
                ? "API offline"
                : health
                  ? `API online · LLM: ${health.llmProvider}`
                  : "Connecting…"
            }
          />
          <Badge variant="secondary">
            <ShieldCheck className="h-3 w-3" /> Ethical guardrails active
          </Badge>
          <Badge variant="muted">Owned / lab targets only</Badge>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
        {MODES.map((m) => (
          <Link key={m.to} to={m.to}>
            <Card className="group h-full transition-all hover:-translate-y-0.5 hover:shadow-neon">
              <CardHeader>
                <div className="mb-2 flex h-10 w-10 items-center justify-center rounded-lg border border-neon-blue/30 bg-neon-blue/10 text-neon-blue transition-colors group-hover:bg-neon-blue/20">
                  <m.icon className="h-5 w-5" />
                </div>
                <CardTitle>{m.title}</CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm text-muted-foreground">{m.desc}</p>
              </CardContent>
            </Card>
          </Link>
        ))}
      </div>

      <div className="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldAlert className="h-4 w-4 text-severity-high" />
              Safety Guardrails — always refused
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {GUARDRAILS.map((g) => (
                <div
                  key={g}
                  className="flex items-center gap-2 text-sm text-muted-foreground"
                >
                  <XCircle className="h-3.5 w-3.5 shrink-0 text-severity-critical" />
                  {g}
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Activity className="h-4 w-4 text-neon-blue" />
              Quick start
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm text-muted-foreground">
            <Step n={1} to="/scope" icon={Crosshair}>
              Confirm ownership of your target in <b>Target Scope</b>.
            </Step>
            <Step n={2} to="/audit" icon={ShieldCheck}>
              Generate an <b>OWASP Top 10</b> checklist for it.
            </Step>
            <Step n={3} to="/code-review" icon={FileCode2}>
              Paste code for a <b>secure review</b>.
            </Step>
            <Step n={4} to="/reports" icon={FileText}>
              Compile findings into a <b>professional report</b>.
            </Step>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function StatusPill({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className="inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1 text-xs">
      {ok ? (
        <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
      ) : (
        <XCircle className="h-3.5 w-3.5 text-severity-high" />
      )}
      <span className="font-mono text-muted-foreground">{label}</span>
    </div>
  );
}

function Step({
  n,
  to,
  icon: Icon,
  children,
}: {
  n: number;
  to: string;
  icon: React.ElementType;
  children: React.ReactNode;
}) {
  return (
    <Link to={to} className="flex items-center gap-3 rounded-lg p-2 hover:bg-muted/40">
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-neon-purple/20 text-xs font-bold text-neon-purple">
        {n}
      </span>
      <Icon className="h-4 w-4 text-neon-blue" />
      <span>{children}</span>
    </Link>
  );
}
