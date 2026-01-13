import type { StreamEvent } from "./types";

/**
 * Parse streaming line from Claude CLI format (TEXT:, LINE:, SUB:, JSON:)
 */
export function parseStreamLine(line: string): StreamEvent | null {
  if (line.startsWith("TEXT:")) {
    const text = line.slice(5).replace(/@@NEWLINE@@/g, "\n");
    return { type: "TEXT", text };
  }

  if (line.startsWith("LINE:")) {
    return { type: "LINE", text: line.slice(5) };
  }

  if (line.startsWith("SUB:")) {
    return { type: "SUB", text: line.slice(4) };
  }

  if (line.startsWith("JSON:")) {
    try {
      const data = JSON.parse(line.slice(5));
      return { type: "JSON", data };
    } catch {
      return null;
    }
  }

  return null;
}

/**
 * Format duration in milliseconds to human-readable string
 */
export function formatDuration(ms: number): string {
  if (ms < 1000) {
    return `${ms}ms`;
  }
  return `${(ms / 1000).toFixed(1)}s`;
}

/**
 * Generate unique session ID in UUID v4 format
 * Required by claude CLI for --resume flag
 */
export function generateSessionId(): string {
  // Generate UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

/**
 * Strip ANSI color codes from text
 */
export function stripAnsi(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

/**
 * Check if path is absolute
 */
export function isAbsolutePath(path: string): boolean {
  return path.startsWith("/");
}

/**
 * Normalize directory path
 */
export function normalizePath(path: string): string {
  return path.replace(/\/+$/, "") || "/";
}
