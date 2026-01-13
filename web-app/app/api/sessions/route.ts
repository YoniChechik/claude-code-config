import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import type { CreateSessionRequest, CreateSessionResponse } from "@/lib/types";

/**
 * GET /api/sessions - List all sessions
 */
export async function GET() {
  const sessions = sessionManager.getAllSessions();
  return NextResponse.json({ sessions });
}

/**
 * POST /api/sessions - Create new session
 */
export async function POST(request: NextRequest) {
  const body = (await request.json()) as CreateSessionRequest;
  const { cwd, clientHostname } = body;

  if (!cwd) {
    return NextResponse.json({ error: "cwd is required" }, { status: 400 });
  }

  const session = sessionManager.createSession(cwd, clientHostname);

  const response: CreateSessionResponse = { session };
  return NextResponse.json(response);
}
