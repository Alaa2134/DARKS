import { useState } from "react";
import { Crosshair, Plus, Trash2, ShieldCheck, ShieldX, Loader2 } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useScope } from "@/lib/scopeStore";
import { api, type ScopeResult } from "@/lib/api";

export function TargetScope() {
  const { scope, addScope, removeScope, hosts } = useScope();
  const [host, setHost] = useState("");
  const [note, setNote] = useState("");
  const [attested, setAttested] = useState(false);

  const [checkTarget, setCheckTarget] = useState("");
  const [result, setResult] = useState<ScopeResult | null>(null);
  const [checking, setChecking] = useState(false);

  function add() {
    if (!host.trim() || !attested) return;
    addScope(host, note || "Ownership attested by operator");
    setHost("");
    setNote("");
    setAttested(false);
  }

  async function check() {
    if (!checkTarget.trim()) return;
    setChecking(true);
    try {
      setResult(await api.scopeCheck(checkTarget, hosts));
    } catch {
      setResult({
        allowed: false,
        host: null,
        isPrivate: false,
        reason: "Could not reach the API to validate the target.",
      });
    } finally {
      setChecking(false);
    }
  }

  return (
    <div>
      <PageHeader
        icon={Crosshair}
        title="Target Scope"
        subtitle="Declare the assets you own. Active testing guidance is limited to these + local/private hosts."
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Plus className="h-4 w-4 text-neon-blue" /> Add an owned asset
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="host">Hostname or URL</Label>
              <Input
                id="host"
                placeholder="myapp.local or staging.mycompany.com"
                value={host}
                onChange={(e) => setHost(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="note">Note (engagement / authorization reference)</Label>
              <Input
                id="note"
                placeholder="e.g. personal lab, written authorization #1234"
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
            </div>
            <label className="flex items-start gap-2 rounded-lg border border-border bg-background/40 p-3 text-sm">
              <input
                type="checkbox"
                checked={attested}
                onChange={(e) => setAttested(e.target.checked)}
                className="mt-0.5 accent-neon-blue"
              />
              <span className="text-muted-foreground">
                I confirm I <b className="text-foreground">own</b> this asset or have{" "}
                <b className="text-foreground">explicit written authorization</b> to test it.
              </span>
            </label>
            <Button onClick={add} disabled={!host.trim() || !attested} className="w-full">
              <Plus className="h-4 w-4" /> Add to scope
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-neon-purple" /> Scope checker
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex gap-2">
              <Input
                placeholder="http://localhost:3000 or https://example.com"
                value={checkTarget}
                onChange={(e) => setCheckTarget(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && check()}
              />
              <Button onClick={check} disabled={checking || !checkTarget.trim()}>
                {checking ? <Loader2 className="h-4 w-4 animate-spin" /> : "Check"}
              </Button>
            </div>
            {result && (
              <div
                className={`rounded-lg border p-4 ${
                  result.allowed
                    ? "border-emerald-500/30 bg-emerald-500/10"
                    : "border-severity-critical/30 bg-severity-critical/10"
                }`}
              >
                <div className="mb-1 flex items-center gap-2 font-semibold">
                  {result.allowed ? (
                    <>
                      <ShieldCheck className="h-4 w-4 text-emerald-400" />
                      <span className="text-emerald-400">In scope — testing guidance allowed</span>
                    </>
                  ) : (
                    <>
                      <ShieldX className="h-4 w-4 text-severity-critical" />
                      <span className="text-severity-critical">Out of scope — blocked</span>
                    </>
                  )}
                </div>
                <p className="text-sm text-muted-foreground">{result.reason}</p>
                {result.host && (
                  <p className="mt-2 font-mono text-xs text-muted-foreground">
                    host: {result.host} · {result.isPrivate ? "private/lab" : "public"}
                  </p>
                )}
              </div>
            )}
            <p className="text-xs text-muted-foreground">
              Local & private hosts (localhost, 127.x, 10.x, 192.168.x, *.local,
              *.test) are always allowed. Public hosts must be added above.
            </p>
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>Confirmed scope ({scope.length})</CardTitle>
        </CardHeader>
        <CardContent>
          {scope.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No owned assets added yet. Local/private lab hosts work without
              being listed.
            </p>
          ) : (
            <div className="space-y-2">
              {scope.map((s) => (
                <div
                  key={s.host}
                  className="flex items-center justify-between rounded-lg border border-border bg-background/40 px-4 py-2.5"
                >
                  <div>
                    <div className="font-mono text-sm text-foreground">{s.host}</div>
                    <div className="text-xs text-muted-foreground">
                      {s.note} · attested {new Date(s.attestedAt).toLocaleString()}
                    </div>
                  </div>
                  <Button variant="ghost" size="icon" onClick={() => removeScope(s.host)}>
                    <Trash2 className="h-4 w-4 text-severity-high" />
                  </Button>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
