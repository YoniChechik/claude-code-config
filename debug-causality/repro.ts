/**
 * Reproduction script for causality bug in ClaudeClient
 *
 * This script demonstrates the bug where:
 * 1. An agent spawns a subagent using the Task tool
 * 2. The subagent executes "sleep 5 && echo done"
 * 3. The agent completion message arrives BEFORE the bash tool_result
 *
 * Run with: npx tsx repro.ts
 *
 * This script tests BOTH:
 * 1. Raw CLI output (to see the actual event order from Claude)
 * 2. ClaudeClient output (to see how the client processes events)
 */

import { spawn, ChildProcess } from "child_process";
import * as fs from "fs";
import { ClaudeClient, ClaudeStreamEvent } from "../web-app/lib/claude-client";

// Timestamp helper
function ts(): string {
  return new Date().toISOString();
}

// Event log entry
interface EventLogEntry {
  timestamp: string;
  elapsed_ms: number;
  event_type: string;
  tool_name?: string;
  tool_id?: string;
  content_preview?: string;
  raw_event?: unknown;
}

const eventLog: EventLogEntry[] = [];
const startTime = Date.now();

function logEvent(
  eventType: string,
  details: {
    tool_name?: string;
    tool_id?: string;
    content_preview?: string;
    raw_event?: unknown;
  } = {}
): void {
  const entry: EventLogEntry = {
    timestamp: ts(),
    elapsed_ms: Date.now() - startTime,
    event_type: eventType,
    ...details,
  };
  eventLog.push(entry);
  console.log(
    `[${entry.elapsed_ms.toString().padStart(6)}ms] ${entry.event_type}${entry.tool_name ? ` (${entry.tool_name})` : ""}${entry.tool_id ? ` [${entry.tool_id}]` : ""}${entry.content_preview ? `: ${entry.content_preview.slice(0, 100)}` : ""}`
  );
}

// The prompt that triggers the causality bug
const PROMPT = `Use the Task tool to spawn a subagent. The subagent should execute: sleep 5 && echo done
Wait for the subagent to complete and report its output.`;

async function runReproduction(): Promise<void> {
  console.log("=".repeat(80));
  console.log("CAUSALITY BUG REPRODUCTION");
  console.log("=".repeat(80));
  console.log(`Start time: ${ts()}`);
  console.log(`Prompt: ${PROMPT}`);
  console.log("=".repeat(80));
  console.log("");

  logEvent("SCRIPT_START");

  // Build args for claude CLI
  const args = ["-p", PROMPT, "--output-format", "stream-json", "--verbose"];

  logEvent("SPAWNING_CLAUDE", { content_preview: args.join(" ") });

  const claude = spawn("/home/ubuntu/.local/bin/claude", args, {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: "/home/ubuntu/.claude/debug-causality",
  });

  claude.stdin.end();

  let outputBuffer = "";
  let stderrOutput = "";

  // Track tool_use and tool_result events
  const toolUseEvents: Map<string, EventLogEntry> = new Map();
  const toolResultEvents: Map<string, EventLogEntry> = new Map();

  claude.stderr.on("data", (chunk: Buffer) => {
    stderrOutput += chunk.toString();
  });

  claude.stdout.on("data", (chunk: Buffer) => {
    const chunkStr = chunk.toString();
    outputBuffer += chunkStr;
    const lines = outputBuffer.split("\n");
    outputBuffer = lines.pop() || "";

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const event = JSON.parse(line);

        // Handle init event
        if (event.subtype === "init") {
          logEvent("INIT", {
            content_preview: `session=${event.session_id} model=${event.model}`,
          });
        }

        // Handle content_block_start for tool_use
        if (
          event.type === "content_block_start" &&
          event.content_block?.type === "tool_use"
        ) {
          const block = event.content_block;
          const entry: EventLogEntry = {
            timestamp: ts(),
            elapsed_ms: Date.now() - startTime,
            event_type: "TOOL_USE_START",
            tool_name: block.name,
            tool_id: block.id,
            raw_event: event,
          };
          toolUseEvents.set(block.id, entry);
          logEvent("TOOL_USE_START", {
            tool_name: block.name,
            tool_id: block.id,
            content_preview: JSON.stringify(block.input || {}),
          });
        }

        // Handle assistant messages with tool_use blocks
        if (event.type === "assistant" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_use") {
              if (!toolUseEvents.has(block.id)) {
                const entry: EventLogEntry = {
                  timestamp: ts(),
                  elapsed_ms: Date.now() - startTime,
                  event_type: "TOOL_USE_COMPLETE",
                  tool_name: block.name,
                  tool_id: block.id,
                  raw_event: block,
                };
                toolUseEvents.set(block.id, entry);
                logEvent("TOOL_USE_COMPLETE", {
                  tool_name: block.name,
                  tool_id: block.id,
                  content_preview: JSON.stringify(block.input || {}).slice(
                    0,
                    200
                  ),
                });
              }
            }
            if (block.type === "text" && block.text) {
              logEvent("ASSISTANT_TEXT", {
                content_preview: block.text.slice(0, 200),
              });
            }
          }
        }

        // Handle user messages with tool_result blocks
        if (event.type === "user" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_result") {
              const entry: EventLogEntry = {
                timestamp: ts(),
                elapsed_ms: Date.now() - startTime,
                event_type: "TOOL_RESULT",
                tool_id: block.tool_use_id,
                content_preview:
                  typeof block.content === "string"
                    ? block.content.slice(0, 200)
                    : JSON.stringify(block.content).slice(0, 200),
                raw_event: block,
              };
              toolResultEvents.set(block.tool_use_id, entry);
              logEvent("TOOL_RESULT", {
                tool_id: block.tool_use_id,
                content_preview:
                  typeof block.content === "string"
                    ? block.content.slice(0, 200)
                    : JSON.stringify(block.content).slice(0, 200),
              });
            }
          }
        }

        // Handle result event (end of stream)
        if (event.type === "result") {
          logEvent("RESULT", {
            content_preview: `cost=${event.cost_usd} session=${event.session_id}`,
          });
        }

        // Handle text deltas
        if (
          event.type === "content_block_delta" &&
          event.delta?.type === "text_delta"
        ) {
          // Only log if significant
          if (event.delta.text && event.delta.text.length > 0) {
            logEvent("TEXT_DELTA", {
              content_preview: event.delta.text.slice(0, 50),
            });
          }
        }
      } catch {
        // JSON parse error - skip
      }
    }
  });

  // Wait for process to complete
  await new Promise<void>((resolve, reject) => {
    claude.on("close", (code: number | null) => {
      logEvent("PROCESS_CLOSE", { content_preview: `exit_code=${code}` });
      if (code !== 0 && code !== null) {
        console.error("Stderr:", stderrOutput);
      }
      resolve();
    });
    claude.on("error", (err: Error) => {
      logEvent("PROCESS_ERROR", { content_preview: err.message });
      reject(err);
    });
  });

  // Analysis
  console.log("");
  console.log("=".repeat(80));
  console.log("EVENT ANALYSIS");
  console.log("=".repeat(80));

  // Check for causality violations
  console.log("\nTool Use Events:");
  for (const [id, entry] of toolUseEvents) {
    console.log(
      `  [${entry.elapsed_ms}ms] ${entry.tool_name} (${id.slice(0, 12)}...)`
    );
  }

  console.log("\nTool Result Events:");
  for (const [id, entry] of toolResultEvents) {
    const useEvent = toolUseEvents.get(id);
    console.log(
      `  [${entry.elapsed_ms}ms] ${id.slice(0, 12)}... (use was at ${useEvent?.elapsed_ms || "?"}ms)`
    );
  }

  // Check for Task tool results arriving after later events
  console.log("\nCausality Analysis:");
  const sortedByTime = [...eventLog].sort((a, b) => a.elapsed_ms - b.elapsed_ms);

  let taskToolUseTime: number | null = null;
  let taskToolResultTime: number | null = null;
  let lastAssistantTextTime: number | null = null;

  for (const entry of sortedByTime) {
    if (entry.tool_name === "Task" && entry.event_type.includes("TOOL_USE")) {
      taskToolUseTime = entry.elapsed_ms;
    }
    if (entry.event_type === "TOOL_RESULT" && taskToolUseTime !== null) {
      // Check if this is the Task tool's result by checking if we saw a Task tool_use
      for (const [id, useEntry] of toolUseEvents) {
        if (useEntry.tool_name === "Task" && id === entry.tool_id) {
          taskToolResultTime = entry.elapsed_ms;
        }
      }
    }
    if (entry.event_type === "ASSISTANT_TEXT") {
      lastAssistantTextTime = entry.elapsed_ms;
    }
  }

  if (taskToolUseTime !== null && taskToolResultTime !== null) {
    console.log(`  Task tool_use at: ${taskToolUseTime}ms`);
    console.log(`  Task tool_result at: ${taskToolResultTime}ms`);
    if (
      lastAssistantTextTime !== null &&
      lastAssistantTextTime < taskToolResultTime
    ) {
      console.log(`  Last assistant text at: ${lastAssistantTextTime}ms`);
      console.log(
        "\n  CAUSALITY VIOLATION: Assistant response appeared before Task result!"
      );
    }
  }

  // Write full event log to file
  const logPath = "/home/ubuntu/.claude/debug-causality/event_log.json";
  fs.writeFileSync(logPath, JSON.stringify(eventLog, null, 2));
  console.log(`\nFull event log written to: ${logPath}`);

  console.log("");
  console.log("=".repeat(80));
  console.log("END OF REPRODUCTION");
  console.log("=".repeat(80));
}

async function runClaudeClientTest(): Promise<void> {
  console.log("");
  console.log("=".repeat(80));
  console.log("CLAUDE CLIENT TEST");
  console.log("=".repeat(80));
  console.log(`Start time: ${ts()}`);
  console.log("Testing event ordering through ClaudeClient...");
  console.log("=".repeat(80));
  console.log("");

  const client = new ClaudeClient();
  const clientEventLog: EventLogEntry[] = [];
  const clientStartTime = Date.now();

  const prompt = `Use the Task tool to spawn a subagent. The subagent should execute: sleep 3 && echo done
Wait for the subagent to complete and report its output.`;

  try {
    for await (const event of client.streamCommand(prompt, {
      cwd: "/home/ubuntu/.claude/debug-causality",
    })) {
      const entry: EventLogEntry = {
        timestamp: ts(),
        elapsed_ms: Date.now() - clientStartTime,
        event_type: event.type,
        tool_name: event.tool?.name,
        tool_id: event.tool?.id || event.tool_result?.tool_use_id,
        content_preview:
          event.content?.slice(0, 100) ||
          event.tool_result?.content?.slice(0, 100) ||
          JSON.stringify(event.tool?.input || {}).slice(0, 100),
      };
      clientEventLog.push(entry);

      console.log(
        `[${entry.elapsed_ms.toString().padStart(6)}ms] ${entry.event_type}${entry.tool_name ? ` (${entry.tool_name})` : ""}${entry.tool_id ? ` [${entry.tool_id?.slice(0, 12)}...]` : ""}${entry.content_preview ? `: ${entry.content_preview.slice(0, 80)}` : ""}`
      );
    }
  } catch (error) {
    console.error("Error:", error);
  }

  // Analysis
  console.log("");
  console.log("=".repeat(80));
  console.log("CLIENT EVENT ANALYSIS");
  console.log("=".repeat(80));

  // Check for causality violations in client events
  let taskToolUseTime: number | null = null;
  let taskToolId: string | null = null;
  let taskToolResultTime: number | null = null;
  let bashToolUseTime: number | null = null;
  let bashToolId: string | null = null;
  let bashToolResultTime: number | null = null;

  for (const entry of clientEventLog) {
    if (entry.event_type === "tool_use" && entry.tool_name === "Task") {
      taskToolUseTime = entry.elapsed_ms;
      taskToolId = entry.tool_id || null;
      console.log(`  Task tool_use at: ${taskToolUseTime}ms [${taskToolId}]`);
    }
    if (entry.event_type === "tool_use" && entry.tool_name === "Bash") {
      bashToolUseTime = entry.elapsed_ms;
      bashToolId = entry.tool_id || null;
      console.log(`  Bash tool_use at: ${bashToolUseTime}ms [${bashToolId}]`);
    }
    if (entry.event_type === "tool_result" && entry.tool_id === taskToolId) {
      taskToolResultTime = entry.elapsed_ms;
      console.log(`  Task tool_result at: ${taskToolResultTime}ms`);
    }
    if (entry.event_type === "tool_result" && entry.tool_id === bashToolId) {
      bashToolResultTime = entry.elapsed_ms;
      console.log(`  Bash tool_result at: ${bashToolResultTime}ms`);
    }
  }

  console.log("\nCausality Check:");
  if (
    bashToolUseTime !== null &&
    bashToolResultTime !== null &&
    taskToolResultTime !== null
  ) {
    if (bashToolResultTime > taskToolResultTime) {
      console.log(
        "  WARNING: Bash tool_result arrived AFTER Task tool_result!"
      );
      console.log(
        `  This means the parent agent completed BEFORE its child's bash command finished.`
      );
      console.log("  This is a CAUSALITY VIOLATION!");
    } else {
      console.log(
        "  OK: Bash tool_result arrived before Task tool_result (correct ordering)"
      );
    }
  }

  // Write client event log
  const clientLogPath =
    "/home/ubuntu/.claude/debug-causality/client_event_log.json";
  fs.writeFileSync(clientLogPath, JSON.stringify(clientEventLog, null, 2));
  console.log(`\nClient event log written to: ${clientLogPath}`);
}

async function main(): Promise<void> {
  // Run raw CLI test first
  await runReproduction();

  // Then run ClaudeClient test
  await runClaudeClientTest();
}

main().catch(console.error);
