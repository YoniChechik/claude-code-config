import Anthropic from "@anthropic-ai/sdk";

/**
 * Claude client wrapper for streaming commands
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
  private client: Anthropic;
  private apiKey: string;

  constructor(apiKey?: string) {
    this.apiKey = apiKey || process.env.CLAUDE_API_KEY || "";
    if (!this.apiKey) {
      throw new Error("CLAUDE_API_KEY not found in environment");
    }
    this.client = new Anthropic({ apiKey: this.apiKey });
  }

  /**
   * Stream a command to Claude with structured output
   * This mimics the behavior of ccui.sh's run_claude function
   */
  async *streamCommand(
    prompt: string,
    sessionId?: string,
    appendSystemPrompt?: string
  ): AsyncGenerator<ClaudeStreamEvent> {
    const startTime = Date.now();

    try {
      // Build messages array
      const messages: Anthropic.MessageCreateParams["messages"] = [
        {
          role: "user",
          content: prompt,
        },
      ];

      // Build system prompt if needed
      let system = undefined;
      if (appendSystemPrompt) {
        system = appendSystemPrompt;
      }

      // Create streaming request with json_schema for structured output
      const stream = await this.client.messages.create({
        model: "claude-sonnet-4-5-20250929",
        max_tokens: 8192,
        messages,
        system,
        // @ts-expect-error - json_schema is valid but not in types yet
        response_format: {
          type: "json_schema",
          json_schema: STRUCTURED_OUTPUT_SCHEMA,
        },
        stream: true,
      });

      let currentModel = "claude-sonnet-4-5-20250929";

      // Yield init event with model
      yield {
        type: "init",
        model: currentModel,
      };

      // Process stream events
      for await (const event of stream) {
        if (event.type === "message_start") {
          currentModel = event.message.model || currentModel;
        } else if (event.type === "content_block_start") {
          // Handle different content block types
          if (event.content_block.type === "text") {
            // Text block started
          } else if (event.content_block.type === "thinking") {
            yield {
              type: "thinking",
              content: "",
            };
          }
        } else if (event.type === "content_block_delta") {
          if (event.delta.type === "text_delta") {
            yield {
              type: "text",
              content: event.delta.text,
            };
          } else if (event.delta.type === "thinking_delta") {
            yield {
              type: "thinking",
              content: event.delta.thinking,
            };
          }
        } else if (event.type === "message_delta") {
          // Handle stop reason, usage, etc.
        } else if (event.type === "message_stop") {
          // Message complete
        }
      }

      // Yield result event with duration
      const duration = Date.now() - startTime;
      yield {
        type: "result",
        duration_ms: duration,
      };
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
