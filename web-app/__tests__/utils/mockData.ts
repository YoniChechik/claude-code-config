import type { Message, ContentBlock } from "@/lib/types";

export const createMockMessage = (
  role: "user" | "assistant",
  content: ContentBlock[],
  overrides?: Partial<Message>
): Message => ({
  role,
  content,
  timestamp: new Date(),
  ...overrides,
});

export const createTextBlock = (text: string): ContentBlock => ({
  type: "text",
  text,
});

export const createToolUseBlock = (
  toolName: string,
  input: Record<string, unknown>,
  id?: string
): ContentBlock => ({
  type: "tool_use",
  id: id || `tool_${Math.random().toString(36).substr(2, 9)}`,
  name: toolName,
  input,
});

export const createToolResultBlock = (
  toolUseId: string,
  content: string | Array<{ type: string; text?: string }>
): ContentBlock => ({
  type: "tool_result",
  tool_use_id: toolUseId,
  content,
});

export const mockSessionProps = {
  cwd: "/home/user/project",
  model: "claude-3-opus-20240229",
  lastDurationMs: 1500,
};

export const mockTokenUsage = {
  used: 50000,
  total: 100000,
  remaining: 50000,
};
