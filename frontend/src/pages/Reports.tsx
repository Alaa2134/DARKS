import { useState } from "react";
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

  // manual finding form
  const [mTitle, setMTitle] = useState("");
  const [mSev, setMSev] = useState<Severity>("medium");
  const [mDesc, setMDesc] = useState("");

  async function generate() {
    setLoading(true);
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
          impact: f.impact,
          remediation: f.remediation,
          evidence: f.evidence,
        })),
      });
      setMarkdown(res.markdown);
    } catch (e) {
      setMarkdown(`> Failed to generate report: ${e instanceof Error ? e.message : "error"}`);
    } finally {
      setLoading(false);
    }
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
              <Button onClick={addManual} disabled={!mTitle.trim()} variant="secondary">
                <Plus className="h-4 w-4" /> Add finding
              </Button>
            </CardContent>
          </Card>
        </div>

        <Card className="lg:sticky lg:top-8 lg:self-start">
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle>Report preview</CardTitle>
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
