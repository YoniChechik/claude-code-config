import { promises as fs } from "fs";
import path from "path";

/**
 * Convert directory path to Claude's encoding format
 * Examples:
 *   /home/ubuntu/.claude -> -home-ubuntu--claude
 *   /tmp -> -tmp
 *   /tmp/test_underscore -> -tmp-test-underscore
 *   /tmp/test with spaces -> -tmp-test-with-spaces
 *   /tmp/test.dots -> -tmp-test-dots
 * Rule: Replace all non-alphanumeric, non-hyphen characters with hyphen
 * Preserves: a-z, A-Z, 0-9, - (hyphen)
 * Converts to hyphen: /, ., _, space, and all special characters
 */
export function dirToClaudePath(dirPath: string): string {
  return dirPath.replace(/[^a-zA-Z0-9-]/g, "-");
}

/**
 * Create session symlink from target directory to source directory
 * So --resume can find the session after cd
 */
export async function createSessionSymlink(
  sessionId: string,
  sourceDir: string,
  targetDir: string
): Promise<void> {
  if (!sessionId || sourceDir === targetDir) return;

  const sourceEncoded = dirToClaudePath(sourceDir);
  const targetEncoded = dirToClaudePath(targetDir);

  const sourcePath = path.join(process.env.HOME!, ".claude", "projects", sourceEncoded);
  const targetPath = path.join(process.env.HOME!, ".claude", "projects", targetEncoded);

  try {
    // Create target directory if it doesn't exist
    await fs.mkdir(targetPath, { recursive: true });

    // Create symlink for session file
    const sessionFile = path.join(sourcePath, `${sessionId}.jsonl`);
    try {
      await fs.access(sessionFile);
      const targetFile = path.join(targetPath, `${sessionId}.jsonl`);
      await fs.symlink(sessionFile, targetFile);
    } catch {
      // File doesn't exist or symlink failed, ignore
    }

    // Create symlink for session directory (if exists)
    const sessionDir = path.join(sourcePath, sessionId);
    try {
      await fs.access(sessionDir);
      const targetSessionDir = path.join(targetPath, sessionId);
      await fs.symlink(sessionDir, targetSessionDir);
    } catch {
      // Directory doesn't exist or symlink failed, ignore
    }
  } catch (error) {
    // Log but don't throw - symlink creation is best-effort
    console.warn(`Failed to create session symlink: ${error}`);
  }
}
