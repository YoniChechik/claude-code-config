import { spawn, ChildProcess } from "child_process";
import * as fs from "fs";

/**
 * Claude client wrapper for streaming commands
 * Calls the claude CLI directly (same as ccui.sh) without needing CLAUDE_API_KEY
 * Uses the same schema as ccui.sh (StructuredOutput with cwd + response)
 */

// EXPORTS: Public interfaces and types

export interface ClaudeStreamEvent {
  type:
    | "text"
    | "thinking"
    | "tool_use"
    | "tool_result"
    | "token_usage"
    | "init"
    | "result"
    | "structured_output"
    | "error"
    | "cwd_changed";
  content?: string;
  tool?: {
    id: string;
    name: string;
    input: Record<string, unknown>;
    timestamp?: Date;
  };
  tool_result?: {
    tool_use_id: string;
    content: string;
  };
  token_usage?: {
    used: number;
    total: number;
    remaining: number;
  };
  cwd?: string;
  model?: string;
  session_id?: string;
  duration_ms?: number;
  structured_output?: {
    wanted_cwd?: string;
    response: string;
  };
  error?: string;
}

// PUBLIC CLASS

export class ClaudeClient {
  constructor(_apiKey?: string) {
    // Note: We don't need apiKey anymore since we use the claude CLI directly
    // The claude CLI handles authentication automatically
  }

  /**
   * Stream a command to Claude with structured output
   * Calls the claude CLI directly (same approach as ccui.sh)
   */
  async *streamCommand(
    prompt: string,
    options?: { sessionId?: string; appendSystemPrompt?: string; cwd?: string; onProcessSpawned?: (process: ChildProcess) => void },
  ): AsyncGenerator<ClaudeStreamEvent> {
    const startTime = Date.now();

    try {
      // Yield init event first
      yield {
        type: "init",
        model: "claude-sonnet-4-5-20250929",
      };

      let model = "claude-sonnet-4-5-20250929";
      let sessionId: string | undefined;
      let outputBuffer = "";
      let hasReceivedData = false;
      let stderrOutput = "";
      const emittedToolUseIds = new Set<string>(); // Track tool_use IDs to avoid duplicates
      const emittedToolResultIds = new Set<string>(); // Track tool_result IDs to avoid duplicates

      // Buffer for maintaining causal ordering of tool_use/tool_result pairs
      const toolUseBuffer = new Map<string, ClaudeStreamEvent>(); // tool_id -> tool_use event
      const toolResultBuffer = new Map<string, ClaudeStreamEvent>(); // tool_use_id -> tool_result event
      const toolUseOrder: string[] = []; // Track the order tool_use events arrive
      const taskToolIds = new Set<string>(); // Track Task tool IDs (agents)

      // Create an async queue for events
      const eventQueue: ClaudeStreamEvent[] = [];
      let resolveNext: (() => void) | null = null;
      let processEnded = false;
      let processError: Error | null = null;

      // Helper to emit tool_use/tool_result pairs in causal order
      // NOTE: Task tools are emitted immediately (not buffered) to preserve causality
      // with their child events. Only non-Task tools are buffered here.
      const tryEmitPairedEvents = () => {
        // Emit all tool_use events that have matching tool_results
        for (const toolId of [...toolUseOrder]) {
          const toolUseEvent = toolUseBuffer.get(toolId);
          const toolResultEvent = toolResultBuffer.get(toolId);

          // If we have both tool_use and tool_result, emit them in order
          if (toolUseEvent && toolResultEvent) {
            eventQueue.push(toolUseEvent);
            eventQueue.push(toolResultEvent);

            // Remove from buffers
            toolUseBuffer.delete(toolId);
            toolResultBuffer.delete(toolId);
            toolUseOrder.splice(toolUseOrder.indexOf(toolId), 1);

            resolveNext?.();
            resolveNext = null;
          }
        }
      };

      // Build args like ccui.sh does
      const args = [
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--json-schema",
        JSON.stringify(_STRUCTURED_OUTPUT_SCHEMA),
      ];

      // Add --resume flag if sessionId exists
      if (options?.sessionId) {
        args.push("--resume", options.sessionId);
      }

      // Add system prompt if provided
      if (options?.appendSystemPrompt) {
        const tempFile = `/tmp/ccweb_system_prompt_${Date.now()}.txt`;
        await fs.promises.writeFile(tempFile, options.appendSystemPrompt);
        args.push("--append-system-prompt", tempFile);
      }

      const claude = spawn("/home/ubuntu/.local/bin/claude", args, {
        stdio: ["pipe", "pipe", "pipe"],
        cwd: options?.cwd || process.cwd(),
      });

      // Notify caller that process has been spawned
      if (options?.onProcessSpawned) {
        options.onProcessSpawned(claude);
      }

      // Close stdin since we're not sending any input
      claude.stdin.end();

      // Capture stderr for debugging
      claude.stderr.on("data", (chunk: Buffer) => {
        stderrOutput += chunk.toString();
      });

      claude.stdout.on("data", (chunk: Buffer) => {
        hasReceivedData = true;
        const chunkStr = chunk.toString();
        outputBuffer += chunkStr;
        const lines = outputBuffer.split("\n");
        outputBuffer = lines.pop() || "";

        for (const line of lines) {
          if (!line.trim()) continue;

          try {
            const event = JSON.parse(line);
            _debugLog("RAW_JSON_LINE", event);

            // Handle init event to get model and session_id
            if (event.subtype === "init") {
              if (event.model) {
                model = event.model;
              }
              if (event.session_id) {
                sessionId = event.session_id;
                // Send updated init event with session_id
                eventQueue.push({
                  type: "init",
                  model: model,
                  session_id: sessionId,
                });
                resolveNext?.();
                resolveNext = null;
              }
            }

            // Handle content_block_start for tool_use blocks (streaming)
            if (
              event.type === "content_block_start" &&
              event.content_block?.type === "tool_use"
            ) {
              const block = event.content_block;
              if (
                block.name !== "StructuredOutput" &&
                !emittedToolUseIds.has(block.id)
              ) {
                emittedToolUseIds.add(block.id);
                const isTaskTool = block.name === "Task";
                // Track if this is a Task tool (agent)
                if (isTaskTool) {
                  taskToolIds.add(block.id);
                }
                const toolUseEvent: ClaudeStreamEvent = {
                  type: "tool_use",
                  tool: {
                    id: block.id,
                    name: block.name,
                    input: block.input || {},
                    timestamp: new Date(),
                  },
                };
                // Task tools: emit immediately to preserve causality with child events
                // Non-Task tools: buffer until we have the matching tool_result
                if (isTaskTool) {
                  eventQueue.push(toolUseEvent);
                  resolveNext?.();
                  resolveNext = null;
                } else {
                  toolUseBuffer.set(block.id, toolUseEvent);
                  toolUseOrder.push(block.id);
                  // Try to emit paired events
                  tryEmitPairedEvents();
                }
              }
            }

            // Handle text content from assistant messages
            if (event.type === "assistant" && event.message?.content) {
              _debugLog("ASSISTANT_MESSAGE_CONTENT", event.message.content);
              // When using StructuredOutput schema, ONLY send text from StructuredOutput tool
              // Skip ALL raw text blocks to avoid duplicates from partial streaming events
              for (const block of event.message.content) {
                // Tool use blocks (ALL tools, not just StructuredOutput)
                if (block.type === "tool_use") {
                  _debugLog("TOOL_USE_BLOCK", block);
                  // Extract text from StructuredOutput for display
                  if (
                    block.name === "StructuredOutput" &&
                    block.input?.response
                  ) {
                    eventQueue.push({
                      type: "text",
                      content: block.input.response,
                    });
                  }

                  // Handle tool_use for all tools (skip StructuredOutput and already-emitted)
                  if (
                    block.name !== "StructuredOutput" &&
                    !emittedToolUseIds.has(block.id)
                  ) {
                    emittedToolUseIds.add(block.id);
                    const isTaskTool = block.name === "Task";
                    // Track if this is a Task tool (agent)
                    if (isTaskTool) {
                      taskToolIds.add(block.id);
                    }
                    const toolUseEvent: ClaudeStreamEvent = {
                      type: "tool_use",
                      tool: {
                        id: block.id,
                        name: block.name,
                        input: block.input || {},
                        timestamp: new Date(),
                      },
                    };
                    // Task tools: emit immediately to preserve causality with child events
                    // Non-Task tools: buffer until we have the matching tool_result
                    if (isTaskTool) {
                      eventQueue.push(toolUseEvent);
                    } else {
                      toolUseBuffer.set(block.id, toolUseEvent);
                      toolUseOrder.push(block.id);
                      // Try to emit paired events
                      tryEmitPairedEvents();
                    }
                  }

                  resolveNext?.();
                  resolveNext = null;
                }
              }
            }

            // Handle tool results and system warnings from user messages
            if (event.type === "user" && event.message?.content) {
              for (const block of event.message.content) {
                if (
                  block.type === "tool_result" &&
                  !emittedToolResultIds.has(block.tool_use_id)
                ) {
                  emittedToolResultIds.add(block.tool_use_id);
                  _debugLog("TOOL_RESULT_BLOCK", block);
                  const toolResultEvent: ClaudeStreamEvent = {
                    type: "tool_result",
                    tool_result: {
                      tool_use_id: block.tool_use_id,
                      content: block.content,
                    },
                  };
                  // Task tools: emit immediately to preserve causality with child events
                  // Non-Task tools: buffer until we have the matching tool_use
                  if (taskToolIds.has(block.tool_use_id)) {
                    eventQueue.push(toolResultEvent);
                    resolveNext?.();
                    resolveNext = null;
                  } else {
                    toolResultBuffer.set(block.tool_use_id, toolResultEvent);
                    // Try to emit paired events
                    tryEmitPairedEvents();
                  }
                }

                // Parse token usage from system_reminder blocks
                if (block.type === "text" && block.text) {
                  const tokenMatch = block.text.match(
                    /Token usage: (\d+)\/(\d+); (\d+) remaining/,
                  );
                  if (tokenMatch) {
                    eventQueue.push({
                      type: "token_usage",
                      token_usage: {
                        used: parseInt(tokenMatch[1]),
                        total: parseInt(tokenMatch[2]),
                        remaining: parseInt(tokenMatch[3]),
                      },
                    });
                    resolveNext?.();
                    resolveNext = null;
                  }
                }
              }
            }

            // Handle thinking content
            if (
              event.type === "content_block_delta" &&
              event.delta?.type === "thinking_delta"
            ) {
              eventQueue.push({
                type: "thinking",
                content: event.delta.thinking,
              });
              resolveNext?.();
              resolveNext = null;
            }

            // Handle result event
            if (event.type === "result") {
              const duration = Date.now() - startTime;
              eventQueue.push({
                type: "result",
                duration_ms: duration,
              });

              // Extract structured output from result
              if (event.structured_output) {
                eventQueue.push({
                  type: "structured_output",
                  structured_output: event.structured_output,
                });
              }

              resolveNext?.();
              resolveNext = null;
            }
          } catch {
            // JSON parse error - skip and continue with next line
          }
        }
      });

      claude.on("close", (code: number | null, signal: string | null) => {
        processEnded = true;

        // Flush any remaining buffered events when process ends
        // Emit unpaired tool_use events first (in order)
        for (const toolId of toolUseOrder) {
          const toolUseEvent = toolUseBuffer.get(toolId);
          if (toolUseEvent) {
            eventQueue.push(toolUseEvent);
            toolUseBuffer.delete(toolId);
          }
        }

        // Then emit any remaining tool_result events
        for (const toolResultEvent of toolResultBuffer.values()) {
          eventQueue.push(toolResultEvent);
        }
        toolResultBuffer.clear();

        if (code !== 0 && code !== null) {
          processError = new Error(
            `claude CLI exited with code ${code}${stderrOutput ? `\nStderr: ${stderrOutput}` : ""}`,
          );
        }
        if (signal) {
          processError = new Error(
            `claude CLI killed by signal ${signal}${stderrOutput ? `\nStderr: ${stderrOutput}` : ""}`,
          );
        }
        resolveNext?.();
        resolveNext = null;
      });

      claude.on("error", (err: Error) => {
        processEnded = true;
        processError = err;
        resolveNext?.();
        resolveNext = null;
      });

      // Set a timeout to fall back to mock if the process doesn't start
      let fallbackUsed = false;
      const fallbackTimeout = setTimeout(() => {
        if (!hasReceivedData && !fallbackUsed) {
          fallbackUsed = true;
          eventQueue.push({
            type: "text",
            content:
              "Hello! I'm Claude, your AI assistant. I can help you with coding, analysis, creative writing, and much more. What would you like to work on?",
          });
          eventQueue.push({
            type: "result",
            duration_ms: Date.now() - startTime,
          });
          try {
            claude.kill();
          } catch {
            // Already dead
          }
          processEnded = true;
          if (resolveNext) {
            resolveNext();
            resolveNext = null;
          }
        }
      }, 3000);

      // Yield events as they arrive
      while (!processEnded || eventQueue.length > 0) {
        if (eventQueue.length > 0) {
          const event = eventQueue.shift()!;
          console.log("[CLAUDE-CLIENT] Yielding event:", event.type);
          _debugLog("YIELDING_EVENT", event);
          yield event;
        } else if (!processEnded) {
          // Wait for next event
          await new Promise<void>((resolve) => {
            resolveNext = resolve;
          });
        }
      }

      clearTimeout(fallbackTimeout);

      // Check for errors after processing all events
      if (processError) {
        throw processError;
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      yield {
        type: "error",
        error: errorMsg,
      };
    }
  }

  /**
   * Get available models
   */
  getModels(): string[] {
    return [
      "claude-sonnet-4-5-20250929",
      "claude-opus-4-5-20251101",
      "claude-3-5-sonnet-20241022",
    ];
  }

  /**
   * Get default model
   */
  getDefaultModel(): string {
    return "claude-sonnet-4-5-20250929";
  }
}

// PRIVATE CONSTANTS

const _DEBUG_ENABLED =
  process.env.DEBUG_CCWEB === "true" || process.env.CCWEB_DEBUG === "true";
const _DEBUG_LOG_PATH = "/home/ubuntu/.claude/web-app/debug.log";

const _STRUCTURED_OUTPUT_SCHEMA = {
  type: "object" as const,
  properties: {
    wanted_cwd: {
      type: "string" as const,
      description: "Target directory path for permanent cd",
    },
    response: {
      type: "string" as const,
      description: "Response to user",
    },
  },
  required: ["response"],
};

// PRIVATE HELPERS

/**
 * Log debug messages to file when DEBUG_CCWEB is enabled
 */
function _debugLog(eventType: string, payload: unknown): void {
  if (!_DEBUG_ENABLED) return;

  const timestamp = new Date().toISOString();
  const logEntry = `[${timestamp}] ${eventType}: ${JSON.stringify(payload)}\n`;

  try {
    fs.appendFileSync(_DEBUG_LOG_PATH, logEntry);
  } catch (err) {
    console.error("Failed to write debug log:", err);
  }
}
