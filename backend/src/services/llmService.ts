/**
 * llmService.ts
 * ----------------------------------------------------------------------------
 * Thin LLM abstraction. Supports Anthropic and OpenAI via native fetch (no SDK
 * dependency), plus a fully offline template mode so the product works for a
 * demo with zero API keys.
 *
 * The safety filter is applied by the route layer BEFORE anything reaches here.
 */

import { config } from "../config";
import { buildSystemPrompt } from "../prompts/systemPrompts";
import { offlineResponse } from "./offlineResponder";

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface LlmReply {
  content: string;
  provider: string;
  model: string;
  offline: boolean;
}

async function callAnthropic(
  system: string,
  messages: ChatMessage[]
): Promise<string> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": config.llm.anthropic.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: config.llm.anthropic.model,
      max_tokens: 2048,
      system,
      messages: messages.map((m) => ({ role: m.role, content: m.content })),
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Anthropic API error ${res.status}: ${text.slice(0, 300)}`);
  }
  const data = (await res.json()) as {
    content?: { type: string; text?: string }[];
  };
  return (data.content ?? [])
    .map((c) => c.text ?? "")
    .join("")
    .trim();
}

async function callOpenAI(
  system: string,
  messages: ChatMessage[]
): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${config.llm.openai.apiKey}`,
    },
    body: JSON.stringify({
      model: config.llm.openai.model,
      max_tokens: 2048,
      messages: [
        { role: "system", content: system },
        ...messages.map((m) => ({ role: m.role, content: m.content })),
      ],
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenAI API error ${res.status}: ${text.slice(0, 300)}`);
  }
  const data = (await res.json()) as {
    choices?: { message?: { content?: string } }[];
  };
  return (data.choices?.[0]?.message?.content ?? "").trim();
}

export async function chat(
  mode: string,
  messages: ChatMessage[]
): Promise<LlmReply> {
  const system = buildSystemPrompt(mode);
  const provider = config.llm.provider;

  const lastUser = [...messages].reverse().find((m) => m.role === "user");
  const userText = lastUser?.content ?? "";

  try {
    if (provider === "anthropic" && config.llm.anthropic.apiKey) {
      const content = await callAnthropic(system, messages);
      return {
        content,
        provider: "anthropic",
        model: config.llm.anthropic.model,
        offline: false,
      };
    }
    if (provider === "openai" && config.llm.openai.apiKey) {
      const content = await callOpenAI(system, messages);
      return {
        content,
        provider: "openai",
        model: config.llm.openai.model,
        offline: false,
      };
    }
  } catch (err) {
    // Fall through to offline mode on any provider error so the UI keeps working.
    const message = err instanceof Error ? err.message : String(err);
    const fallback = offlineResponse(mode, userText);
    return {
      content:
        `> _Live LLM call failed, using built-in template mode._\n> \`${message}\`\n\n` +
        fallback,
      provider: "offline",
      model: "template",
      offline: true,
    };
  }

  // Default: offline template responder.
  return {
    content: offlineResponse(mode, userText),
    provider: "offline",
    model: "template",
    offline: true,
  };
}
