import { NextResponse } from "next/server";
import { ClaudeClient } from "@/lib/claude-client";
import type { GetModelsResponse } from "@/lib/types";

export async function GET() {
  try {
    const client = new ClaudeClient(process.env.CLAUDE_API_KEY);
    const models = client.getModels();
    const defaultModel = client.getDefaultModel();

    const response: GetModelsResponse = {
      models,
      default: defaultModel,
    };

    return NextResponse.json(response);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : String(error) },
      { status: 500 }
    );
  }
}
