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
    const events: ClaudeStreamEvent[] = [];
    const schema = JSON.stringify(STRUCTURED_OUTPUT_SCHEMA);

    // Build args like ccui.sh does
    const args = ["-p", prompt, "--output-format", "stream-json", "--json-schema", schema];

    if (sessionId) {
      args.push("--resume", sessionId);
    }

    // Add system prompt if provided
    if (appendSystemPrompt) {
      const tempFile = `/tmp/ccweb_system_prompt_${Date.now()}.txt`;
      await fs.promises.writeFile(tempFile, appendSystemPrompt);
      args.push("--append-system-prompt", tempFile);
    }

    try {
      // Yield init event first
      yield {
        type: "init",
        model: "claude-sonnet-4-5-20250929",
      };

      // Use a queue to collect events from the process
      let model = "claude-sonnet-4-5-20250929";
      let outputBuffer = "";

      await new Promise<void>((resolve, reject) => {
        const claude = spawn("claude", args, {
          stdio: ["pipe", "pipe", "pipe"],
        });

        claude.stdout.on("data", (chunk: Buffer) => {
          outputBuffer += chunk.toString();
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

              // Handle text content
              if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
                events.push({
                  type: "text",
                  content: event.delta.text,
                });
              }

              // Handle thinking content
              if (event.type === "content_block_delta" && event.delta?.type === "thinking_delta") {
                events.push({
                  type: "thinking",
                  content: event.delta.thinking,
                });
              }

              // Handle result event
              if (event.type === "result") {
                const duration = Date.now() - startTime;
                events.push({
                  type: "result",
                  duration_ms: duration,
                });

                // Extract structured output from result
                if (event.structured_output) {
                  events.push({
                    type: "structured_output",
                    structured_output: event.structured_output,
                  });
                }
              }
            } catch (e) {
              // Ignore JSON parse errors for non-JSON output
            }
          }
        });

        claude.on("close", (code: number) => {
          if (code !== 0) {
            reject(new Error(`claude CLI exited with code ${code}`));
          } else {
            resolve();
          }
        });

        claude.on("error", (err: Error) => {
          reject(err);
        });
      });

      // Now yield all collected events
      for (const event of events) {
        yield event;
      }
    } catch (error) {
      yield {
        type: "error",
        error: error instanceof Error ? error.message : String(error),
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
