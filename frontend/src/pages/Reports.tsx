import { useEffect, useState } from "react";
import {
  FileText,
  Loader2,
  Download,
  Trash2,
  Plus,
  FileDown,
  Eraser,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { SeverityBadge } from "@/components/SeverityBadge";
import { Markdown } from "@/components/Markdown";
import { api } from "@/lib/api";
import { useFindings } from "@/lib/findingsStore";
import { useScope } from "@/lib/scopeStore";
import type { Severity } from "@/lib/utils";

const SEVERITIES: Severity[] = ["critical", "high", "medium", "low", "info"];

export function Reports() {
  const { findings, addFinding, removeFinding, clear } = useFindings();
  const { hosts } = useScope();

  const [title, setTitle] = useState("Security Assessment Report");
  const [client, setClient] = useState("Internal / Lab Engagement");
  const [author, setAuthor] = useState("Horus Cyber Agent");
  const [markdown, setMarkdown] = useState("");
  const [loading, setLoading] = useState(false);
  const [saved, setSaved] = useState(false);
  const [recent, setRecent] = useState<
    { id: number; title: string; finding_count: number; created_at: string }[]
  >([]);

  useEffect(() => {
    api.listReports().then((r) => setRecent(r.reports)).catch(() => {});
  }, []);

  // manual finding form
  const [mTitle, setMTitle] = useState("");
  const [mSev, setMSev] = useState<Severity>("medium");
  const [mDesc, setMDesc] = useState("");
  const [mVector, setMVector] = useState("");
  const [mScore, setMScore] = useState<number | null>(null);

  async function scoreCvss() {
    if (!mVector.trim()) return;
    try {
      const r = await api.cvss(mVector.trim());
      setMScore(r.baseScore);
      setMSev(r.severity);
    } catch {
      setMScore(null);
    }
  }

  async function generate() {
    setLoading(true);
    setSaved(false);
    try {
      const res = await api.generateReport({
        title,
        client,
        author,
        scope: hosts.length ? hosts : undefined,
        findings: findings.map((f) => ({
          title: f.title,
          severity: f.severity,
          description: f.description,
          impact: f.impact ?? undefined,
          remediation: f.remediation ?? undefined,
          evidence: f.evidence ?? undefined,
        })),
      });
      setMarkdown(res.markdown);
      try {
        await api.saveReport({
          title,
          client,
          markdown: res.markdown,
          finding_count: findings.length,
        });
        setSaved(true);
        loadReports();
      } catch {
        /* persistence optional */
      }
    } catch (e) {
      setMarkdown(`> Failed to generate report: ${e instanceof Error ? e.message : "error"}`);
    } finally {
      setLoading(false);
    }
  }

  function loadReports() {
    api
      .listReports()
      .then((r) => setRecent(r.reports))
      .catch(() => {});
  }

  function download() {
    const blob = new Blob([markdown], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${title.replace(/\s+/g, "_").toLowerCase()}.md`;
    a.click();
    URL.revokeObjectURL(url);
  }

  function addManual() {
    if (!mTitle.trim()) return;
    addFinding({
      title: mTitle,
      severity: mSev,
      description: mDesc || "—",
      source: "manual",
    });
    setMTitle("");
    setMDesc("");
    setMSev("medium");
  }

  return (
    <div>
      <PageHeader
        icon={FileText}
        title="Reports"
        subtitle="Compile findings into a professional pentest-style report and export Markdown."
        actions={
          <div className="flex gap-2">
            <Button variant="outline" onClick={clear} disabled={!findings.length}>
              <Eraser className="h-4 w-4" /> Clear findings
            </Button>
            <Button onClick={generate} disabled={loading}>
              {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileDown className="h-4 w-4" />}
              Generate report
            </Button>
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Report metadata</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="space-y-1.5">
                <Label>Title</Label>
                <Input value={title} onChange={(e) => setTitle(e.target.value)} />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label>Client / Engagement</Label>
                  <Input value={client} onChange={(e) => setClient(e.target.value)} />
                </div>
                <div className="space-y-1.5">
                  <Label>Author</Label>
                  <Input value={author} onChange={(e) => setAuthor(e.target.value)} />
                </div>
              </div>
              {hosts.length > 0 && (
                <p className="text-xs text-muted-foreground">
                  Scope auto-filled from Target Scope: {hosts.join(", ")}
                </p>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Findings ({findings.length})</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2">
              {findings.length === 0 && (
                <p className="text-sm text-muted-foreground">
                  No findings yet. Add them from Web Audit, Code Review, Logs, or
                  the manual form below.
                </p>
              )}
              {findings.map((f) => (
                <div
                  key={f.id}
                  className="flex items-start justify-between gap-2 rounded-lg border border-border bg-background/40 p-3"
                >
                  <div>
                    <div className="flex items-center gap-2">
                      <SeverityBadge severity={f.severity} />
                      <span className="text-sm font-medium">{f.title}</span>
                    </div>
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      source: {f.source}
                    </div>
                  </div>
                  <Button variant="ghost" size="icon" onClick={() => removeFinding(f.id)}>
                    <Trash2 className="h-4 w-4 text-severity-high" />
                  </Button>
                </div>
              ))}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <Plus className="h-4 w-4 text-neon-blue" /> Add a manual finding
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <Input
                placeholder="Finding title"
                value={mTitle}
                onChange={(e) => setMTitle(e.target.value)}
              />
              <div className="flex flex-wrap gap-1.5">
                {SEVERITIES.map((s) => (
                  <button key={s} onClick={() => setMSev(s)} className="focus:outline-none">
                    <span className={mSev === s ? "ring-2 ring-neon-blue rounded-md" : ""}>
                      <SeverityBadge severity={s} />
                    </span>
                  </button>
                ))}
              </div>
              <Textarea
                placeholder="Description"
                value={mDesc}
                onChange={(e) => setMDesc(e.target.value)}
              />
              <div className="flex items-center gap-2">
                <Input
                  placeholder="CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
                  value={mVector}
                  onChange={(e) => setMVector(e.target.value)}
                  className="font-mono text-xs"
                />
                <Button variant="outline" onClick={scoreCvss} disabled={!mVector.trim()}>
                  Score
                </Button>
                {mScore !== null && (
                  <span className="shrink-0 rounded-md border border-neon-blue/40 bg-neon-blue/10 px-2 py-1 text-sm font-bold text-neon-blue">
                    {mScore}
                  </span>
                )}
              </div>
              <Button onClick={addManual} disabled={!mTitle.trim()} variant="secondary">
                <Plus className="h-4 w-4" /> Add finding
              </Button>
            </CardContent>
          </Card>

          {recent.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle>Saved reports ({recent.length})</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                {recent.map((r) => (
                  <button
                    key={r.id}
                    onClick={() =>
                      api.getReport(r.id).then((res) => {
                        setMarkdown(res.report.markdown);
                        setSaved(false);
                      })
                    }
                    className="flex w-full items-center justify-between rounded-lg border border-border bg-background/40 px-3 py-2 text-left text-sm hover:border-neon-blue/40"
                  >
                    <span className="truncate">{r.title}</span>
                    <span className="ml-2 shrink-0 text-xs text-muted-foreground">
                      {r.finding_count} · {new Date(r.created_at).toLocaleDateString()}
                    </span>
                  </button>
                ))}
              </CardContent>
            </Card>
          )}
        </div>

        <Card className="lg:sticky lg:top-8 lg:self-start">
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              Report preview
              {saved && (
                <span className="rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2 py-0.5 text-xs text-emerald-300">
                  saved
                </span>
              )}
            </CardTitle>
            {markdown && (
              <Button variant="outline" size="sm" onClick={download}>
                <Download className="h-4 w-4" /> Export .md
              </Button>
            )}
          </CardHeader>
          <CardContent>
            {markdown ? (
              <div className="max-h-[70vh] overflow-y-auto rounded-lg border border-border bg-background/40 p-4">
                <Markdown>{markdown}</Markdown>
              </div>
            ) : (
              <div className="flex h-64 items-center justify-center text-sm text-muted-foreground">
                Generate a report to preview it here.
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
