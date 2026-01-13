import { promises as fs } from "fs";
import path from "path";
import { homedir } from "os";

/**
 * Session metadata extracted from JSONL files
 */
export interface SessionMetadata {
  id: string;
  cwd: string;
  createdAt: string;
  lastActivityAt: string;
  messageCount: number;
  lastMessagePreview: string;
  filePath: string;
}

/**
 * JSONL line format for session storage
 */
interface SessionLine {
  type: "user" | "assistant";
  message?: {
    role: string;
    content: string | Array<{ type: string; text?: string; [key: string]: unknown }>;
  };
  cwd?: string;
  sessionId?: string;
  timestamp?: string;
}

/**
 * Format relative time (e.g., "2h ago", "1d ago")
 */
export function formatRelativeTime(timestamp: string): string {
  const diff = Date.now() - new Date(timestamp).getTime();
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(hours / 24);

  if (hours < 1) return "< 1h ago";
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;
  return `${Math.floor(days / 7)}w ago`;
}

/**
 * Scan projects directory and discover all session JSONL files
 */
async function discoverSessionFiles(): Promise<string[]> {
  const projectsDir = path.join(homedir(), ".claude", "projects");

  const stats = await fs.stat(projectsDir);
  if (!stats.isDirectory()) {
    return [];
  }

  const sessionFiles: string[] = [];
  const entries = await fs.readdir(projectsDir);

  for (const entry of entries) {
    // Skip hidden files/directories (like .jsonl symlink)
    if (entry.startsWith(".")) continue;

    const entryPath = path.join(projectsDir, entry);
    const entryStats = await fs.stat(entryPath);
    if (!entryStats.isDirectory()) continue;

    const files = await fs.readdir(entryPath);
    for (const file of files) {
      if (file.endsWith(".jsonl") && !file.includes("subagents")) {
        sessionFiles.push(path.join(entryPath, file));
      }
    }
  }

  return sessionFiles;
}

/**
 * Extract metadata from a session JSONL file
 */
async function loadSessionMetadata(filePath: string): Promise<SessionMetadata | null> {
  const content = await fs.readFile(filePath, "utf-8");
  const lines = content.trim().split("\n").filter(line => line.trim());

  if (lines.length === 0) {
    return null;
  }

  // Parse first line for session ID and creation time
  const firstLine: SessionLine = JSON.parse(lines[0]);
  const sessionId = firstLine.sessionId || path.basename(filePath, ".jsonl");
  const createdAt = firstLine.timestamp || new Date().toISOString();
  const cwd = firstLine.cwd || "/unknown";

  // Parse last line for last activity
  const lastLine: SessionLine = JSON.parse(lines[lines.length - 1]);
  const lastActivityAt = lastLine.timestamp || createdAt;

  // Count messages (user + assistant pairs)
  const messageCount = lines.length;

  // Extract last message preview
  let lastMessagePreview = "";
  for (let i = lines.length - 1; i >= 0; i--) {
    const line: SessionLine = JSON.parse(lines[i]);
    if (line.type === "user" && line.message) {
      const content = line.message.content;
      if (typeof content === "string") {
        lastMessagePreview = content;
      } else if (Array.isArray(content)) {
        const textBlock = content.find(block => block.type === "text");
        lastMessagePreview = textBlock?.text || "";
      }
      break;
    }
  }

  // Truncate preview to 50 characters
  if (lastMessagePreview.length > 50) {
    lastMessagePreview = lastMessagePreview.substring(0, 50) + "...";
  }

  return {
    id: sessionId,
    cwd,
    createdAt,
    lastActivityAt,
    messageCount,
    lastMessagePreview,
    filePath,
  };
}

/**
 * Get recent sessions sorted by last activity
 */
export async function getRecentSessions(limit = 20): Promise<SessionMetadata[]> {
  const sessionFiles = await discoverSessionFiles();

  // Get file modification times and sort
  const filesWithStats = await Promise.all(
    sessionFiles.map(async (filePath) => {
      const stats = await fs.stat(filePath);
      return { filePath, mtime: stats.mtime };
    })
  );

  filesWithStats.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());

  // Load metadata for top N files
  const recentFiles = filesWithStats.slice(0, limit).map(f => f.filePath);
  const metadataPromises = recentFiles.map(filePath => loadSessionMetadata(filePath));
  const metadata = await Promise.all(metadataPromises);

  // Filter out null results and sort by last activity
  const validMetadata = metadata.filter((m): m is SessionMetadata => m !== null);
  validMetadata.sort((a, b) =>
    new Date(b.lastActivityAt).getTime() - new Date(a.lastActivityAt).getTime()
  );

  return validMetadata;
}

/**
 * Message format for loaded sessions
 */
interface LoadedMessage {
  role: "user" | "assistant";
  content: Array<Record<string, unknown>>;
  timestamp: Date;
}

/**
 * Load full session messages from JSONL file
 */
export async function loadSessionMessages(filePath: string): Promise<LoadedMessage[]> {
  const content = await fs.readFile(filePath, "utf-8");
  const lines = content.trim().split("\n").filter(line => line.trim());

  const messages = lines
    .map(line => {
      const parsed: SessionLine = JSON.parse(line);
      if (!parsed.message) return null;

      let contentBlocks: Array<{ type: string; text?: string; [key: string]: unknown }>;

      if (typeof parsed.message.content === "string") {
        contentBlocks = [{ type: "text", text: parsed.message.content }];
      } else if (Array.isArray(parsed.message.content)) {
        contentBlocks = parsed.message.content;
      } else {
        return null;
      }

      return {
        role: parsed.type as "user" | "assistant",
        content: contentBlocks,
        timestamp: new Date(parsed.timestamp || new Date()),
      };
    })
    .filter((m): m is NonNullable<typeof m> => m !== null);

  return messages;
}
