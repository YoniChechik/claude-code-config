import { ClaudeClient, type ClaudeStreamEvent } from "../lib/claude-client";
import { MockChildProcess } from "./test-utils";
import * as child_process from "child_process";

jest.mock("child_process");

describe("ClaudeClient", () => {
  let client: ClaudeClient;
  let mockProcess: MockChildProcess;

  beforeEach(() => {
    client = new ClaudeClient();
    mockProcess = new MockChildProcess();
    (child_process.spawn as jest.Mock).mockReturnValue(mockProcess);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe("constructor", () => {
    it("should create client without API key", () => {
      expect(() => new ClaudeClient()).not.toThrow();
    });

    it("should create client with API key", () => {
      expect(() => new ClaudeClient("test-api-key")).not.toThrow();
    });
  });

  describe("getModels", () => {
    it("should return list of available models", () => {
      const models = client.getModels();
      expect(models).toContain("claude-sonnet-4-5-20250929");
      expect(models).toContain("claude-opus-4-5-20251101");
      expect(models).toContain("claude-3-5-sonnet-20241022");
      expect(models.length).toBeGreaterThan(0);
    });

    it("should return models as array", () => {
      const models = client.getModels();
      expect(Array.isArray(models)).toBe(true);
    });
  });

  describe("getDefaultModel", () => {
    it("should return default model", () => {
      const model = client.getDefaultModel();
      expect(model).toBe("claude-sonnet-4-5-20250929");
    });

    it("should return a non-empty string", () => {
      const model = client.getDefaultModel();
      expect(typeof model).toBe("string");
      expect(model.length).toBeGreaterThan(0);
    });

    it("should return a model that exists in getModels", () => {
      const models = client.getModels();
      const defaultModel = client.getDefaultModel();
      expect(models).toContain(defaultModel);
    });
  });

  describe("streamCommand", () => {
    it("should yield init event immediately", async () => {
      const streamPromise = client.streamCommand("test prompt");
      const iterator = streamPromise[Symbol.asyncIterator]();

      const firstEvent = await iterator.next();

      expect(firstEvent.done).toBe(false);
      expect(firstEvent.value.type).toBe("init");
      expect(firstEvent.value.model).toBe("claude-sonnet-4-5-20250929");

      mockProcess.emitClose(0);
    });

    it("should parse init event with session_id", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const initEvent = {
        type: "init",
        subtype: "init",
        model: "claude-sonnet-4-5-20250929",
        session_id: "test-session-123",
      };
      mockProcess.emitData(JSON.stringify(initEvent) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const initEvents = events.filter(e => e.type === "init" && e.session_id);
      expect(initEvents.length).toBeGreaterThan(0);
      expect(initEvents[0].session_id).toBe("test-session-123");
    });

    it("should parse text content from assistant messages", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const assistantMsg = {
        type: "assistant",
        message: {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              name: "StructuredOutput",
              input: { response: "Hello from Claude!" },
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(assistantMsg) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const textEvents = events.filter(e => e.type === "text");
      expect(textEvents.length).toBeGreaterThan(0);
      expect(textEvents[0].content).toBe("Hello from Claude!");
    });

    it("should emit tool_use and tool_result immediately without buffering", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const toolUseMsg = {
        type: "assistant",
        message: {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: "tool_001",
              name: "Read",
              input: { file_path: "/test.txt" },
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(toolUseMsg) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));

      const toolResultMsg = {
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: "tool_001",
              content: "file content",
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(toolResultMsg) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const toolUseEvents = events.filter(e => e.type === "tool_use");
      const toolResultEvents = events.filter(e => e.type === "tool_result");

      // Both should be emitted immediately (no buffering)
      expect(toolUseEvents.length).toBe(1);
      expect(toolResultEvents.length).toBe(1);

      const toolUseIdx = events.findIndex(e => e.type === "tool_use");
      const toolResultIdx = events.findIndex(e => e.type === "tool_result");
      expect(toolUseIdx).toBeLessThan(toolResultIdx);
    });

    it("should parse token usage from system reminders", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const tokenMsg = {
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "text",
              text: "Token usage: 1000/200000; 199000 remaining",
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(tokenMsg) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const tokenEvents = events.filter(e => e.type === "token_usage");
      expect(tokenEvents.length).toBeGreaterThan(0);
      expect(tokenEvents[0].token_usage?.used).toBe(1000);
      expect(tokenEvents[0].token_usage?.total).toBe(200000);
      expect(tokenEvents[0].token_usage?.remaining).toBe(199000);
    });

    it("should parse structured output from result event", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const resultEvent = {
        type: "result",
        structured_output: {
          response: "Task complete",
          wanted_cwd: "/new/path",
        },
      };
      mockProcess.emitData(JSON.stringify(resultEvent) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const structuredEvents = events.filter(e => e.type === "structured_output");
      expect(structuredEvents.length).toBeGreaterThan(0);
      expect(structuredEvents[0].structured_output?.response).toBe("Task complete");
      expect(structuredEvents[0].structured_output?.wanted_cwd).toBe("/new/path");
    });

    it("should handle process errors", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      mockProcess.emitError(new Error("Process spawn failed"));
      mockProcess.emitClose(1);

      await streamPromise;

      const errorEvents = events.filter(e => e.type === "error");
      expect(errorEvents.length).toBeGreaterThan(0);
    });

    it("should handle non-zero exit codes", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitStderr("Error occurred");
      mockProcess.emitClose(1);

      await streamPromise;

      expect(events.some(e => e.type === "error")).toBe(true);
    });

    it("should skip StructuredOutput tool_use events", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test")) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const structuredToolMsg = {
        type: "assistant",
        message: {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: "tool_structured",
              name: "StructuredOutput",
              input: { response: "Test" },
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(structuredToolMsg) + "\n");

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const toolUseEvents = events.filter(e => e.type === "tool_use");
      const hasStructuredOutput = toolUseEvents.some(
        e => e.tool?.name === "StructuredOutput"
      );
      expect(hasStructuredOutput).toBe(false);
    });

    it("should process text_delta events when includePartialMessages is enabled", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test", { includePartialMessages: true })) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      // Send multiple text_delta events
      const delta1 = {
        type: "content_block_delta",
        delta: { type: "text_delta", text: "Hello " },
      };
      const delta2 = {
        type: "content_block_delta",
        delta: { type: "text_delta", text: "world!" },
      };

      mockProcess.emitData(JSON.stringify(delta1) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitData(JSON.stringify(delta2) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));

      mockProcess.emitClose(0);
      await streamPromise;

      const textEvents = events.filter(e => e.type === "text");
      expect(textEvents.length).toBeGreaterThanOrEqual(2);
      expect(textEvents[0].content).toBe("Hello ");
      expect(textEvents[1].content).toBe("world!");
    });

    it("should pass includePartialMessages flag to CLI", async () => {
      const streamPromise = (async () => {
        for await (const _ of client.streamCommand("test", { includePartialMessages: true })) {
          // Consume stream
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const spawnCall = (child_process.spawn as jest.Mock).mock.calls[0];
      const args = spawnCall[1] as string[];
      expect(args).toContain("--include-partial-messages");
    });

    it("should not pass includePartialMessages flag when disabled", async () => {
      const streamPromise = (async () => {
        for await (const _ of client.streamCommand("test", { includePartialMessages: false })) {
          // Consume stream
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitClose(0);
      await streamPromise;

      const spawnCall = (child_process.spawn as jest.Mock).mock.calls[0];
      const args = spawnCall[1] as string[];
      expect(args).not.toContain("--include-partial-messages");
    });

    it("should skip StructuredOutput text when text_delta events received", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test", { includePartialMessages: true })) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      // Send text_delta events first
      const delta1 = {
        type: "content_block_delta",
        delta: { type: "text_delta", text: "Partial " },
      };
      const delta2 = {
        type: "content_block_delta",
        delta: { type: "text_delta", text: "message" },
      };
      mockProcess.emitData(JSON.stringify(delta1) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitData(JSON.stringify(delta2) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));

      // Then send final StructuredOutput
      const finalMsg = {
        type: "assistant",
        message: {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              name: "StructuredOutput",
              input: { response: "Partial message - complete" },
            },
          ],
        },
      };
      mockProcess.emitData(JSON.stringify(finalMsg) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));

      mockProcess.emitClose(0);
      await streamPromise;

      const textEvents = events.filter(e => e.type === "text");
      // Should only have 2 delta events, NOT StructuredOutput text (to avoid duplication)
      expect(textEvents.length).toBe(2);
      expect(textEvents[0].content).toBe("Partial ");
      expect(textEvents[1].content).toBe("message");
    });

    it("should parse thinking_delta alongside text_delta", async () => {
      const events: ClaudeStreamEvent[] = [];
      const streamPromise = (async () => {
        for await (const event of client.streamCommand("test", { includePartialMessages: true })) {
          events.push(event);
        }
      })();

      await new Promise(resolve => setTimeout(resolve, 10));

      const thinkingDelta = {
        type: "content_block_delta",
        delta: { type: "thinking_delta", thinking: "Let me think..." },
      };
      const textDelta = {
        type: "content_block_delta",
        delta: { type: "text_delta", text: "Here's the answer" },
      };

      mockProcess.emitData(JSON.stringify(thinkingDelta) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));
      mockProcess.emitData(JSON.stringify(textDelta) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));

      mockProcess.emitClose(0);
      await streamPromise;

      const thinkingEvents = events.filter(e => e.type === "thinking");
      const textEvents = events.filter(e => e.type === "text");

      expect(thinkingEvents.length).toBe(1);
      expect(thinkingEvents[0].content).toBe("Let me think...");
      expect(textEvents.length).toBe(1);
      expect(textEvents[0].content).toBe("Here's the answer");
    });
  });
});
