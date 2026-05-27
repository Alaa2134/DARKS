import { Flag, Globe, Lock, Search, Cpu, Bug, Eye } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { ChatPanel } from "@/components/ChatPanel";
import { Card, CardContent } from "@/components/ui/card";

const CATEGORIES = [
  { id: "web", name: "Web", icon: Globe, desc: "Logic & input-handling flaws" },
  { id: "crypto", name: "Crypto", icon: Lock, desc: "Weak / misused ciphers" },
  { id: "forensics", name: "Forensics", icon: Search, desc: "Hidden data in files/captures" },
  { id: "rev", name: "Reverse Eng.", icon: Cpu, desc: "Understand binary logic" },
  { id: "pwn", name: "Pwn", icon: Bug, desc: "Memory-safety in sandbox" },
  { id: "osint", name: "OSINT", icon: Eye, desc: "Public, lawful sources only" },
];

export function CtfHelper() {
  return (
    <div>
      <PageHeader
        icon={Flag}
        title="CTF Helper"
        subtitle="Conceptual methodology, graduated hints, and write-ups. Works only against the challenge sandbox you were given."
      />

      <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
        {CATEGORIES.map((c) => (
          <Card key={c.id} className="text-center">
            <CardContent className="flex flex-col items-center gap-1.5 p-4">
              <c.icon className="h-5 w-5 text-neon-blue" />
              <div className="text-sm font-semibold">{c.name}</div>
              <div className="text-[11px] leading-tight text-muted-foreground">
                {c.desc}
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      <ChatPanel
        mode="ctf"
        greeting="**CTF Helper ready.** Tell me the category (web, crypto, forensics, rev, pwn, osint) and what you've observed. I'll give methodology and graduated hints — and help you write it up afterwards."
        placeholder="e.g. I have a web challenge with a login form and a suspicious cookie…"
        suggestions={[
          "Give me a web exploitation methodology",
          "How do I approach a crypto RSA challenge?",
          "Forensics: I have a pcap file, where do I start?",
          "Explain reverse engineering triage steps",
        ]}
      />
    </div>
  );
}
