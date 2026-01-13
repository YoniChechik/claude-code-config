import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { loadSessionMessages } from "@/lib/session-storage";
import type { Message } from "@/lib/types";

/**
 * POST /api/sessions/resume - Resume a session from JSONL file
 */
export async function POST(request: NextRequest) {
  const { sessionId, filePath, cwd } = await request.json();

  if (!sessionId || !filePath || !cwd) {
    return NextResponse.json(
      { error: "sessionId, filePath, and cwd are required" },
      { status: 400 },
    );
  }

  // Load messages from JSONL file
  const loadedMessages = await loadSessionMessages(filePath);

  // Messages are already in the correct format from loadSessionMessages
  const messages = loadedMessages as Message[];

  // Create resumed session
  const session = sessionManager.resumeSession(sessionId, cwd, messages);

  return NextResponse.json({ session });
}
