import * as fs from "fs";
import * as path from "path";

/**
 * Session logger for recording raw Claude inputs and outputs
 * Logs are stored per session in ~/.cache/claude/session-logs/
 */

const LOG_DIR = path.join(process.env.HOME || "~", ".cache", "claude", "session-logs");

function ensureLogDir(): void {
  if (!fs.existsSync(LOG_DIR)) {
    fs.mkdirSync(LOG_DIR, { recursive: true });
  }
}

function getLogFilePath(sessionId: string): string {
  ensureLogDir();
  return path.join(LOG_DIR, `${sessionId}.log`);
}

export function logSessionInput(sessionId: string, prompt: string, metadata?: Record<string, unknown>): void {
  const logFilePath = getLogFilePath(sessionId);
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    type: "input",
    prompt,
    metadata,
  };

  const logLine = JSON.stringify(logEntry) + "\n";
  fs.appendFileSync(logFilePath, logLine);
}

export function logSessionOutput(sessionId: string, rawEvent: unknown): void {
  const logFilePath = getLogFilePath(sessionId);
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    type: "output",
    event: rawEvent,
  };

  const logLine = JSON.stringify(logEntry) + "\n";
  fs.appendFileSync(logFilePath, logLine);
}

export function logSessionError(sessionId: string, error: string): void {
  const logFilePath = getLogFilePath(sessionId);
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    type: "error",
    error,
  };

  const logLine = JSON.stringify(logEntry) + "\n";
  fs.appendFileSync(logFilePath, logLine);
}
