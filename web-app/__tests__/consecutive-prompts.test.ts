import { ClaudeClient, type ClaudeStreamEvent } from "../lib/claude-client";
import { MockChildProcess } from "./test-utils";
import * as child_process from "child_process";

jest.mock("child_process");

describe("ClaudeClient - Consecutive Prompts", () => {
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

  it("should show text for second prompt when text_delta events not received", async () => {
    // Simulate second prompt scenario: includePartialMessages=true but NO text_delta events arrive
    const events: ClaudeStreamEvent[] = [];
    const streamPromise = (async () => {
      for await (const event of client.streamCommand("second prompt", {
        includePartialMessages: true,
        sessionId: "test-session-123"
      })) {
        events.push(event);
      }
    })();

    await new Promise(resolve => setTimeout(resolve, 10));

    // NO text_delta events arrive (this is the bug scenario)

    // Only send final StructuredOutput
    const finalMsg = {
      type: "assistant",
      message: {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            name: "StructuredOutput",
            input: { response: "This is the second response" },
          },
        ],
      },
    };
    mockProcess.emitData(JSON.stringify(finalMsg) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    mockProcess.emitClose(0);
    await streamPromise;

    const textEvents = events.filter(e => e.type === "text");

    // MUST have at least 1 text event (the StructuredOutput fallback)
    expect(textEvents.length).toBeGreaterThanOrEqual(1);
    expect(textEvents[0].content).toBe("This is the second response");
  });

  it("should NOT show StructuredOutput text when text_delta events ARE received", async () => {
    const events: ClaudeStreamEvent[] = [];
    const streamPromise = (async () => {
      for await (const event of client.streamCommand("first prompt", {
        includePartialMessages: true
      })) {
        events.push(event);
      }
    })();

    await new Promise(resolve => setTimeout(resolve, 10));

    // Send text_delta events (normal streaming scenario)
    const delta1 = {
      type: "content_block_delta",
      delta: { type: "text_delta", text: "This is " },
    };
    const delta2 = {
      type: "content_block_delta",
      delta: { type: "text_delta", text: "the first response" },
    };
    mockProcess.emitData(JSON.stringify(delta1) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));
    mockProcess.emitData(JSON.stringify(delta2) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    // Send final StructuredOutput
    const finalMsg = {
      type: "assistant",
      message: {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            name: "StructuredOutput",
            input: { response: "This is the first response" },
          },
        ],
      },
    };
    mockProcess.emitData(JSON.stringify(finalMsg) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    mockProcess.emitClose(0);
    await streamPromise;

    const textEvents = events.filter(e => e.type === "text");

    // Should only have the 2 delta events, NOT the StructuredOutput text (to avoid duplication)
    expect(textEvents.length).toBe(2);
    expect(textEvents[0].content).toBe("This is ");
    expect(textEvents[1].content).toBe("the first response");
  });
});
