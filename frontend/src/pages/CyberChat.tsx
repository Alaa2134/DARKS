import { useState } from "react";
import { MessagesSquare } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { ChatPanel } from "@/components/ChatPanel";
import { cn } from "@/lib/utils";

const MODES = [
  { id: "chat", label: "General" },
  { id: "webaudit", label: "Web Audit" },
  { id: "codereview", label: "Code Review" },
  { id: "loganalysis", label: "Log Analysis" },
  { id: "report", label: "Report" },
];

const SUGGESTIONS = [
  "Explain how XSS works in a safe demo",
  "Create an OWASP checklist for my local web app",
  "Suggest security headers for my React app",
  "Help me write a pentest report template",
];

export function CyberChat() {
  const [mode, setMode] = useState("chat");

  return (
    <div>
      <PageHeader
        icon={MessagesSquare}
        title="Cyber Chat Agent"
        subtitle="Safety-filtered, mode-aware AI assistant for ethical security work."
        actions={
          <div className="flex flex-wrap gap-1.5">
            {MODES.map((m) => (
              <button
                key={m.id}
                onClick={() => setMode(m.id)}
                className={cn(
                  "rounded-lg border px-3 py-1.5 text-xs font-medium transition-colors",
                  mode === m.id
                    ? "border-neon-blue/40 bg-neon-blue/15 text-neon-blue"
                    : "border-border text-muted-foreground hover:text-foreground"
                )}
              >
                {m.label}
              </button>
            ))}
          </div>
        }
      />
      <ChatPanel
        key={mode}
        mode={mode}
        greeting={`**Horus is ready** — mode: \`${mode}\`. Ask away. I help with learning, defending, CTFs, and testing assets you own. Harmful or unauthorized requests are refused.`}
        suggestions={SUGGESTIONS}
      />
    </div>
  );
}
