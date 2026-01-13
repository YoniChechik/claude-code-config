import { NextRequest } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { ClaudeClient } from "@/lib/claude-client";
import type { SendCommandRequest } from "@/lib/types";

/**
 * POST /api/commands - Send command to Claude (streaming response)
 */
export async function POST(request: NextRequest) {
  const body = (await request.json()) as SendCommandRequest;
  const { sessionId, prompt } = body;

  if (!sessionId || !prompt) {
    return new Response(
      JSON.stringify({ error: "sessionId and prompt are required" }),
      { status: 400, headers: { "Content-Type": "application/json" } }
    );
  }

  const session = sessionManager.getSession(sessionId);
  if (!session) {
    return new Response(JSON.stringify({ error: "Session not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  }

  const tracker = sessionManager.getCDTracker(sessionId);
  if (!tracker) {
    return new Response(
      JSON.stringify({ error: "Session tracker not found" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  // Add user message to session
  sessionManager.addMessage(sessionId, {
    role: "user",
    content: prompt,
    timestamp: new Date(),
  });

  // Create streaming response
  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();

      try {
        const client = new ClaudeClient(process.env.CLAUDE_API_KEY);

        // Stream events from Claude
        for await (const event of client.streamCommand(prompt, sessionId)) {
          // Send event as SSE format
          const data = `data: ${JSON.stringify(event)}\n\n`;
          controller.enqueue(encoder.encode(data));

          // Track CD changes, model, and duration
          if (event.type === "init" && event.model) {
            tracker.processInitEvent({ model: event.model });
          } else if (event.type === "result" && event.duration_ms !== undefined) {
            tracker.processResultEvent({ duration_ms: event.duration_ms });
          } else if (
            event.type === "structured_output" &&
            event.structured_output
          ) {
            tracker.processStructuredOutput(event.structured_output);
          }
        }

        // Update session from tracker
        sessionManager.updateSessionFromTracker(sessionId);

        // Send completion marker
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      } catch (error) {
        const errorEvent = {
          type: "error",
          error: error instanceof Error ? error.message : String(error),
        };
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify(errorEvent)}\n\n`)
        );
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
}
