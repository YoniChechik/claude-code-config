import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";

/**
 * GET /api/sessions/[id] - Get session by ID
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const windowId = request.headers.get("x-window-id");

  if (!windowId) {
    return NextResponse.json(
      { error: "x-window-id header required" },
      { status: 400 }
    );
  }

  const session = sessionManager.getSession(id);

  if (!session) {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }

  if (!sessionManager.validateOwnership(id, windowId)) {
    return NextResponse.json(
      { error: "Session ownership validation failed" },
      { status: 403 }
    );
  }

  return NextResponse.json({ session });
}

/**
 * PATCH /api/sessions/[id] - Update session settings
 */
export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const windowId = request.headers.get("x-window-id");

  if (!windowId) {
    return NextResponse.json(
      { error: "x-window-id header required" },
      { status: 400 }
    );
  }

  const session = sessionManager.getSession(id);
  if (!session) {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }

  if (!sessionManager.validateOwnership(id, windowId)) {
    return NextResponse.json(
      { error: "Session ownership validation failed" },
      { status: 403 }
    );
  }

  const body = await request.json();

  // Update session fields if provided
  if (body.audioNotificationsEnabled !== undefined) {
    session.audioNotificationsEnabled = body.audioNotificationsEnabled;
  }
  if (body.includePartialMessages !== undefined) {
    session.includePartialMessages = body.includePartialMessages;
  }

  return NextResponse.json({ session });
}

/**
 * DELETE /api/sessions/[id] - Delete session
 */
export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const windowId = request.headers.get("x-window-id");

  if (!windowId) {
    return NextResponse.json(
      { error: "x-window-id header required" },
      { status: 400 }
    );
  }

  const session = sessionManager.getSession(id);
  if (!session) {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }

  if (!sessionManager.validateOwnership(id, windowId)) {
    return NextResponse.json(
      { error: "Session ownership validation failed" },
      { status: 403 }
    );
  }

  const deleted = sessionManager.deleteSession(id);

  if (!deleted) {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }

  return NextResponse.json({ success: true });
}
