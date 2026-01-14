import { NextResponse } from "next/server";

export async function GET() {
  // Using claude-sonnet-4-5 as the current version
  // This could be fetched from Anthropic SDK or environment variable
  const version = "claude-sonnet-4-5-20250929";

  return NextResponse.json({ version });
}
