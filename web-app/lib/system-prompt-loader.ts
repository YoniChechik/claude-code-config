import { promises as fs } from "fs";

const SYSTEM_PROMPT_PATH = "/home/ubuntu/.claude/main_appended_system_prompt.md";

/**
 * Load system prompt from /home/ubuntu/.claude/main_appended_system_prompt.md
 * Returns undefined if file doesn't exist
 */
export async function loadSystemPrompt(): Promise<string | undefined> {
  try {
    const content = await fs.readFile(SYSTEM_PROMPT_PATH, "utf-8");
    return content.trim();
  } catch {
    return undefined;
  }
}
