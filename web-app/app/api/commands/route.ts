import { NextRequest } from "next/server";
import { sessionManager } from "@/lib/session-manager";
import { ClaudeClient } from "@/lib/claude-client";
import { createSessionSymlink } from "@/lib/symlink-manager";
import { loadSystemPrompt } from "@/lib/system-prompt-loader";
import { processRegistry } from "@/lib/process-registry";
import { streamRegistry } from "@/lib/stream-registry";
import type { SendCommandRequest } from "@/lib/types";

// No timeout - allow responses to take as long as needed
export const maxDuration = 0;

/**
 * POST /api/commands - Send command to Claude (streaming response)
 */
export async function POST(request: NextRequest) {
  const body = (await request.json()) as SendCommandRequest;
  const { sessionId, windowId, prompt } = body;

  if (!sessionId || !windowId || !prompt) {
    return new Response(
      JSON.stringify({ error: "sessionId, windowId, and prompt are required" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!sessionManager.validateOwnership(sessionId, windowId)) {
    console.warn(
      `[Security] Command blocked: ` +
        `sessionId=${sessionId}, windowId=${windowId}, ` +
        `owner=${sessionManager.getOwner(sessionId)}`
    );
    return new Response(
      JSON.stringify({ error: "You do not own this session" }),
      { status: 403, headers: { "Content-Type": "application/json" } }
    );
  }

  let session;
  let tracker;
  try {
    session = sessionManager.getSession(sessionId);
    tracker = sessionManager.getCDTracker(sessionId);
  } catch (error) {
    return new Response(JSON.stringify({ error: "Session not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Add user message to session
  sessionManager.addMessage(sessionId, {
    role: "user",
    content: [{ type: "text", text: prompt }],
    timestamp: new Date(),
  });

  // Create AbortController for this stream
  const abortController = new AbortController();
  streamRegistry.register(sessionId, abortController);

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
          cwd: session.cwd,
          includePartialMessages: session.includePartialMessages,
          onProcessSpawned: (process) => {
            // Register process for cleanup
            processRegistry.register(sessionId, process);
          },
        })) {
          // Check if stream was aborted
          if (abortController.signal.aborted) {
            console.log(`[Commands API] Stream aborted for session ${sessionId}`);
            break;
          }
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
          } else if (
            event.type === "result" &&
            event.duration_ms !== undefined
          ) {
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
                await createSessionSymlink(
                  claudeSessionId,
                  session.cwd,
                  wantedCwd,
                );
              }
            }
          }
        }

        // Update session from tracker and check if directory changed
        const previousCwd = session.cwd;
        sessionManager.updateSessionFromTracker(sessionId);
        const updatedSession = sessionManager.getSession(sessionId);
        const didChangeCwd =
          updatedSession && updatedSession.cwd !== previousCwd;

        // Send cwd_changed event to client so navbar updates immediately
        if (didChangeCwd) {
          const cwdChangedEvent = {
            type: "cwd_changed",
            cwd: updatedSession.cwd,
          };
          controller.enqueue(
            encoder.encode(`data: ${JSON.stringify(cwdChangedEvent)}\n\n`),
          );
        }

        // Auto-continue if directory changed BEFORE closing stream
        if (didChangeCwd) {
          try {
            const client = new ClaudeClient();
            const systemPrompt = await loadSystemPrompt();
            const continuePrompt = `Now we are in ${updatedSession.cwd}. CONTINUE`;

            // Add user message for continue
            sessionManager.addMessage(sessionId, {
              role: "user",
              content: [{ type: "text", text: continuePrompt }],
              timestamp: new Date(),
            });

            // Stream the auto-continue response to client
            for await (const event of client.streamCommand(continuePrompt, {
              sessionId: updatedSession.claudeSessionId,
              appendSystemPrompt: systemPrompt,
              cwd: updatedSession.cwd,
              includePartialMessages: updatedSession.includePartialMessages,
              onProcessSpawned: (process) => {
                // Register auto-continue process for cleanup
                processRegistry.register(sessionId, process);
              },
            })) {
              // Check if stream was aborted
              if (abortController.signal.aborted) {
                console.log(`[Commands API] Auto-continue stream aborted for session ${sessionId}`);
                break;
              }
              // Send event to client
              const data = `data: ${JSON.stringify(event)}\n\n`;
              controller.enqueue(encoder.encode(data));

              // Process events to update tracker state
              const continueTracker = sessionManager.getCDTracker(sessionId);
              if (continueTracker) {
                if (event.type === "init" && event.model) {
                  continueTracker.processInitEvent({ model: event.model });
                } else if (
                  event.type === "result" &&
                  event.duration_ms !== undefined
                ) {
                  continueTracker.processResultEvent({
                    duration_ms: event.duration_ms,
                  });
                } else if (
                  event.type === "structured_output" &&
                  event.structured_output
                ) {
                  continueTracker.processStructuredOutput(
                    event.structured_output,
                  );
                }
              }
            }

            // Update session after continue
            sessionManager.updateSessionFromTracker(sessionId);
          } catch (err) {
            console.error("Auto-continue after cd failed:", err);
            const errorEvent = {
              type: "error",
              error: err instanceof Error ? err.message : String(err),
            };
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify(errorEvent)}\n\n`),
            );
          }
        }

        // Send completion marker AFTER auto-continue
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      } catch (error) {
        const errorEvent = {
          type: "error",
          error: error instanceof Error ? error.message : String(error),
        };
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify(errorEvent)}\n\n`),
        );
      } finally {
        // Cleanup: unregister process and stream
        processRegistry.unregister(sessionId);
        streamRegistry.unregister(sessionId);
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
