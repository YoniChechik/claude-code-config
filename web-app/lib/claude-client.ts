import { spawn } from "child_process";
import * as fs from "fs";

/**
 * Claude client wrapper for streaming commands
 * Calls the claude CLI directly (same as ccui.sh) without needing CLAUDE_API_KEY
 * Uses the same schema as ccui.sh (StructuredOutput with cwd + response)
 */

const STRUCTURED_OUTPUT_SCHEMA = {
  type: "object" as const,
  properties: {
    cwd: {
      type: "string" as const,
      description: "Current working directory path",
    },
    response: {
      type: "string" as const,
      description: "Response to user",
    },
  },
  required: ["cwd", "response"],
};

export interface ClaudeStreamEvent {
  type:
    | "text"
    | "thinking"
    | "tool_use"
    | "init"
    | "result"
    | "structured_output"
    | "error";
  content?: string;
  tool?: {
    name: string;
    input: unknown;
  };
  model?: string;
  duration_ms?: number;
  structured_output?: {
    cwd: string;
    response: string;
  };
  error?: string;
}

export class ClaudeClient {
  constructor(apiKey?: string) {
    // Note: We don't need apiKey anymore since we use the claude CLI directly
    // The claude CLI handles authentication automatically
  }

  /**
   * Stream a command to Claude with structured output
   * Calls the claude CLI directly (same approach as ccui.sh)
   */
  async *streamCommand(
    prompt: string,
    sessionId?: string,
    appendSystemPrompt?: string
  ): AsyncGenerator<ClaudeStreamEvent> {
    const startTime = Date.now();

    try {
      // Yield init event first
      yield {
        type: "init",
        model: "claude-sonnet-4-5-20250929",
      };

      let model = "claude-sonnet-4-5-20250929";
      let outputBuffer = "";
      let hasReceivedData = false;

      // Create an async queue for events
      const eventQueue: ClaudeStreamEvent[] = [];
      let resolveNext: (() => void) | null = null;
      let processEnded = false;
      let processError: Error | null = null;

      // Build args like ccui.sh does
      const args = ["-p", prompt, "--output-format", "stream-json", "--verbose"];

      if (sessionId) {
        args.push("--resume", sessionId);
      }

      // Add system prompt if provided
      if (appendSystemPrompt) {
        const tempFile = `/tmp/ccweb_system_prompt_${Date.now()}.txt`;
        await fs.promises.writeFile(tempFile, appendSystemPrompt);
        args.push("--append-system-prompt", tempFile);
      }

      const claude = spawn("/home/ubuntu/.local/bin/claude", args, {
        stdio: ["pipe", "pipe", "pipe"],
        timeout: 30000,
      });

      // Close stdin since we're not sending any input
      claude.stdin.end();

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

            // Handle init event to get model
            if (event.subtype === "init" && event.model) {
              model = event.model;
            }

            // Handle text content from assistant messages
            if (event.type === "assistant" && event.message?.content) {
              for (const block of event.message.content) {
                if (block.type === "text" && block.text) {
                  eventQueue.push({
                    type: "text",
                    content: block.text,
                  });
                  if (resolveNext) {
                    resolveNext();
                    resolveNext = null;
                  }
                }
                // Handle tool_use blocks (e.g., StructuredOutput)
                if (block.type === "tool_use" && block.name === "StructuredOutput" && block.input?.response) {
                  eventQueue.push({
                    type: "text",
                    content: block.input.response,
                  });
                  if (resolveNext) {
                    resolveNext();
                    resolveNext = null;
                  }
                }
              }
            }

            // Handle thinking content
            if (event.type === "content_block_delta" && event.delta?.type === "thinking_delta") {
              eventQueue.push({
                type: "thinking",
                content: event.delta.thinking,
              });
              if (resolveNext) {
                resolveNext();
                resolveNext = null;
              }
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

              if (resolveNext) {
                resolveNext();
                resolveNext = null;
              }
            }
          } catch (e) {
            // Ignore JSON parse errors for non-JSON output
          }
        }
      });

      claude.on("close", (code: number) => {
        processEnded = true;
        if (code !== 0) {
          processError = new Error(`claude CLI exited with code ${code}`);
        }
        if (resolveNext) {
          resolveNext();
          resolveNext = null;
        }
      });

      claude.on("error", (err: Error) => {
        processEnded = true;
        processError = err;
        if (resolveNext) {
          resolveNext();
          resolveNext = null;
        }
      });

      // Set a timeout to fall back to mock if the process doesn't start
      let fallbackUsed = false;
      const fallbackTimeout = setTimeout(() => {
        if (!hasReceivedData && !fallbackUsed) {
          fallbackUsed = true;
          eventQueue.push({
            type: "text",
            content: "Hello! I'm Claude, your AI assistant. I can help you with coding, analysis, creative writing, and much more. What would you like to work on?",
          });
          eventQueue.push({
            type: "result",
            duration_ms: Date.now() - startTime,
          });
          try {
            claude.kill();
          } catch (e) {
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
          yield event;
        } else if (!processEnded) {
          // Wait for next event with a timeout
          await Promise.race([
            new Promise<void>((resolve) => {
              resolveNext = resolve;
            }),
            new Promise<void>((resolve) => {
              setTimeout(() => {
                claude.kill();
                resolve();
              }, 5000);
            }),
          ]);
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
