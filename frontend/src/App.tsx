import { Routes, Route } from "react-router-dom";
import { Sidebar } from "@/components/Sidebar";
import { ScopeProvider } from "@/lib/scopeStore";
import { FindingsProvider } from "@/lib/findingsStore";
import { Dashboard } from "@/pages/Dashboard";
import { CyberChat } from "@/pages/CyberChat";
import { AgentConsole } from "@/pages/AgentConsole";
import { TargetScope } from "@/pages/TargetScope";
import { CtfHelper } from "@/pages/CtfHelper";
import { CtfToolkit } from "@/pages/CtfToolkit";
import { ThreatModel } from "@/pages/ThreatModel";
import { WebAudit } from "@/pages/WebAudit";
import { SecureCodeReview } from "@/pages/SecureCodeReview";
import { TerminalLogs } from "@/pages/TerminalLogs";
import { Reports } from "@/pages/Reports";
import { Settings } from "@/pages/Settings";

export default function App() {
  return (
    <ScopeProvider>
      <FindingsProvider>
      <div className="flex h-screen overflow-hidden">
        <Sidebar />
        <main className="grid-bg flex-1 overflow-y-auto">
          <div className="mx-auto max-w-6xl px-6 py-8">
            <Routes>
              <Route path="/" element={<Dashboard />} />
              <Route path="/agent" element={<AgentConsole />} />
              <Route path="/chat" element={<CyberChat />} />
              <Route path="/scope" element={<TargetScope />} />
              <Route path="/ctf" element={<CtfHelper />} />
              <Route path="/toolkit" element={<CtfToolkit />} />
              <Route path="/threat-model" element={<ThreatModel />} />
              <Route path="/audit" element={<WebAudit />} />
              <Route path="/code-review" element={<SecureCodeReview />} />
              <Route path="/logs" element={<TerminalLogs />} />
              <Route path="/reports" element={<Reports />} />
              <Route path="/settings" element={<Settings />} />
            </Routes>
          </div>
        </main>
      </div>
      </FindingsProvider>
    </ScopeProvider>
  );
}
