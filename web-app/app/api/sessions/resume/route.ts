import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { loadSessionMessages } from "@/lib/session-storage";
import type { Message } from "@/lib/types";

/**
 * POST /api/sessions/resume - Resume a session from JSONL file
 */
export async function POST(request: NextRequest) {
  const { sessionId, filePath, cwd } = await request.json();
  const windowId = request.headers.get("x-window-id");

  if (!sessionId || !filePath || !cwd) {
    return NextResponse.json(
      { error: "sessionId, filePath, and cwd are required" },
      { status: 400 }
    );
  }

  if (!windowId) {
    return NextResponse.json(
      { error: "x-window-id header required" },
      { status: 400 }
    );
  }

  try {
    // Load messages from JSONL file
    const loadedMessages = await loadSessionMessages(filePath);

    // Messages are already in the correct format from loadSessionMessages
    const messages = loadedMessages as Message[];

    // Create resumed session
    const session = sessionManager.resumeSession(sessionId, windowId, cwd, messages);
    return NextResponse.json({ session });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";

    // Return 404 if file not found, 403 for ownership errors, 500 for other errors
    if (errorMessage.includes("Session file not found") || errorMessage.includes("ENOENT")) {
      return NextResponse.json(
        { error: "Session file not found" },
        { status: 404 }
      );
    } else if (errorMessage.includes("ownership")) {
      return NextResponse.json(
        { error: errorMessage },
        { status: 403 }
      );
    } else {
      return NextResponse.json(
        { error: "Failed to resume session", details: errorMessage },
        { status: 500 }
      );
    }
  }
}
