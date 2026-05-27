import { useEffect, useState } from "react";
import {
  ShieldCheck,
  ShieldX,
  Loader2,
  ListChecks,
  FileLock2,
  Plus,
  Lock,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { SeverityBadge } from "@/components/SeverityBadge";
import {
  api,
  type ChecklistItem,
  type ScopeResult,
  type SecurityHeader,
} from "@/lib/api";
import { useScope } from "@/lib/scopeStore";
import { useFindings } from "@/lib/findingsStore";

export function WebAudit() {
  const { hosts } = useScope();
  const { addFinding } = useFindings();

  const [target, setTarget] = useState("http://localhost:3000");
  const [scope, setScope] = useState<ScopeResult | null>(null);
  const [checking, setChecking] = useState(false);

  const [items, setItems] = useState<ChecklistItem[]>([]);
  const [headers, setHeaders] = useState<SecurityHeader[]>([]);
  const [checked, setChecked] = useState<Record<string, boolean>>({});

  useEffect(() => {
    api.checklist().then((r) => setItems(r.items)).catch(() => {});
    api.headers().then((r) => setHeaders(r.headers)).catch(() => {});
  }, []);

  async function confirmScope() {
    if (!target.trim()) return;
    setChecking(true);
    try {
      setScope(await api.scopeCheck(target, hosts));
    } catch {
      setScope({
        allowed: false,
        host: null,
        isPrivate: false,
        reason: "Could not reach the API.",
      });
    } finally {
      setChecking(false);
    }
  }

  const unlocked = scope?.allowed ?? false;

  return (
    <div>
      <PageHeader
        icon={ShieldCheck}
        title="Web Audit"
        subtitle="OWASP Top 10 checklist for assets you own or run locally. Confirm scope to unlock."
      />

      <Card className="mb-6">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Lock className="h-4 w-4 text-neon-blue" /> 1. Confirm scope &amp; ownership
          </CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex gap-2">
            <Input
              value={target}
              onChange={(e) => setTarget(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && confirmScope()}
              placeholder="http://localhost:3000"
            />
            <Button onClick={confirmScope} disabled={checking || !target.trim()}>
              {checking ? <Loader2 className="h-4 w-4 animate-spin" /> : "Confirm scope"}
            </Button>
          </div>
          {scope && (
            <div
              className={`mt-4 rounded-lg border p-3 text-sm ${
                scope.allowed
                  ? "border-emerald-500/30 bg-emerald-500/10"
                  : "border-severity-critical/30 bg-severity-critical/10"
              }`}
            >
              <div className="flex items-center gap-2 font-semibold">
                {scope.allowed ? (
                  <ShieldCheck className="h-4 w-4 text-emerald-400" />
                ) : (
                  <ShieldX className="h-4 w-4 text-severity-critical" />
                )}
                {scope.allowed ? "Scope confirmed — audit unlocked" : "Blocked"}
              </div>
              <p className="mt-1 text-muted-foreground">{scope.reason}</p>
            </div>
          )}
        </CardContent>
      </Card>

      <div className={unlocked ? "" : "pointer-events-none select-none opacity-40"}>
        <h2 className="mb-3 flex items-center gap-2 text-lg font-semibold">
          <ListChecks className="h-5 w-5 text-neon-purple" /> 2. OWASP Top 10 Checklist
        </h2>
        <div className="space-y-3">
          {items.map((item) => (
            <Card key={item.id}>
              <CardContent className="p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-xs text-neon-blue">{item.id}</span>
                      <span className="font-semibold">{item.title}</span>
                      <SeverityBadge severity={item.severityHint} />
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {item.description}
                    </p>
                  </div>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      addFinding({
                        title: `${item.id} — ${item.title}`,
                        severity: item.severityHint,
                        description: item.description,
                        remediation: item.remediation.join(" "),
                        source: "audit",
                      })
                    }
                  >
                    <Plus className="h-3.5 w-3.5" /> To report
                  </Button>
                </div>
                <div className="mt-3 space-y-1.5">
                  {item.checks.map((c, i) => {
                    const key = `${item.id}-${i}`;
                    return (
                      <label
                        key={key}
                        className="flex cursor-pointer items-start gap-2 text-sm text-muted-foreground"
                      >
                        <input
                          type="checkbox"
                          className="mt-0.5 accent-neon-blue"
                          checked={!!checked[key]}
                          onChange={(e) =>
                            setChecked((p) => ({ ...p, [key]: e.target.checked }))
                          }
                        />
                        <span className={checked[key] ? "text-foreground" : ""}>{c}</span>
                      </label>
                    );
                  })}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>

        <h2 className="mb-3 mt-8 flex items-center gap-2 text-lg font-semibold">
          <FileLock2 className="h-5 w-5 text-neon-purple" /> 3. Recommended Security Headers
        </h2>
        <Card>
          <CardContent className="space-y-3 p-4">
            {headers.map((h) => (
              <div key={h.header} className="rounded-lg border border-border bg-background/40 p-3">
                <div className="font-mono text-sm text-neon-blue">{h.header}</div>
                <div className="mt-0.5 text-sm text-muted-foreground">{h.purpose}</div>
                <code className="mt-2 block rounded bg-[#0a0e1a] p-2 font-mono text-xs text-foreground/80">
                  {h.header}: {h.example}
                </code>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
