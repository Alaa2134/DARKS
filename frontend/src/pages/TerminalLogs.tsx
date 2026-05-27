import { useEffect, useState } from "react";
import {
  Terminal,
  Play,
  Loader2,
  ScanLine,
  ShieldX,
  CheckCircle2,
  Plus,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { SeverityBadge } from "@/components/SeverityBadge";
import {
  api,
  type AllowlistInfo,
  type CommandResult,
  type LogAnalysisResult,
} from "@/lib/api";
import { useFindings } from "@/lib/findingsStore";

const SAMPLE_LOG = `192.0.2.10 - - "GET /?id=1' OR 1=1-- HTTP/1.1" 200
192.0.2.10 - - "GET /?q=<script>alert(1)</script> HTTP/1.1" 200
198.51.100.5 - - "GET /../../etc/passwd HTTP/1.1" 404
203.0.113.7 - - "POST /login HTTP/1.1" 401 failed password
203.0.113.7 - - "POST /login HTTP/1.1" 401 failed password
203.0.113.7 - - "POST /login HTTP/1.1" 401 failed password
198.51.100.9 - sqlmap/1.7 "GET /search?q=1 UNION SELECT password FROM users"
10.0.0.4 - - "GET /api/data HTTP/1.1" 500`;

export function TerminalLogs() {
  return (
    <div>
      <PageHeader
        icon={Terminal}
        title="Terminal &amp; Logs"
        subtitle="An allowlist-only command runner and a defensive log analyzer."
      />
      <Tabs defaultValue="runner">
        <TabsList>
          <TabsTrigger value="runner">
            <Terminal className="h-4 w-4" /> Command Runner
          </TabsTrigger>
          <TabsTrigger value="logs">
            <ScanLine className="h-4 w-4" /> Log Analyzer
          </TabsTrigger>
        </TabsList>
        <TabsContent value="runner">
          <CommandRunner />
        </TabsContent>
        <TabsContent value="logs">
          <LogAnalyzer />
        </TabsContent>
      </Tabs>
    </div>
  );
}

function CommandRunner() {
  const [allowlist, setAllowlist] = useState<AllowlistInfo | null>(null);
  const [command, setCommand] = useState("");
  const [history, setHistory] = useState<
    { command: string; result: CommandResult }[]
  >([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    api.allowlist().then(setAllowlist).catch(() => {});
  }, []);

  async function run() {
    if (!command.trim()) return;
    setLoading(true);
    try {
      const result = await api.runCommand(command);
      setHistory((h) => [{ command, result }, ...h]);
    } catch (e) {
      setHistory((h) => [
        {
          command,
          result: {
            allowed: false,
            ran: false,
            reason: e instanceof Error ? e.message : "Request failed",
          },
        },
        ...h,
      ]);
    } finally {
      setLoading(false);
      setCommand("");
    }
  }

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
      <div className="lg:col-span-2">
        <Card>
          <CardHeader>
            <CardTitle>Run a command (workspace-sandboxed, allowlist only)</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex gap-2">
              <div className="flex flex-1 items-center gap-2 rounded-lg border border-input bg-[#0a0e1a] px-3">
                <span className="font-mono text-sm text-neon-blue">$</span>
                <Input
                  value={command}
                  onChange={(e) => setCommand(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && run()}
                  placeholder="npm test"
                  className="border-0 bg-transparent px-0 font-mono focus-visible:ring-0"
                />
              </div>
              <Button onClick={run} disabled={loading || !command.trim()}>
                {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
                Run
              </Button>
            </div>

            <div className="mt-4 space-y-3">
              {history.length === 0 && (
                <div className="terminal text-muted-foreground">
                  Output will appear here. Try <code>git status</code>,{" "}
                  <code>node -v</code>, or <code>npm test</code>.
                </div>
              )}
              {history.map((h, i) => (
                <div key={i} className="terminal">
                  <div className="mb-1 flex items-center gap-2">
                    <span className="text-neon-blue">$</span>
                    <span className="text-foreground">{h.command}</span>
                    {h.result.allowed ? (
                      h.result.ran ? (
                        <Badge variant="muted" className="ml-auto">
                          exit {String(h.result.exitCode)} · {h.result.durationMs}ms
                        </Badge>
                      ) : (
                        <Badge variant="muted" className="ml-auto">
                          not run
                        </Badge>
                      )
                    ) : (
                      <span className="ml-auto inline-flex items-center gap-1 text-xs text-severity-critical">
                        <ShieldX className="h-3.5 w-3.5" /> blocked
                      </span>
                    )}
                  </div>
                  {h.result.reason && (
                    <div className="text-severity-high">{h.result.reason}</div>
                  )}
                  {h.result.stdout && (
                    <pre className="whitespace-pre-wrap text-foreground/80">
                      {h.result.stdout}
                    </pre>
                  )}
                  {h.result.stderr && (
                    <pre className="whitespace-pre-wrap text-severity-high/80">
                      {h.result.stderr}
                    </pre>
                  )}
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="space-y-4">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <CheckCircle2 className="h-4 w-4 text-emerald-400" /> Allowed
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-1.5">
            {allowlist?.allowed.map((c) => (
              <div key={c.bin} className="text-sm">
                <code className="text-neon-blue">{c.bin}</code>
                <span className="ml-2 text-xs text-muted-foreground">{c.description}</span>
              </div>
            ))}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldX className="h-4 w-4 text-severity-critical" /> Always blocked
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-1.5">
            {allowlist?.blocked.map((b) => (
              <Badge key={b} variant="muted" className="border-severity-critical/30">
                {b}
              </Badge>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function LogAnalyzer() {
  const { addFinding } = useFindings();
  const [log, setLog] = useState("");
  const [result, setResult] = useState<LogAnalysisResult | null>(null);
  const [loading, setLoading] = useState(false);

  async function run() {
    if (!log.trim()) return;
    setLoading(true);
    try {
      setResult(await api.analyzeLogs(log));
    } catch {
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
      <Card>
        <CardHeader className="flex-row items-center justify-between">
          <CardTitle>Paste logs (access / auth / WAF / error)</CardTitle>
          <Button variant="ghost" size="sm" onClick={() => setLog(SAMPLE_LOG)}>
            Load sample
          </Button>
        </CardHeader>
        <CardContent>
          <Textarea
            value={log}
            onChange={(e) => setLog(e.target.value)}
            placeholder="Paste log lines…"
            className="min-h-[360px] font-mono text-xs"
          />
          <Button onClick={run} disabled={loading || !log.trim()} className="mt-3 w-full">
            {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <ScanLine className="h-4 w-4" />}
            Analyze defensively
          </Button>
        </CardContent>
      </Card>

      <div className="space-y-3">
        {result && (
          <p className="text-sm text-muted-foreground">
            Scanned {result.totalLines} line(s) · {result.summary.total} pattern(s) detected.
          </p>
        )}
        {result?.findings.map((f) => (
          <Card key={f.id}>
            <CardContent className="p-4">
              <div className="flex items-start justify-between gap-2">
                <div className="flex items-center gap-2">
                  <SeverityBadge severity={f.severity} />
                  <span className="font-semibold">{f.title}</span>
                  <Badge variant="muted">{f.count}×</Badge>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() =>
                    addFinding({
                      title: f.title,
                      severity: f.severity,
                      description: `${f.explanation}\n\nObserved ${f.count} time(s). Example:\n\`${f.examples[0] ?? ""}\``,
                      remediation: f.recommendation,
                      source: "log",
                    })
                  }
                >
                  <Plus className="h-3.5 w-3.5" /> To report
                </Button>
              </div>
              <p className="mt-2 text-sm text-muted-foreground">{f.explanation}</p>
              {f.examples.map((ex, i) => (
                <code
                  key={i}
                  className="mt-1.5 block overflow-x-auto rounded bg-[#0a0e1a] p-2 font-mono text-xs text-severity-high/90"
                >
                  {ex}
                </code>
              ))}
              <p className="mt-2 text-sm text-emerald-300/90">
                <b className="text-emerald-400">Recommendation:</b> {f.recommendation}
              </p>
            </CardContent>
          </Card>
        ))}
        {result?.findings.length === 0 && (
          <Card>
            <CardContent className="p-6 text-center text-sm text-muted-foreground">
              No suspicious patterns detected in the provided logs.
            </CardContent>
          </Card>
        )}
        {!result && (
          <Card>
            <CardContent className="p-6 text-center text-sm text-muted-foreground">
              Paste logs and analyze to see defensive findings here.
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
