import { useEffect, useState } from "react";
import {
  Settings as SettingsIcon,
  ShieldCheck,
  ServerCog,
  Sparkles,
  Lightbulb,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { api, type AllowlistInfo, type SafetyLogEntry, type SafetyStats } from "@/lib/api";

const EXAMPLE_PROMPTS = [
  "Review this code for SQL injection",
  "Create an OWASP checklist for my website",
  "Help me write a pentest report template",
  "Explain how XSS works in a safe demo",
  "Make a CTF methodology guide",
  "Analyze this log file defensively",
  "Suggest security headers for my React app",
  "Create a local DVWA-style lab explanation without real-world abuse",
];

const REFUSALS = [
  "Phishing / fake login pages",
  "Malware, ransomware, worms, trojans",
  "Credential / cookie / token stealing",
  "Bypassing login or MFA",
  "Real target exploitation",
  "Persistence, evasion, backdoors",
  "Botnets or spam",
  "Destructive commands",
  "Social-engineering fraud scripts",
  "Testing systems the user does not own",
];

export function Settings() {
  const [health, setHealth] = useState<{ status: string; llmProvider: string } | null>(
    null
  );
  const [allowlist, setAllowlist] = useState<AllowlistInfo | null>(null);
  const [safety, setSafety] = useState<{ entries: SafetyLogEntry[]; stats: SafetyStats } | null>(
    null
  );

  useEffect(() => {
    api.health().then(setHealth).catch(() => {});
    api.allowlist().then(setAllowlist).catch(() => {});
    api.safetyLog().then(setSafety).catch(() => {});
  }, []);

  return (
    <div>
      <PageHeader
        icon={SettingsIcon}
        title="Settings"
        subtitle="Runtime configuration, safety policy, and the command allowlist."
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ServerCog className="h-4 w-4 text-neon-blue" /> Runtime
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <Row label="API status">
              <Badge variant={health ? "default" : "muted"}>
                {health?.status ?? "offline"}
              </Badge>
            </Row>
            <Row label="LLM provider">
              <code className="text-neon-blue">{health?.llmProvider ?? "unknown"}</code>
            </Row>
            <Row label="Command runner">
              <Badge variant={allowlist?.enabled ? "default" : "muted"}>
                {allowlist?.enabled ? "enabled" : "disabled"}
              </Badge>
            </Row>
            <Row label="Workspace">
              <code className="text-xs text-muted-foreground">
                {allowlist?.workspace ?? "—"}
              </code>
            </Row>
            <p className="pt-2 text-xs text-muted-foreground">
              Configure providers and limits in <code>backend/.env</code>. With no
              API key, Horus runs in built-in template mode — every feature still
              works.
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-emerald-400" /> Safety policy
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="mb-3 text-sm text-muted-foreground">
              The safety filter runs server-side on every request and is always
              on. Horus refuses:
            </p>
            <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
              {REFUSALS.map((r) => (
                <div key={r} className="text-sm text-muted-foreground">
                  • {r}
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Lightbulb className="h-4 w-4 text-neon-purple" /> Example prompts
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {EXAMPLE_PROMPTS.map((p) => (
              <span
                key={p}
                className="rounded-full border border-border bg-background/40 px-3 py-1.5 text-xs text-muted-foreground"
              >
                {p}
              </span>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Sparkles className="h-4 w-4 text-neon-blue" /> About
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-muted-foreground">
            <p>
              <b className="text-foreground">Horus Cyber Agent</b> is a safe,
              ethical AI cybersecurity workspace for students, CTF players, and
              authorized testers.
            </p>
            <p>
              It helps you plan audits, review code, analyze logs, and generate
              reports while preventing harmful or unauthorized activity through a
              built-in safety guardrail system.
            </p>
            <p className="text-xs">
              For education, CTFs, local labs, and assets you own or are
              authorized to test. Not a tool for attacking systems.
            </p>
          </CardContent>
        </Card>
      </div>

      {safety && (
        <Card className="mt-6">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-emerald-400" /> Safety telemetry
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="mb-4 flex flex-wrap gap-2 text-sm">
              <Badge variant="muted">{safety.stats.total} requests evaluated</Badge>
              <Badge variant="muted" className="border-severity-critical/30 text-severity-critical">
                {safety.stats.refusals} refused
              </Badge>
              {safety.stats.byCategory.map((c) => (
                <Badge key={c.category} variant="muted">
                  {c.category}: {c.count}
                </Badge>
              ))}
            </div>
            <p className="mb-2 text-xs text-muted-foreground">
              Every refusal is logged server-side for transparency. Most recent:
            </p>
            <div className="space-y-1.5">
              {safety.entries
                .filter((e) => e.decision === "refuse")
                .slice(0, 8)
                .map((e) => (
                  <div
                    key={e.id}
                    className="rounded-lg border border-border bg-background/40 px-3 py-2 text-xs"
                  >
                    <span className="text-severity-high">refused</span>{" "}
                    <span className="text-muted-foreground">[{e.category}]</span>{" "}
                    <span className="text-foreground">{e.excerpt}</span>
                  </div>
                ))}
              {safety.entries.filter((e) => e.decision === "refuse").length === 0 && (
                <p className="text-xs text-muted-foreground">No refusals logged yet.</p>
              )}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between border-b border-border/50 py-1.5 last:border-0">
      <span className="text-muted-foreground">{label}</span>
      {children}
    </div>
  );
}
