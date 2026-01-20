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

  try {
    const session = sessionManager.getSession(id);

    if (!sessionManager.validateOwnership(id, windowId)) {
      return NextResponse.json(
        { error: "Session ownership validation failed" },
        { status: 403 }
      );
    }

    return NextResponse.json({ session });
  } catch {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }
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

  try {
    const session = sessionManager.getSession(id);

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
  } catch {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }
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

  try {
    sessionManager.getSession(id);

    if (!sessionManager.validateOwnership(id, windowId)) {
      return NextResponse.json(
        { error: "Session ownership validation failed" },
        { status: 403 }
      );
    }

    sessionManager.deleteSession(id);
    return NextResponse.json({ success: true });
  } catch {
    return NextResponse.json({ error: "Session not found" }, { status: 404 });
  }
}
