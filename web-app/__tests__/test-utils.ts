import type { ClaudeStreamEvent } from "../lib/claude-client";
import { EventEmitter } from "events";

/**
 * Mock Claude API stream events for testing
 */
export function* mockClaudeStream(
  options: {
    text?: string;
    error?: string;
    sessionId?: string;
    includeToolUse?: boolean;
    includeTokenUsage?: boolean;
    wantedCwd?: string;
  } = {},
): Generator<ClaudeStreamEvent> {
  const {
    text = "Test response",
    error,
    sessionId = "test-session-123",
    includeToolUse = false,
    includeTokenUsage = false,
    wantedCwd,
  } = options;

  // Init event
  yield {
    type: "init",
    model: "claude-sonnet-4-5-20250929",
    session_id: sessionId,
  };

  if (error) {
    yield {
      type: "error",
      error,
    };
    return;
  }

  // Text content
  yield {
    type: "text",
    content: text,
  };

  // Optional tool use
  if (includeToolUse) {
    yield {
      type: "tool_use",
      tool: {
        id: "tool_123",
        name: "Read",
        input: { file_path: "/test/file.txt" },
        timestamp: new Date(),
      },
    };

    yield {
      type: "tool_result",
      tool_result: {
        tool_use_id: "tool_123",
        content: "File content here",
      },
    };
  }

  // Optional token usage
  if (includeTokenUsage) {
    yield {
      type: "token_usage",
      token_usage: {
        used: 1000,
        total: 200000,
        remaining: 199000,
      },
    };
  }

  // Result with structured output
  yield {
    type: "result",
    duration_ms: 1234,
  };

  yield {
    type: "structured_output",
    structured_output: {
      response: text,
      wanted_cwd: wantedCwd,
    },
  };
}

/**
 * Mock child process for testing ClaudeClient spawn
 */
export class MockChildProcess extends EventEmitter {
  stdout = new EventEmitter();
  stderr = new EventEmitter();
  stdin = {
    end: jest.fn(),
    write: jest.fn(),
  };
  kill = jest.fn();

  emitData(data: string) {
    this.stdout.emit("data", Buffer.from(data));
  }

  emitError(error: Error) {
    this.emit("error", error);
  }

  emitClose(code: number | null = 0, signal: string | null = null) {
    this.emit("close", code, signal);
  }

  emitStderr(data: string) {
    this.stderr.emit("data", Buffer.from(data));
  }
}

/**
 * Create async generator from sync generator for testing
 */
export async function* asyncFromSync<T>(
  gen: Generator<T>,
): AsyncGenerator<T> {
  for (const item of gen) {
    yield item;
  }
}

/**
 * Collect all items from async generator
 */
export async function collectAsyncGenerator<T>(
  gen: AsyncGenerator<T>,
): Promise<T[]> {
  const items: T[] = [];
  for await (const item of gen) {
    items.push(item);
  }
  return items;
}

/**
 * Mock child_process spawn for testing ClaudeClient
 */
export function mockSpawn() {
  class MockChildProcess extends EventEmitter {
    stdout = new EventEmitter();
    stderr = new EventEmitter();
    stdin = {
      end: jest.fn(),
    };
    kill = jest.fn();
  }

  return {
    mockProcess: new MockChildProcess(),
    spawn: jest.fn(() => new MockChildProcess()),
  };
}

/**
 * Wait for next tick
 */
export function nextTick(): Promise<void> {
  return new Promise((resolve) => process.nextTick(resolve));
}

/**
 * Wait for specified milliseconds
 */
export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
