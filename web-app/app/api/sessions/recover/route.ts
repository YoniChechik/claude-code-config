import { NextRequest, NextResponse } from "next/server";
import { findSessionsByDirectory } from "@/lib/session-storage";

/**
 * GET /api/sessions/recover - Get sessions accessible from a specific directory
 * Includes sessions created in the directory and sessions symlinked from other directories
 *
 * Query params:
 * - cwd: The current working directory to search from
 */
export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;
  const cwd = searchParams.get("cwd");

  if (!cwd) {
    return NextResponse.json(
      { error: "cwd parameter is required" },
      { status: 400 },
    );
  }

  try {
    const sessions = await findSessionsByDirectory(cwd);

    return NextResponse.json({
      sessions,
      count: sessions.length,
    });
  } catch (error) {
    console.error("Error recovering sessions:", error);
    return NextResponse.json(
      {
        error: "Failed to recover sessions",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 500 },
    );
  }
}
