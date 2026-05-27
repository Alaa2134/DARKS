/**
 * commandRunner.ts
 * ----------------------------------------------------------------------------
 * A deliberately boring, safe command runner. It exists so students can run
 * everyday dev tasks (install deps, run tests, lint) from the Horus UI without
 * ever turning into an attack platform.
 *
 * Safety model:
 *   1. Deny by default — only ALLOWED_COMMANDS base binaries are permitted.
 *   2. No shell — arguments are parsed and passed to spawn() as an argv array,
 *      so there is no shell interpolation / chaining.
 *   3. Argument deny patterns block destructive / offensive usage.
 *   4. Execution is locked to a single workspace directory.
 *   5. Hard timeout + output truncation.
 */

import { spawn } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import {
  ALLOWED_COMMANDS,
  BLOCKED_ARG_PATTERNS,
  HARD_BLOCKED_BINS,
} from "../data/allowlist";

export interface CommandResult {
  allowed: boolean;
  ran: boolean;
  bin?: string;
  args?: string[];
  exitCode?: number | null;
  stdout?: string;
  stderr?: string;
  reason?: string;
  durationMs?: number;
}

const MAX_OUTPUT = 60_000; // characters

/**
 * Tokenize a command string without invoking a shell. Supports simple single
 * and double quoting; rejects shell metacharacters elsewhere.
 */
function tokenize(command: string): string[] {
  const tokens: string[] = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(command)) !== null) {
    tokens.push(match[1] ?? match[2] ?? match[3] ?? "");
  }
  return tokens;
}

export function validateCommand(command: string): {
  allowed: boolean;
  bin?: string;
  args?: string[];
  reason?: string;
} {
  const trimmed = (command ?? "").trim();
  if (!trimmed) {
    return { allowed: false, reason: "Empty command." };
  }

  // Block dangerous argument patterns on the whole string first.
  for (const { label, pattern } of BLOCKED_ARG_PATTERNS) {
    if (pattern.test(trimmed)) {
      return {
        allowed: false,
        reason: `Blocked: command contains a disallowed pattern (${label}).`,
      };
    }
  }

  const tokens = tokenize(trimmed);
  const bin = (tokens[0] ?? "").toLowerCase();
  const args = tokens.slice(1);

  if (HARD_BLOCKED_BINS.includes(bin)) {
    return {
      allowed: false,
      bin,
      reason: `Blocked: "${bin}" is an offensive/exploitation tool and is never permitted.`,
    };
  }

  const allowed = ALLOWED_COMMANDS.find((c) => c.bin === bin);
  if (!allowed) {
    return {
      allowed: false,
      bin,
      reason: `Blocked: "${bin}" is not on the command allowlist.`,
    };
  }

  if (allowed.allowedSubcommands && args.length > 0) {
    const sub = args[0].toLowerCase();
    if (!allowed.allowedSubcommands.includes(sub)) {
      return {
        allowed: false,
        bin,
        reason: `Blocked: "${bin} ${sub}" is not an allowed sub-command. Allowed: ${allowed.allowedSubcommands.join(", ")}.`,
      };
    }
  }

  return { allowed: true, bin, args };
}

export async function runCommand(
  command: string,
  workspace: string,
  timeoutMs: number
): Promise<CommandResult> {
  const validation = validateCommand(command);
  if (!validation.allowed) {
    return { allowed: false, ran: false, reason: validation.reason };
  }

  const cwd = path.resolve(workspace);
  if (!fs.existsSync(cwd)) {
    try {
      fs.mkdirSync(cwd, { recursive: true });
    } catch {
      return {
        allowed: true,
        ran: false,
        reason: `Workspace directory does not exist and could not be created: ${cwd}`,
      };
    }
  }

  const bin = validation.bin!;
  const args = validation.args!;
  const start = Date.now();

  return new Promise<CommandResult>((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;

    const child = spawn(bin, args, {
      cwd,
      shell: false, // critical: no shell interpolation
      windowsHide: true,
      env: { ...process.env, NODE_ENV: process.env.NODE_ENV ?? "development" },
    });

    const timer = setTimeout(() => {
      if (settled) return;
      child.kill("SIGKILL");
      settled = true;
      resolve({
        allowed: true,
        ran: true,
        bin,
        args,
        exitCode: null,
        stdout: stdout.slice(0, MAX_OUTPUT),
        stderr: stderr.slice(0, MAX_OUTPUT),
        reason: `Command timed out after ${timeoutMs}ms and was terminated.`,
        durationMs: Date.now() - start,
      });
    }, timeoutMs);

    child.stdout?.on("data", (d) => {
      stdout += d.toString();
      if (stdout.length > MAX_OUTPUT) stdout = stdout.slice(0, MAX_OUTPUT);
    });
    child.stderr?.on("data", (d) => {
      stderr += d.toString();
      if (stderr.length > MAX_OUTPUT) stderr = stderr.slice(0, MAX_OUTPUT);
    });

    child.on("error", (err) => {
      if (settled) return;
      clearTimeout(timer);
      settled = true;
      resolve({
        allowed: true,
        ran: false,
        bin,
        args,
        reason: `Failed to start command: ${err.message}`,
        durationMs: Date.now() - start,
      });
    });

    child.on("close", (code) => {
      if (settled) return;
      clearTimeout(timer);
      settled = true;
      resolve({
        allowed: true,
        ran: true,
        bin,
        args,
        exitCode: code,
        stdout: stdout.slice(0, MAX_OUTPUT),
        stderr: stderr.slice(0, MAX_OUTPUT),
        durationMs: Date.now() - start,
      });
    });
  });
}
