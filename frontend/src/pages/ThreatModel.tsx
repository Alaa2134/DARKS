import { useState } from "react";
import { ShieldHalf, Loader2, Plus, GitBranch } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { SeverityBadge } from "@/components/SeverityBadge";
import { Badge } from "@/components/ui/badge";
import { api, type ThreatModelResult } from "@/lib/api";
import { useFindings } from "@/lib/findingsStore";

const CATEGORY_COLORS: Record<string, string> = {
  Spoofing: "text-neon-blue",
  Tampering: "text-severity-high",
  Repudiation: "text-neon-purple",
  "Information Disclosure": "text-severity-medium",
  "Denial of Service": "text-severity-low",
  "Elevation of Privilege": "text-severity-critical",
};

export function ThreatModel() {
  const { addFinding } = useFindings();
  const [system, setSystem] = useState("");
  const [result, setResult] = useState<ThreatModelResult | null>(null);
  const [loading, setLoading] = useState(false);

  async function run() {
    if (!system.trim()) return;
    setLoading(true);
    try {
      setResult(await api.threatModel(system));
    } catch {
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div>
      <PageHeader
        icon={ShieldHalf}
        title="Threat Model"
        subtitle="Generate a STRIDE threat model for a system you own — threats per component with mitigations and trust boundaries."
      />

      <Card className="mb-6">
        <CardHeader className="flex-row items-center justify-between">
          <CardTitle>Describe your system</CardTitle>
          <Button
            variant="ghost"
            size="sm"
            onClick={() =>
              setSystem(
                "A web app with a React frontend, a REST API, user login/auth, a PostgreSQL database, file upload, and an admin panel."
              )
            }
          >
            Load example
          </Button>
        </CardHeader>
        <CardContent>
          <Textarea
            value={system}
            onChange={(e) => setSystem(e.target.value)}
            placeholder="Describe the components, data flows, and trust boundaries…"
            className="min-h-[100px]"
          />
          <Button onClick={run} disabled={loading || !system.trim()} className="mt-3">
            {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <GitBranch className="h-4 w-4" />}
            Generate STRIDE model
          </Button>
        </CardContent>
      </Card>

      {result && (
        <>
          <div className="mb-4 flex flex-wrap gap-2">
            <Badge variant="muted">Components: {result.components.join(", ")}</Badge>
            <Badge variant="muted">{result.threats.length} threats</Badge>
          </div>

          <Card className="mb-6">
            <CardHeader>
              <CardTitle className="text-sm">Trust boundaries</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1.5">
              {result.trustBoundaries.map((b, i) => (
                <div key={i} className="text-sm text-muted-foreground">
                  • {b}
                </div>
              ))}
            </CardContent>
          </Card>

          <div className="space-y-3">
            {result.threats.map((t, i) => (
              <Card key={i}>
                <CardContent className="p-4">
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className={`text-sm font-semibold ${CATEGORY_COLORS[t.category] ?? ""}`}>
                        {t.category}
                      </span>
                      <Badge variant="muted">{t.component}</Badge>
                      <SeverityBadge severity={t.severityHint} />
                    </div>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() =>
                        addFinding({
                          title: `${t.category} — ${t.component}`,
                          severity: t.severityHint,
                          description: t.threat,
                          remediation: t.mitigation,
                          source: "manual",
                        })
                      }
                    >
                      <Plus className="h-3.5 w-3.5" /> To report
                    </Button>
                  </div>
                  <p className="mt-2 text-sm text-muted-foreground">{t.threat}</p>
                  <p className="mt-1.5 text-sm text-emerald-300/90">
                    <b className="text-emerald-400">Mitigation:</b> {t.mitigation}
                  </p>
                </CardContent>
              </Card>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
