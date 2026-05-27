import { useEffect, useRef, useState } from "react";
import { Send, Loader2, ShieldAlert, Bot, User } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Markdown } from "@/components/Markdown";
import { api, type ChatMessage } from "@/lib/api";
import { cn } from "@/lib/utils";

interface DisplayMessage extends ChatMessage {
  refused?: boolean;
}

export function ChatPanel({
  mode,
  greeting,
  suggestions = [],
  placeholder = "Ask a security question…",
}: {
  mode: string;
  greeting: string;
  suggestions?: string[];
  placeholder?: string;
}) {
  const [messages, setMessages] = useState<DisplayMessage[]>([
    { role: "assistant", content: greeting },
  ]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, loading]);

  async function send(text: string) {
    const content = text.trim();
    if (!content || loading) return;
    const next: DisplayMessage[] = [...messages, { role: "user", content }];
    setMessages(next);
    setInput("");
    setLoading(true);
    try {
      const history: ChatMessage[] = next.map((m) => ({
        role: m.role,
        content: m.content,
      }));
      const res = await api.chat(mode, history);
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: res.reply.content, refused: res.refused },
      ]);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Request failed";
      setMessages((prev) => [
        ...prev,
        {
          role: "assistant",
          content: `⚠️ Could not reach the Horus API.\n\n\`${msg}\`\n\nIs the backend running on port 5174?`,
        },
      ]);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex h-[calc(100vh-13rem)] flex-col">
      <div
        ref={scrollRef}
        className="flex-1 space-y-4 overflow-y-auto rounded-xl border border-border bg-card/40 p-4"
      >
        {messages.map((m, i) => (
          <div
            key={i}
            className={cn("flex gap-3", m.role === "user" ? "flex-row-reverse" : "")}
          >
            <div
              className={cn(
                "flex h-8 w-8 shrink-0 items-center justify-center rounded-lg",
                m.role === "user"
                  ? "bg-neon-purple/20 text-neon-purple"
                  : m.refused
                    ? "bg-severity-high/20 text-severity-high"
                    : "bg-neon-blue/20 text-neon-blue"
              )}
            >
              {m.role === "user" ? (
                <User className="h-4 w-4" />
              ) : m.refused ? (
                <ShieldAlert className="h-4 w-4" />
              ) : (
                <Bot className="h-4 w-4" />
              )}
            </div>
            <div
              className={cn(
                "max-w-[80%] rounded-xl border px-4 py-2.5",
                m.role === "user"
                  ? "border-neon-purple/30 bg-neon-purple/10"
                  : m.refused
                    ? "border-severity-high/30 bg-severity-high/5"
                    : "border-border bg-background/60"
              )}
            >
              <Markdown>{m.content}</Markdown>
            </div>
          </div>
        ))}
        {loading && (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" /> Horus is thinking…
          </div>
        )}
      </div>

      {suggestions.length > 0 && messages.length <= 1 && (
        <div className="mt-3 flex flex-wrap gap-2">
          {suggestions.map((s) => (
            <button
              key={s}
              onClick={() => send(s)}
              className="rounded-full border border-border bg-card px-3 py-1.5 text-xs text-muted-foreground transition-colors hover:border-neon-blue/40 hover:text-foreground"
            >
              {s}
            </button>
          ))}
        </div>
      )}

      <div className="mt-3 flex items-end gap-2">
        <Textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              send(input);
            }
          }}
          placeholder={placeholder}
          className="min-h-[52px] resize-none"
          rows={1}
        />
        <Button
          onClick={() => send(input)}
          disabled={loading || !input.trim()}
          size="icon"
          className="h-[52px] w-[52px]"
        >
          {loading ? <Loader2 className="h-5 w-5 animate-spin" /> : <Send className="h-5 w-5" />}
        </Button>
      </div>
    </div>
  );
}
