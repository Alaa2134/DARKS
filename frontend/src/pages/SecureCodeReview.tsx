import { useState } from "react";
import { FileCode2, Loader2, ScanLine, Plus, Check } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { SeverityBadge } from "@/components/SeverityBadge";
import { api, type ScanResult, type CodeFinding } from "@/lib/api";
import { useFindings } from "@/lib/findingsStore";
import type { Severity } from "@/lib/utils";

const SAMPLE = `// Paste your code here. Example with intentional issues:
const id = req.query.id;
const query = "SELECT * FROM users WHERE id = " + id;
db.query(query);

const apiKey = "EXAMPLE_FAKE_DEMO_TOKEN_do_not_use_1234567890";

app.get("/avatar", (req, res) => {
  res.sendFile(req.query.file);
});

element.innerHTML = req.body.comment;
res.cookie("session", token);`;

export function SecureCodeReview() {
  const { addFinding } = useFindings();
  const [code, setCode] = useState("");
  const [result, setResult] = useState<ScanResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [added, setAdded] = useState<Record<string, boolean>>({});

  async function run() {
    if (!code.trim()) return;
    setLoading(true);
    setAdded({});
    try {
      setResult(await api.deepScan(code));
    } catch {
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  function toReport(f: CodeFinding) {
    addFinding({
      title: f.title,
      severity: f.severity,
      description: `${f.why}\n\nLocation: line ${f.line}\n\n\`${f.snippet}\``,
      remediation: f.fix,
      source: "code-review",
    });
    setAdded((p) => ({ ...p, [f.id]: true }));
  }

  const order: Severity[] = ["critical", "high", "medium", "low", "info"];

  return (
    <div>
      <PageHeader
        icon={FileCode2}
        title="Secure Code Review"
        subtitle="Static heuristics flag injection, XSS, weak auth, secrets, bad CORS and more — each with a secure fix."
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle>Source code</CardTitle>
            <Button variant="ghost" size="sm" onClick={() => setCode(SAMPLE)}>
              Load sample
            </Button>
          </CardHeader>
          <CardContent>
            <Textarea
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="Paste code to review…"
              className="min-h-[360px] font-mono text-xs"
            />
            <Button onClick={run} disabled={loading || !code.trim()} className="mt-3 w-full">
              {loading ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <ScanLine className="h-4 w-4" />
              )}
              Run secure review
            </Button>
          </CardContent>
        </Card>

        <div>
          {result && (
            <div className="mb-4 flex flex-wrap gap-2">
              {order.map((s) =>
                result.summary.bySeverity[s] > 0 ? (
                  <div key={s} className="flex items-center gap-1.5">
                    <SeverityBadge severity={s} />
                    <span className="text-sm font-semibold">
                      {result.summary.bySeverity[s]}
                    </span>
                  </div>
                ) : null
              )}
              <span className="ml-auto self-center text-sm text-muted-foreground">
                {result.summary.total} finding(s)
              </span>
            </div>
          )}

          {result && (
            <div className="mb-4 flex flex-wrap gap-1.5">
              {result.engines.map((e) => (
                <span
                  key={e.name}
                  title={e.note}
                  className={`rounded-full border px-2.5 py-0.5 text-xs ${
                    e.ran
                      ? "border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
                      : "border-border bg-muted text-muted-foreground"
                  }`}
                >
                  {e.name}: {e.ran ? `${e.findingCount}` : "skipped"}
                </span>
              ))}
            </div>
          )}

          <div className="space-y-3">
            {result?.findings.length === 0 && (
              <Card>
                <CardContent className="p-6 text-center text-sm text-muted-foreground">
                  No issues detected by the static heuristics. (This is not a
                  guarantee — combine with manual review.)
                </CardContent>
              </Card>
            )}
            {result?.findings.map((f) => (
              <Card key={f.id}>
                <CardContent className="p-4">
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <SeverityBadge severity={f.severity} />
                      <span className="font-semibold">{f.title}</span>
                    </div>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={added[f.id]}
                      onClick={() => toReport(f)}
                    >
                      {added[f.id] ? (
                        <>
                          <Check className="h-3.5 w-3.5" /> Added
                        </>
                      ) : (
                        <>
                          <Plus className="h-3.5 w-3.5" /> To report
                        </>
                      )}
                    </Button>
                  </div>
                  <div className="mt-2 font-mono text-xs text-muted-foreground">
                    line {f.line}
                  </div>
                  <code className="mt-1 block overflow-x-auto rounded bg-[#0a0e1a] p-2 font-mono text-xs text-severity-high">
                    {f.snippet}
                  </code>
                  <p className="mt-2 text-sm text-muted-foreground">
                    <b className="text-foreground">Why:</b> {f.why}
                  </p>
                  <p className="mt-1.5 text-sm text-emerald-300/90">
                    <b className="text-emerald-400">Fix:</b> {f.fix}
                  </p>
                </CardContent>
              </Card>
            ))}
            {!result && (
              <Card>
                <CardContent className="p-6 text-center text-sm text-muted-foreground">
                  Paste code and run the review to see findings here.
                </CardContent>
              </Card>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
