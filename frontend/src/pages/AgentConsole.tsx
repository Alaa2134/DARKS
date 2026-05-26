import { useRef, useState } from "react";
import {
  Bot,
  Loader2,
  Play,
  StopCircle,
  ListChecks,
  CheckCircle2,
  XCircle,
  BookOpen,
  ShieldAlert,
  FilePlus2,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { Markdown } from "@/components/Markdown";
import { streamAgent, type AgentEvent, type ReportFindingInput } from "@/lib/api";
import { useScope } from "@/lib/scopeStore";
import { useFindings } from "@/lib/findingsStore";
import { cn } from "@/lib/utils";

interface StepView {
  tool: string;
  input: string;
  summary?: string;
  ok?: boolean;
}

const EXAMPLE = "Audit my local web app using OWASP Top 10, review the code below, then summarize a report.";

export function AgentConsole() {
  const { hosts } = useScope();
  const { addMany } = useFindings();

  const [goal, setGoal] = useState("");
  const [target, setTarget] = useState("");
  const [code, setCode] = useState("");
  const [running, setRunning] = useState(false);

  const [plan, setPlan] = useState<string[]>([]);
  const [steps, setSteps] = useState<StepView[]>([]);
  const [sources, setSources] = useState<{ id: string; title: string; source: string }[]>([]);
  const [answer, setAnswer] = useState("");
  const [refusal, setRefusal] = useState<{ reason: string; safeAlternative?: string } | null>(
    null
  );
  const [findings, setFindings] = useState<ReportFindingInput[]>([]);
  const [sentToReport, setSentToReport] = useState(false);

  const abortRef = useRef<AbortController | null>(null);

  function reset() {
    setPlan([]);
    setSteps([]);
    setSources([]);
    setAnswer("");
    setRefusal(null);
    setFindings([]);
    setSentToReport(false);
  }

  async function run() {
    if (!goal.trim() || running) return;
    reset();
    setRunning(true);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      await streamAgent(
        {
          goal,
          target: target.trim() || undefined,
          code: code.trim() || undefined,
          confirmedScope: hosts,
        },
        (e: AgentEvent) => {
          switch (e.type) {
            case "plan":
              setPlan(e.steps);
              break;
            case "step":
              setSteps((s) => [...s, { tool: e.tool, input: e.input }]);
              break;
            case "tool_result":
              setSteps((s) => {
                const copy = [...s];
                const idx = copy.map((x) => x.tool).lastIndexOf(e.tool);
                if (idx >= 0) copy[idx] = { ...copy[idx], summary: e.summary, ok: e.ok };
                return copy;
              });
              break;
            case "sources":
              setSources(e.sources);
              break;
            case "token":
              setAnswer((a) => a + e.text);
              break;
            case "refused":
              setRefusal({ reason: e.reason, safeAlternative: e.safeAlternative });
              break;
            case "done":
              setFindings(e.findings);
              break;
            case "error":
              setAnswer((a) => a + `\n\n> Error: ${e.message}`);
              break;
          }
        },
        ctrl.signal
      );
    } catch (err) {
      if (!ctrl.signal.aborted) {
        setAnswer((a) => a + `\n\n> Could not reach the agent: ${err instanceof Error ? err.message : "error"}`);
      }
    } finally {
      setRunning(false);
      abortRef.current = null;
    }
  }

  function stop() {
    abortRef.current?.abort();
    setRunning(false);
  }

  async function sendToReport() {
    if (findings.length === 0) return;
    await addMany(
      findings.map((f) => ({
        title: f.title,
        severity: f.severity,
        description: f.description,
        impact: f.impact,
        remediation: f.remediation,
        evidence: f.evidence,
        source: "audit" as const,
      }))
    );
    setSentToReport(true);
  }

  return (
    <div>
      <PageHeader
        icon={Bot}
        title="Agent Console"
        subtitle="Give a goal — the agent plans, runs safe local tools (scope, OWASP, code review, logs), grounds with the knowledge base, and streams a synthesized answer."
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle>Mission</CardTitle>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setGoal(EXAMPLE);
                setTarget("http://localhost:3000");
                setCode('const q = "SELECT * FROM users WHERE id=" + req.query.id;\nelement.innerHTML = req.body.comment;');
              }}
            >
              Load demo
            </Button>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="space-y-1.5">
              <Label>Goal</Label>
              <Textarea
                value={goal}
                onChange={(e) => setGoal(e.target.value)}
                placeholder="e.g. Audit my local app with OWASP and review this code…"
                className="min-h-[80px]"
              />
            </div>
            <div className="space-y-1.5">
              <Label>Target (optional — local/owned only)</Label>
              <Input
                value={target}
                onChange={(e) => setTarget(e.target.value)}
                placeholder="http://localhost:3000"
              />
            </div>
            <div className="space-y-1.5">
              <Label>Code to review (optional)</Label>
              <Textarea
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="Paste code the agent should review…"
                className="min-h-[120px] font-mono text-xs"
              />
            </div>
            <div className="flex gap-2">
              <Button onClick={run} disabled={running || !goal.trim()} className="flex-1">
                {running ? <Loader2 className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
                Run agent
              </Button>
              {running && (
                <Button variant="outline" onClick={stop}>
                  <StopCircle className="h-4 w-4" /> Stop
                </Button>
              )}
            </div>
          </CardContent>
        </Card>

        <div className="space-y-4">
          {refusal && (
            <Card className="border-severity-high/40">
              <CardContent className="p-4">
                <div className="flex items-center gap-2 font-semibold text-severity-high">
                  <ShieldAlert className="h-4 w-4" /> Refused by safety policy
                </div>
                <p className="mt-1 text-sm text-muted-foreground">{refusal.reason}</p>
                {refusal.safeAlternative && (
                  <p className="mt-2 text-sm text-emerald-300/90">
                    <b className="text-emerald-400">Try instead:</b> {refusal.safeAlternative}
                  </p>
                )}
              </CardContent>
            </Card>
          )}

          {plan.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2 text-sm">
                  <ListChecks className="h-4 w-4 text-neon-purple" /> Plan
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-1.5">
                {plan.map((s, i) => (
                  <div key={i} className="text-sm text-muted-foreground">
                    {i + 1}. {s}
                  </div>
                ))}
              </CardContent>
            </Card>
          )}

          {steps.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-sm">Execution</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                {steps.map((s, i) => (
                  <div key={i} className="rounded-lg border border-border bg-background/40 p-2.5">
                    <div className="flex items-center gap-2">
                      {s.summary === undefined ? (
                        <Loader2 className="h-3.5 w-3.5 animate-spin text-neon-blue" />
                      ) : s.ok ? (
                        <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
                      ) : (
                        <XCircle className="h-3.5 w-3.5 text-severity-high" />
                      )}
                      <code className="text-xs text-neon-blue">{s.tool}</code>
                    </div>
                    {s.summary && (
                      <p className="mt-1 pl-5 text-xs text-muted-foreground">{s.summary}</p>
                    )}
                  </div>
                ))}
              </CardContent>
            </Card>
          )}

          {sources.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2 text-sm">
                  <BookOpen className="h-4 w-4 text-neon-blue" /> Grounded sources
                </CardTitle>
              </CardHeader>
              <CardContent className="flex flex-wrap gap-1.5">
                {sources.map((s) => (
                  <Badge key={s.id} variant="muted" title={s.title}>
                    {s.id}
                  </Badge>
                ))}
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {(answer || findings.length > 0) && (
        <Card className="mt-6">
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              <Bot className="h-4 w-4 text-neon-blue" /> Agent answer
              {running && <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground" />}
            </CardTitle>
            {findings.length > 0 && (
              <Button variant="outline" size="sm" onClick={sendToReport} disabled={sentToReport}>
                <FilePlus2 className="h-4 w-4" />
                {sentToReport ? "Sent to report" : `Send ${findings.length} findings to report`}
              </Button>
            )}
          </CardHeader>
          <CardContent>
            <div className={cn("rounded-lg border border-border bg-background/40 p-4")}>
              <Markdown>{answer || "_…_"}</Markdown>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
