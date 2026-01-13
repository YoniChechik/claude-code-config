import { NextResponse } from "next/server";
import { loadSessionMessages } from "@/lib/session-storage";

/**
 * POST /api/sessions/load - Load full session messages from JSONL file
 */
export async function POST(request: Request) {
  const { filePath } = await request.json();

  if (!filePath || typeof filePath !== "string") {
    return NextResponse.json({ error: "Invalid filePath" }, { status: 400 });
  }

  const messages = await loadSessionMessages(filePath);
  return NextResponse.json({ messages });
}
