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
 *
 * This enables cross-directory session resumption by creating symlinks that make
 * sessions discoverable regardless of the current working directory. When a user
 * changes directories, this function creates symlinks in the new directory's
 * encoded path that point back to the original session files.
 *
 * Symlink resolution is transparent:
 * - Node.js fs.readFile() automatically follows symlinks
 * - Session discovery scans all directories and finds both real files and symlinks
 * - loadSessionMessages() works with both real paths and symlink paths
 * - Deduplication happens at the metadata level by session ID
 *
 * @param sessionId - The unique session identifier
 * @param sourceDir - The original directory where the session was created
 * @param targetDir - The new directory to create symlinks in
 */
export async function createSessionSymlink(
  sessionId: string,
  sourceDir: string,
  targetDir: string,
): Promise<void> {
  if (!sessionId || sourceDir === targetDir) return;

  const sourceEncoded = dirToClaudePath(sourceDir);
  const targetEncoded = dirToClaudePath(targetDir);

  const sourcePath = path.join(
    process.env.HOME!,
    ".claude",
    "projects",
    sourceEncoded,
  );
  const targetPath = path.join(
    process.env.HOME!,
    ".claude",
    "projects",
    targetEncoded,
  );

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

/**
 * Resolve a symlink path to its real file path
 * If the path is not a symlink, returns the original path
 *
 * @param linkPath - Path that may be a symlink
 * @returns The real file path, or the original path if not a symlink
 */
export async function resolveLinkPath(linkPath: string): Promise<string> {
  try {
    const stats = await fs.lstat(linkPath);
    if (stats.isSymbolicLink()) {
      return await fs.realpath(linkPath);
    }
    return linkPath;
  } catch {
    return linkPath;
  }
}

/**
 * Find the real session file path for a given session ID
 * Searches from a specific directory's encoded path
 *
 * @param sessionId - The session ID to find
 * @param fromDir - The directory to search from
 * @returns The real file path if found, null otherwise
 */
export async function findRealSessionPath(
  sessionId: string,
  fromDir: string,
): Promise<string | null> {
  const encoded = dirToClaudePath(fromDir);
  const dirPath = path.join(process.env.HOME!, ".claude", "projects", encoded);

  try {
    const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
    await fs.access(sessionFile);
    return await resolveLinkPath(sessionFile);
  } catch {
    return null;
  }
}
