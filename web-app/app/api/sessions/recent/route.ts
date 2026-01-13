import { NextResponse } from "next/server";
import { getRecentSessions } from "@/lib/session-storage";

/**
 * GET /api/sessions/recent - Fetch recent sessions
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const limit = parseInt(searchParams.get("limit") || "20");

  const sessions = await getRecentSessions(limit);
  return NextResponse.json({ sessions });
}
