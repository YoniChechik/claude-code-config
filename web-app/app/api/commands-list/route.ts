import { NextResponse } from "next/server";
import { getSlashCommands, findProjectRoot } from "@/lib/autosuggest";

export async function GET() {
  try {
    // Find project root from cwd
    const cwd = process.cwd();
    const projectRoot = await findProjectRoot(cwd);

    // Get all slash commands (includes user skills, project skills, builtins)
    const commands = await getSlashCommands(projectRoot || undefined);

    return NextResponse.json({ commands });
  } catch (error) {
    console.error("Failed to load slash commands:", error);
    return NextResponse.json(
      { error: "Failed to load commands" },
      { status: 500 }
    );
  }
}
