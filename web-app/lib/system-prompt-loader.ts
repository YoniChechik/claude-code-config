import { promises as fs } from "fs";
import path from "path";

/**
 * Load custom system prompt from project root
 * File location priority:
 * 1. customPath parameter if provided
 * 2. CCWEB_APPENDED_SYSTEM_PROMPT_FILE environment variable if set
 * 3. Default: PROJECT_ROOT/main_appended_system_prompt.md
 * Gracefully handles missing file (returns undefined)
 */
export async function loadSystemPrompt(
  customPath?: string,
): Promise<string | undefined> {
  try {
    // Determine file path with fallback logic
    const promptPath =
      customPath ||
      process.env.CCWEB_APPENDED_SYSTEM_PROMPT_FILE ||
      path.join(process.cwd(), "..", "main_appended_system_prompt.md");

    const content = await fs.readFile(promptPath, "utf-8");
    return content.trim();
  } catch {
    // File not found - that's okay, return undefined
    return undefined;
  }
}
