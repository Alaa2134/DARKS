/**
 * server.ts — Horus Cyber Agent API.
 *
 * A small, hardened Express server that exposes the safe cybersecurity tooling:
 * chat (safety-filtered), OWASP audit data, static code review, defensive log
 * analysis, report generation, and an allowlist-only command runner.
 */

import express from "express";
import cors from "cors";
import helmet from "helmet";
import morgan from "morgan";

import { config } from "./config";
import { chatRouter } from "./routes/chat";
import { commandRouter } from "./routes/command";
import { auditRouter } from "./routes/audit";
import { analysisRouter } from "./routes/analysis";

const app = express();

app.use(helmet());
app.use(
  cors({
    origin: config.corsOrigin.length ? config.corsOrigin : true,
  })
);
app.use(express.json({ limit: "2mb" }));
app.use(morgan("dev"));

app.get("/api/health", (_req, res) => {
  res.json({
    status: "ok",
    name: "Horus Cyber Agent",
    llmProvider: config.llm.provider,
    commandRunner: config.commandRunner.enabled,
    time: new Date().toISOString(),
  });
});

app.use("/api/chat", chatRouter);
app.use("/api/command", commandRouter);
app.use("/api/audit", auditRouter);
app.use("/api/analysis", analysisRouter);

app.use((_req, res) => {
  res.status(404).json({ error: "Not found" });
});

// Centralized error handler.
app.use(
  (
    err: unknown,
    _req: express.Request,
    res: express.Response,
    _next: express.NextFunction
  ) => {
    const message = err instanceof Error ? err.message : "Internal error";
    res.status(500).json({ error: message });
  }
);

app.listen(config.port, () => {
  console.log(`\n  Horus Cyber Agent API`);
  console.log(`  → http://localhost:${config.port}`);
  console.log(`  → LLM provider: ${config.llm.provider}`);
  console.log(
    `  → Command runner: ${config.commandRunner.enabled ? "enabled" : "disabled"} (workspace: ${config.commandRunner.workspace})\n`
  );
});
