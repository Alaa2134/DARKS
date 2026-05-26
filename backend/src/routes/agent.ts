import { Router } from "express";
import { runAgent, type AgentEvent, type AgentInput } from "../agent/agentLoop";

export const agentRouter = Router();

/**
 * POST /api/agent/stream
 * body: { goal, code?, language?, log?, target?, confirmedScope? }
 * Streams agent progress as Server-Sent Events.
 */
agentRouter.post("/stream", async (req, res) => {
  const body = req.body ?? {};
  const input: AgentInput = {
    goal: typeof body.goal === "string" ? body.goal : "",
    code: typeof body.code === "string" ? body.code : undefined,
    language: typeof body.language === "string" ? body.language : undefined,
    log: typeof body.log === "string" ? body.log : undefined,
    target: typeof body.target === "string" ? body.target : undefined,
    confirmedScope: Array.isArray(body.confirmedScope)
      ? body.confirmedScope.filter((s: unknown) => typeof s === "string")
      : [],
  };

  if (!input.goal.trim()) {
    return res.status(400).json({ error: "goal is required" });
  }

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });

  const send = (e: AgentEvent) => {
    res.write(`data: ${JSON.stringify(e)}\n\n`);
  };

  try {
    await runAgent(input, send);
  } catch (err) {
    send({ type: "error", message: err instanceof Error ? err.message : "error" });
  } finally {
    res.write("event: end\ndata: {}\n\n");
    res.end();
  }
});
