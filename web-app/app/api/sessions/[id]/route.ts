import { NextRequest, NextResponse } from "next/server";
import { sessionManager } from "@/lib/session-manager";

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
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

  // Claim ownership if session exists but has no owner (server restart scenario)
  if (!sessionManager.getOwner(id)) {
    sessionManager.claimOwnership(id, windowId);
  }

  if (!sessionManager.validateOwnership(id, windowId)) {
    return NextResponse.json(
      { error: "Session ownership validation failed" },
      { status: 403 }
    );
  }

  return NextResponse.json({ session });
}

export async function PATCH(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
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

  if (body.audioNotificationsEnabled !== undefined) {
    session.audioNotificationsEnabled = body.audioNotificationsEnabled;
  }
  if (body.includePartialMessages !== undefined) {
    session.includePartialMessages = body.includePartialMessages;
  }

  return NextResponse.json({ session });
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
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

  sessionManager.deleteSession(id);
  return NextResponse.json({ success: true });
}
