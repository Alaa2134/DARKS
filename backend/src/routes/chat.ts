import { Router } from "express";
import { evaluateText } from "../safety/safetyFilter";
import { chat, type ChatMessage } from "../services/llmService";
import { logSafety } from "../db/database";

export const chatRouter = Router();

/**
 * POST /api/chat
 * body: { mode: string, messages: { role, content }[] }
 */
chatRouter.post("/", async (req, res) => {
  const mode = typeof req.body?.mode === "string" ? req.body.mode : "chat";
  const messages: ChatMessage[] = Array.isArray(req.body?.messages)
    ? req.body.messages
        .filter(
          (m: any) =>
            m &&
            (m.role === "user" || m.role === "assistant") &&
            typeof m.content === "string"
        )
        .slice(-20)
    : [];

  if (messages.length === 0) {
    return res.status(400).json({ error: "messages array is required" });
  }

  const lastUser = [...messages].reverse().find((m) => m.role === "user");
  const safety = evaluateText(lastUser?.content ?? "");

  if (!safety.allowed) {
    logSafety({
      decision: "refuse",
      category: safety.category,
      reason: safety.reason,
      excerpt: lastUser?.content ?? "",
      context: `chat:${mode}`,
    });
    return res.json({
      refused: true,
      safety,
      reply: {
        role: "assistant",
        content:
          `**I can't help with that request.**\n\n${safety.reason}\n\n` +
          (safety.safeAlternative
            ? `**What I *can* do instead:** ${safety.safeAlternative}`
            : ""),
        provider: "safety-filter",
        offline: true,
      },
    });
  }

  logSafety({ decision: "allow", excerpt: lastUser?.content ?? "", context: `chat:${mode}` });

  try {
    const reply = await chat(mode, messages);
    return res.json({
      refused: false,
      reply: { role: "assistant", ...reply },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    return res.status(500).json({ error: message });
  }
});
