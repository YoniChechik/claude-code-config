import { promises as fs } from "fs";
import path from "path";

// Public functions
export function dirToClaudePath(dirPath: string): string {
  return dirPath.replace(/[^a-zA-Z0-9-]/g, "-");
}

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
    }

    // Create symlink for session directory (if exists)
    const sessionDir = path.join(sourcePath, sessionId);
    try {
      await fs.access(sessionDir);
      const targetSessionDir = path.join(targetPath, sessionId);
      await fs.symlink(sessionDir, targetSessionDir);
    } catch {
    }
  } catch (error) {
    console.warn(`Failed to create session symlink: ${error}`);
  }
}

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
