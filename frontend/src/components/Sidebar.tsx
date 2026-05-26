import { NavLink } from "react-router-dom";
import {
  LayoutDashboard,
  MessagesSquare,
  Crosshair,
  Flag,
  ShieldCheck,
  FileCode2,
  Terminal,
  FileText,
  Settings,
  Eye,
  Bot,
  Wrench,
  ShieldHalf,
} from "lucide-react";
import { cn } from "@/lib/utils";

const NAV = [
  { to: "/", label: "Dashboard", icon: LayoutDashboard, end: true },
  { to: "/agent", label: "Agent Console", icon: Bot },
  { to: "/chat", label: "Cyber Chat Agent", icon: MessagesSquare },
  { to: "/scope", label: "Target Scope", icon: Crosshair },
  { to: "/ctf", label: "CTF Helper", icon: Flag },
  { to: "/toolkit", label: "CTF Toolkit", icon: Wrench },
  { to: "/audit", label: "Web Audit", icon: ShieldCheck },
  { to: "/threat-model", label: "Threat Model", icon: ShieldHalf },
  { to: "/code-review", label: "Secure Code Review", icon: FileCode2 },
  { to: "/logs", label: "Terminal Logs", icon: Terminal },
  { to: "/reports", label: "Reports", icon: FileText },
  { to: "/settings", label: "Settings", icon: Settings },
];

export function Sidebar() {
  return (
    <aside className="flex w-64 flex-col border-r border-border bg-card/40 backdrop-blur-sm">
      <div className="flex items-center gap-3 border-b border-border px-5 py-5">
        <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-gradient-to-br from-neon-blue to-neon-purple shadow-neon">
          <Eye className="h-5 w-5 text-background" />
        </div>
        <div>
          <div className="text-lg font-bold leading-tight neon-text">Horus</div>
          <div className="text-[10px] uppercase tracking-widest text-muted-foreground">
            Cyber Agent
          </div>
        </div>
      </div>

      <nav className="flex-1 space-y-1 overflow-y-auto p-3">
        {NAV.map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-all",
                isActive
                  ? "bg-gradient-to-r from-neon-blue/15 to-neon-purple/15 text-foreground shadow-sm ring-1 ring-neon-blue/20"
                  : "text-muted-foreground hover:bg-muted/50 hover:text-foreground"
              )
            }
          >
            <Icon className="h-4 w-4 shrink-0" />
            {label}
          </NavLink>
        ))}
      </nav>

      <div className="border-t border-border p-4">
        <div className="rounded-lg border border-neon-blue/20 bg-neon-blue/5 p-3 text-xs text-muted-foreground">
          <div className="mb-1 flex items-center gap-1.5 font-semibold text-neon-blue">
            <ShieldCheck className="h-3.5 w-3.5" />
            Ethical Mode
          </div>
          Safety guardrails are always on. Owned / lab targets only.
        </div>
      </div>
    </aside>
  );
}
