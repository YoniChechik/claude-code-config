import { NextRequest, NextResponse } from "next/server";
import { heartbeatManager } from "@/lib/heartbeat-manager";

/**
 * POST /api/sessions/heartbeat
 * Record heartbeat for active sessions
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { sessionIds } = body as { sessionIds: string[] };

    if (!sessionIds || !Array.isArray(sessionIds)) {
      return NextResponse.json(
        { error: "sessionIds array is required" },
        { status: 400 },
      );
    }

    // Record heartbeat for each session
    sessionIds.forEach((sessionId) => {
      heartbeatManager.beat(sessionId);
    });

    return NextResponse.json({
      alive: true,
      serverTime: Date.now(),
      tracked: sessionIds.length,
    });
  } catch (error) {
    console.error("[Heartbeat API] Error processing heartbeat:", error);
    return NextResponse.json(
      {
        error: "Failed to process heartbeat",
        details: error instanceof Error ? error.message : String(error),
      },
      { status: 500 },
    );
  }
}
