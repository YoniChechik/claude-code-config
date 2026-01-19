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

  it("should stream text from input_json_delta for StructuredOutput on resumed sessions", async () => {
    // Simulate resumed session: input_json_delta events instead of text_delta
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

    // Send content_block_start for StructuredOutput tool
    const blockStart = {
      type: "stream_event",
      event: {
        type: "content_block_start",
        content_block: {
          type: "tool_use",
          name: "StructuredOutput",
          id: "tool_123"
        }
      }
    };
    mockProcess.emitData(JSON.stringify(blockStart) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    // Send input_json_delta events with partial JSON
    const deltas = [
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: '{"response":' } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: ' "Hello ' } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: 'World' } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: '!"}' } } },
    ];

    for (const delta of deltas) {
      mockProcess.emitData(JSON.stringify(delta) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));
    }

    // Send content_block_stop
    const blockStop = {
      type: "stream_event",
      event: { type: "content_block_stop" }
    };
    mockProcess.emitData(JSON.stringify(blockStop) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    mockProcess.emitClose(0);
    await streamPromise;

    const textEvents = events.filter(e => e.type === "text");

    // Should have multiple text events from parsing input_json_delta
    expect(textEvents.length).toBeGreaterThan(0);
    // Combined text should be "Hello World!"
    const combinedText = textEvents.map(e => e.content).join("");
    expect(combinedText).toBe("Hello World!");
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

  it("should not show duplicate text for second prompt after streaming via input_json_delta", async () => {
    const events: ClaudeStreamEvent[] = [];
    const streamPromise = (async () => {
      for await (const event of client.streamCommand("second prompt", {
        includePartialMessages: true,
        sessionId: "test-session-456"
      })) {
        events.push(event);
      }
    })();

    await new Promise(resolve => setTimeout(resolve, 10));

    // Send content_block_start for StructuredOutput
    const blockStart = {
      type: "stream_event",
      event: {
        type: "content_block_start",
        content_block: {
          type: "tool_use",
          name: "StructuredOutput",
          id: "tool_789"
        }
      }
    };
    mockProcess.emitData(JSON.stringify(blockStart) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    // Stream via input_json_delta
    const deltas = [
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: '{"response":"Second ' } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: 'response text"}' } } }
    ];

    for (const delta of deltas) {
      mockProcess.emitData(JSON.stringify(delta) + "\n");
      await new Promise(resolve => setTimeout(resolve, 10));
    }

    // Send content_block_stop
    const blockStop = {
      type: "stream_event",
      event: { type: "content_block_stop" }
    };
    mockProcess.emitData(JSON.stringify(blockStop) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    // Send final assistant message with StructuredOutput
    const finalMsg = {
      type: "assistant",
      message: {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            name: "StructuredOutput",
            input: { response: "Second response text" }
          }
        ]
      }
    };
    mockProcess.emitData(JSON.stringify(finalMsg) + "\n");
    await new Promise(resolve => setTimeout(resolve, 10));

    mockProcess.emitClose(0);
    await streamPromise;

    const textEvents = events.filter(e => e.type === "text");

    // Should have streamed text events but NOT the final StructuredOutput (to avoid duplication)
    expect(textEvents.length).toBeGreaterThan(0);
    const combinedText = textEvents.map(e => e.content).join("");
    expect(combinedText).toBe("Second response text");

    // Verify we don't have duplicate - text should appear exactly once
    expect(textEvents.filter(e => e.content === "Second response text").length).toBe(0);
  });
});
