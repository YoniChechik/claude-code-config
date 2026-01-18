import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { loadSessionMessages, validateSessionPath } from "@/lib/session-storage";
import type { Message, ResumeSessionRequest } from "@/lib/types";

/**
 * POST /api/sessions/resume - Resume a session from JSONL file
 * Handles both real file paths and symlink paths with validation
 */
export async function POST(request: NextRequest) {
  const body = (await request.json()) as ResumeSessionRequest;
  const { sessionId, windowId, filePath, cwd } = body;

  if (!sessionId || !windowId || !filePath || !cwd) {
    return NextResponse.json(
      { error: "sessionId, windowId, filePath, and cwd are required" },
      { status: 400 },
    );
  }

  try {
    const validPath = await validateSessionPath(filePath);
    if (!validPath) {
      return NextResponse.json(
        {
          error: "Session file not found or inaccessible",
          details: "The session file may have been deleted or the symlink is broken",
        },
        { status: 404 },
      );
    }

    const loadedMessages = await loadSessionMessages(validPath);
    const messages = loadedMessages as Message[];
    const session = sessionManager.resumeSession(sessionId, windowId, cwd, messages);

    return NextResponse.json({ session });
  } catch (error) {
    if (error instanceof Error && error.message === "Session ownership mismatch") {
      console.warn(
        `[Security] Session ownership mismatch: ` +
          `sessionId=${sessionId}, windowId=${windowId}, ` +
          `owner=${sessionManager.getOwner(sessionId)}`
      );
      return NextResponse.json(
        { error: "Session ownership validation failed" },
        { status: 403 }
      );
    }
    console.error("Error resuming session:", error);
    return NextResponse.json(
      {
        error: "Failed to resume session",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 500 },
    );
  }
}
