import { useEffect, useState } from "react";
import { Wrench, ArrowRight, Copy, Check } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { api } from "@/lib/api";

const OPS: { id: string; label: string; param?: string }[] = [
  { id: "base64-encode", label: "Base64 encode" },
  { id: "base64-decode", label: "Base64 decode" },
  { id: "hex-encode", label: "Hex encode" },
  { id: "hex-decode", label: "Hex decode" },
  { id: "url-encode", label: "URL encode" },
  { id: "url-decode", label: "URL decode" },
  { id: "rot13", label: "ROT13" },
  { id: "reverse", label: "Reverse" },
  { id: "binary-decode", label: "Binary → text" },
  { id: "caesar", label: "Caesar shift", param: "shift (e.g. 3)" },
  { id: "vigenere-decode", label: "Vigenère decode", param: "key" },
  { id: "hash-identify", label: "Identify hash" },
  { id: "jwt-decode", label: "Decode JWT" },
];

export function CtfToolkit() {
  const [op, setOp] = useState("base64-decode");
  const [input, setInput] = useState("");
  const [param, setParam] = useState("");
  const [output, setOutput] = useState("");
  const [note, setNote] = useState<string | undefined>();
  const [copied, setCopied] = useState(false);

  const active = OPS.find((o) => o.id === op)!;

  async function runTransform(targetOp = op) {
    if (!input.trim()) return;
    try {
      const r = await api.ctfTransform(targetOp, input, param || undefined);
      setOutput(r.output);
      setNote(r.note);
    } catch (e) {
      setOutput(`Error: ${e instanceof Error ? e.message : "request failed"}`);
      setNote(undefined);
    }
  }

  useEffect(() => {
    if (input.trim()) runTransform();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [op, param]);

  function copy() {
    navigator.clipboard.writeText(output);
    setCopied(true);
    setTimeout(() => setCopied(false), 1200);
  }

  return (
    <div>
      <PageHeader
        icon={Wrench}
        title="CTF Toolkit"
        subtitle="Safe local utilities for CTF & forensics — encoders, decoders, hash identification, and JWT decoding. No network, no cracking."
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-[200px_1fr]">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Operations</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1">
            {OPS.map((o) => (
              <button
                key={o.id}
                onClick={() => setOp(o.id)}
                className={cn(
                  "w-full rounded-lg px-3 py-1.5 text-left text-sm transition-colors",
                  op === o.id
                    ? "bg-neon-blue/15 text-neon-blue"
                    : "text-muted-foreground hover:bg-muted/50 hover:text-foreground"
                )}
              >
                {o.label}
              </button>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <span>{active.label}</span>
              <ArrowRight className="h-4 w-4 text-muted-foreground" />
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <Textarea
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder="Input…"
              className="min-h-[120px] font-mono text-xs"
            />
            {active.param && (
              <Input
                value={param}
                onChange={(e) => setParam(e.target.value)}
                placeholder={active.param}
                className="font-mono"
              />
            )}
            <Button onClick={() => runTransform()} disabled={!input.trim()}>
              Run
            </Button>

            <div className="relative">
              <div className="mb-1 flex items-center justify-between">
                <span className="text-xs font-medium text-muted-foreground">Output</span>
                {output && (
                  <Button variant="ghost" size="sm" onClick={copy}>
                    {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                    {copied ? "Copied" : "Copy"}
                  </Button>
                )}
              </div>
              <pre className="terminal max-h-[320px] min-h-[80px] overflow-auto whitespace-pre-wrap break-all text-foreground/90">
                {output || "…"}
              </pre>
              {note && <p className="mt-2 text-xs text-muted-foreground">{note}</p>}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
