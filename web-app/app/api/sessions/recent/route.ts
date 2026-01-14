import { NextResponse } from "next/server";
import { getRecentSessions } from "@/lib/session-storage";

/**
 * GET /api/sessions/recent - Fetch recent sessions
 */
export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url);
    const limit = parseInt(searchParams.get("limit") || "20");

    const sessions = await getRecentSessions(limit);
    return NextResponse.json({ sessions });
  } catch (error) {
    console.error("Failed to fetch recent sessions:", error);
    return NextResponse.json(
      { error: "Failed to load sessions", sessions: [] },
      { status: 500 }
    );
  }
}
