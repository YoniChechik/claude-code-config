import { promises as fs } from "fs";
import path from "path";
import { homedir } from "os";

export interface SessionMetadata {
  id: string;
  cwd: string;
  createdAt: string;
  lastActivityAt: string;
  messageCount: number;
  lastMessagePreview: string;
  filePath: string;
}

interface SessionLine {
  type: "user" | "assistant";
  message?: {
    role: string;
    content:
      | string
      | Array<{ type: string; text?: string; [key: string]: unknown }>;
  };
  cwd?: string;
  sessionId?: string;
  timestamp?: string;
}

interface LoadedMessage {
  role: "user" | "assistant";
  content: Array<Record<string, unknown>>;
  timestamp: Date;
}

export async function getRecentSessions(
  limit = 20,
): Promise<SessionMetadata[]> {
  const sessionFiles = await _discoverSessionFiles();

  const filesWithStats = await Promise.all(
    sessionFiles.map(async (filePath) => {
      const stats = await fs.stat(filePath);
      return { filePath, mtime: stats.mtime };
    }),
  );

  filesWithStats.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());

  const recentFiles = filesWithStats.slice(0, limit).map((f) => f.filePath);
  const metadataPromises = recentFiles.map((filePath) =>
    _loadSessionMetadata(filePath),
  );
  const metadata = await Promise.all(metadataPromises);

  const validMetadata = metadata.filter(
    (m): m is SessionMetadata => m !== null,
  );

  const seenIds = new Set<string>();
  const uniqueMetadata = validMetadata.filter((session) => {
    if (seenIds.has(session.id)) {
      return false;
    }
    seenIds.add(session.id);
    return true;
  });

  uniqueMetadata.sort(
    (a, b) =>
      new Date(b.lastActivityAt).getTime() -
      new Date(a.lastActivityAt).getTime(),
  );

  return uniqueMetadata;
}

export async function loadSessionMessages(
  filePath: string,
): Promise<LoadedMessage[]> {
  const content = await fs.readFile(filePath, "utf-8");
  const lines = content
    .trim()
    .split("\n")
    .filter((line) => line.trim());

  const messages = lines
    .map((line) => {
      const parsed: SessionLine = JSON.parse(line);
      if (!parsed.message) return null;

      let contentBlocks: Array<{
        type: string;
        text?: string;
        [key: string]: unknown;
      }>;

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

async function _discoverSessionFiles(): Promise<string[]> {
  const projectsDir = path.join(homedir(), ".claude", "projects");
  const sessionFiles: string[] = [];
  const entries = await fs.readdir(projectsDir);

  for (const entry of entries) {
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

async function _loadSessionMetadata(
  filePath: string,
): Promise<SessionMetadata | null> {
  const content = await fs.readFile(filePath, "utf-8");
  const lines = content
    .trim()
    .split("\n")
    .filter((line) => line.trim());

  if (lines.length === 0) {
    return null;
  }

  const firstLine: SessionLine = JSON.parse(lines[0]);
  const sessionId = firstLine.sessionId!;
  const createdAt = firstLine.timestamp!;
  const cwd = firstLine.cwd!;

  const lastLine: SessionLine = JSON.parse(lines[lines.length - 1]);
  const lastActivityAt = lastLine.timestamp!;

  const messageCount = lines.length;

  let lastMessagePreview = "";
  for (let i = lines.length - 1; i >= 0; i--) {
    const line: SessionLine = JSON.parse(lines[i]);
    if (line.type === "user" && line.message) {
      const content = line.message.content;
      if (typeof content === "string") {
        lastMessagePreview = content;
      } else if (Array.isArray(content)) {
        const textBlock = content.find((block) => block.type === "text");
        lastMessagePreview = textBlock!.text!;
      }
      break;
    }
  }

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

export function formatRelativeTime(timestamp: string): string {
  const diff = Date.now() - new Date(timestamp).getTime();
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(hours / 24);

  if (hours < 1) return "< 1h ago";
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;
  return `${Math.floor(days / 7)}w ago`;
}
