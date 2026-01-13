import { NextResponse } from "next/server";

/**
 * GET /api/cwd - Get current working directory where ccweb was launched
 */
export async function GET() {
  // Use the original cwd from when ccweb was launched
  // Sessions will update their CWD dynamically via CD tracking as commands execute
  const cwd = process.env.CCWEB_ORIGINAL_CWD || "/home/ubuntu";
  return NextResponse.json({ cwd });
}
