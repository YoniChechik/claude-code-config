import { NextRequest, NextResponse } from "next/server";
import { processRegistry } from "@/lib/process-registry";
import { streamRegistry } from "@/lib/stream-registry";
import { sessionManager } from "@/lib/session-manager";
import { heartbeatManager } from "@/lib/heartbeat-manager";

/**
 * POST /api/sessions/cleanup
 * Clean up sessions when tab closes
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

    console.log(
      `[Cleanup API] Cleaning up ${sessionIds.length} sessions:`,
      sessionIds,
    );

    const results: Array<{ sessionId: string; success: boolean; error?: string }> = [];

    for (const sessionId of sessionIds) {
      try {
        console.log(`[Cleanup API] Cleaning up session ${sessionId}`);

        // 1. Terminate Claude process
        const processTerminated = await processRegistry.terminate(sessionId);
        console.log(
          `[Cleanup API] Process termination for ${sessionId}: ${processTerminated}`,
        );

        // 2. Abort SSE stream
        streamRegistry.abort(sessionId);
        console.log(`[Cleanup API] Stream aborted for ${sessionId}`);

        // 3. Delete session from sessionManager
        sessionManager.deleteSession(sessionId);
        console.log(`[Cleanup API] Session deleted: ${sessionId}`);

        // 4. Remove from heartbeat tracking
        heartbeatManager.remove(sessionId);
        console.log(`[Cleanup API] Heartbeat tracking removed: ${sessionId}`);

        results.push({ sessionId, success: true });
      } catch (error) {
        console.error(
          `[Cleanup API] Error cleaning up session ${sessionId}:`,
          error,
        );
        results.push({
          sessionId,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    const successCount = results.filter((r) => r.success).length;
    console.log(
      `[Cleanup API] Cleanup complete: ${successCount}/${sessionIds.length} successful`,
    );

    return NextResponse.json({
      success: successCount === sessionIds.length,
      cleaned: sessionIds.length,
      successCount,
      results,
    });
  } catch (error) {
    console.error("[Cleanup API] Error processing cleanup request:", error);
    return NextResponse.json(
      {
        error: "Failed to process cleanup request",
        details: error instanceof Error ? error.message : String(error),
      },
      { status: 500 },
    );
  }
}
