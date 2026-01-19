import { promises as fs } from "fs";
import path from "path";

/**
 * Load custom system prompt from project root
 * File location: PROJECT_ROOT/main_appended_system_prompt.md
 * Gracefully handles missing file (returns undefined)
 */
export async function loadSystemPrompt(): Promise<string | undefined> {
  try {
    // Path relative to web-app directory: ../main_appended_system_prompt.md
    const promptPath = path.join(process.cwd(), "..", "main_appended_system_prompt.md");
    const content = await fs.readFile(promptPath, "utf-8");
    return content.trim();
  } catch {
    // File not found - that's okay, return undefined
    return undefined;
  }
}
