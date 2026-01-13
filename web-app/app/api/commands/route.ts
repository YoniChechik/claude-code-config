import { NextRequest } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { ClaudeClient } from "@/lib/claude-client";
import { createSessionSymlink } from "@/lib/symlink-manager";
import { loadSystemPrompt } from "@/lib/system-prompt-loader";
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
        const client = new ClaudeClient();

        // Pass claude session ID if exists
        const claudeSessionId = session.claudeSessionId;

        // Load custom system prompt if exists
        const systemPrompt = await loadSystemPrompt();

        // Stream events from Claude (uses claude CLI directly, no API key needed)
        for await (const event of client.streamCommand(prompt, {
          sessionId: claudeSessionId,
          appendSystemPrompt: systemPrompt,
        })) {
          // Send event as SSE format
          const data = `data: ${JSON.stringify(event)}\n\n`;
          controller.enqueue(encoder.encode(data));

          // Track CD changes, model, and duration
          if (event.type === "init") {
            if (event.model) {
              tracker.processInitEvent({ model: event.model });
            }
            // Store claude session ID from init event
            if (event.session_id) {
              sessionManager.setClaudeSessionId(sessionId, event.session_id);
            }
          } else if (event.type === "result" && event.duration_ms !== undefined) {
            tracker.processResultEvent({ duration_ms: event.duration_ms });
          } else if (
            event.type === "structured_output" &&
            event.structured_output
          ) {
            tracker.processStructuredOutput(event.structured_output);

            // Check if directory change is requested
            const wantedCwd = event.structured_output.wanted_cwd;
            if (wantedCwd && wantedCwd !== session.cwd) {
              // Create symlink BEFORE updating session
              const claudeSessionId = session.claudeSessionId;
              if (claudeSessionId) {
                await createSessionSymlink(claudeSessionId, session.cwd, wantedCwd);
              }
            }
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
