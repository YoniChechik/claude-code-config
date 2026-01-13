import { NextResponse } from "next/server";

/**
 * GET /api/cwd - Get current working directory where ccweb was launched
 */
export async function GET() {
  // Use the original cwd from when ccweb was launched, not the Next.js process cwd
  const cwd = process.env.CCWEB_ORIGINAL_CWD || process.cwd();
  return NextResponse.json({ cwd });
}
