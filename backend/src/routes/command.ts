import { Router } from "express";
import { config } from "../config";
import { runCommand, validateCommand } from "../services/commandRunner";
import { ALLOWED_COMMANDS, HARD_BLOCKED_BINS } from "../data/allowlist";

export const commandRouter = Router();

/** GET /api/command/allowlist — describes what the runner permits. */
commandRouter.get("/allowlist", (_req, res) => {
  res.json({
    enabled: config.commandRunner.enabled,
    workspace: config.commandRunner.workspace,
    allowed: ALLOWED_COMMANDS,
    blocked: HARD_BLOCKED_BINS,
  });
});

/** POST /api/command/validate — dry-run the safety check without executing. */
commandRouter.post("/validate", (req, res) => {
  const command = typeof req.body?.command === "string" ? req.body.command : "";
  res.json(validateCommand(command));
});

/** POST /api/command/run — execute an allowlisted command in the workspace. */
commandRouter.post("/run", async (req, res) => {
  if (!config.commandRunner.enabled) {
    return res
      .status(403)
      .json({ allowed: false, ran: false, reason: "Command runner is disabled." });
  }
  const command = typeof req.body?.command === "string" ? req.body.command : "";
  if (!command.trim()) {
    return res.status(400).json({ allowed: false, ran: false, reason: "command is required" });
  }

  const result = await runCommand(
    command,
    config.commandRunner.workspace,
    config.commandRunner.timeoutMs
  );
  return res.json(result);
});
