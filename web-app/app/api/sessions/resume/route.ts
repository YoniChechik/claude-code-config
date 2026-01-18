import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { loadSessionMessages, validateSessionPath } from "@/lib/session-storage";
import type { Message, ResumeSessionRequest } from "@/lib/types";

/**
 * POST /api/sessions/resume - Resume a session from JSONL file
 * Handles both real file paths and symlink paths with validation
 */
export async function POST(request: NextRequest) {
  const { sessionId, windowId, filePath, cwd } = (await request.json()) as ResumeSessionRequest;

  if (!sessionId || !windowId || !filePath || !cwd) {
    return NextResponse.json(
      { error: "sessionId, windowId, filePath, and cwd are required" },
      { status: 400 },
    );
  }

  // Validate ownership
  if (!sessionManager.validateOwnership(sessionId, windowId)) {
    console.warn(
      `[Security] Session ownership check failed: ` +
        `sessionId=${sessionId}, windowId=${windowId}`
    );
    return NextResponse.json(
      { error: "Session ownership validation failed" },
      { status: 403 }
    );
  }

  try {
    // Validate and resolve the session path (handles symlinks and broken links)
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

    // Load messages from JSONL file (using validated real path)
    const loadedMessages = await loadSessionMessages(validPath);

    // Messages are already in the correct format from loadSessionMessages
    const messages = loadedMessages as Message[];

    // Create resumed session
    const session = sessionManager.resumeSession(sessionId, windowId, cwd, messages);

    return NextResponse.json({ session });
  } catch (error) {
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
