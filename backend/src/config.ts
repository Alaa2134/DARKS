import dotenv from "dotenv";
import path from "node:path";

dotenv.config();

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  return /^(1|true|yes|on)$/i.test(value.trim());
}

function int(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export const config = {
  port: int(process.env.PORT, 5174),
  corsOrigin: (process.env.CORS_ORIGIN ?? "http://localhost:5173")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),

  llm: {
    provider: (process.env.LLM_PROVIDER ?? "offline").toLowerCase() as
      | "anthropic"
      | "openai"
      | "offline",
    anthropic: {
      apiKey: process.env.ANTHROPIC_API_KEY ?? "",
      model: process.env.ANTHROPIC_MODEL ?? "claude-sonnet-4-6",
    },
    openai: {
      apiKey: process.env.OPENAI_API_KEY ?? "",
      model: process.env.OPENAI_MODEL ?? "gpt-4o-mini",
    },
  },

  commandRunner: {
    enabled: bool(process.env.ENABLE_COMMAND_RUNNER, true),
    workspace: path.resolve(process.env.COMMAND_WORKSPACE ?? "./workspace"),
    timeoutMs: int(process.env.COMMAND_TIMEOUT_MS, 20_000),
  },
};

export type AppConfig = typeof config;
