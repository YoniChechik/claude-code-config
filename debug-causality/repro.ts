#!/usr/bin/env tsx
/**
 * Reproduction script for causality bug
 *
 * Bug: Agent reports completion BEFORE bash command finishes
 * Expected: bash result should come BEFORE agent completion
 */

import { spawn } from "child_process";

function timestamp(): string {
  const now = new Date();
  return now.toISOString();
}

function log(msg: string, data?: any) {
  const ts = timestamp();
  if (data) {
    console.log(`[${ts}] ${msg}:`, JSON.stringify(data, null, 2));
  } else {
    console.log(`[${ts}] ${msg}`);
  }
}

async function reproduceIssue() {
  log("START: Spawning claude CLI with subagent that sleeps 10 seconds");

  const args = [
    "-p",
    "open subagent, sleep 10 and print done",
    "--output-format",
    "stream-json",
    "--verbose"
  ];

  const claude = spawn("/home/ubuntu/.local/bin/claude", args, {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: process.cwd(),
  });

  claude.stdin.end();

  const events: Array<{timestamp: string, type: string, data: any}> = [];

  claude.stdout.on("data", (chunk: Buffer) => {
    const chunkStr = chunk.toString();
    const lines = chunkStr.split("\n");

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const event = JSON.parse(line);
        const ts = timestamp();

        // Log important events
        if (event.type === "assistant" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_use" && block.name === "Task") {
              events.push({timestamp: ts, type: "TASK_TOOL_USE", data: block});
              log("EVENT: Task tool_use", {id: block.id, description: block.input?.description});
            }
            if (block.type === "tool_use" && block.name === "Bash") {
              events.push({timestamp: ts, type: "BASH_TOOL_USE", data: block});
              log("EVENT: Bash tool_use (inside agent)", {id: block.id, command: block.input?.command});
            }
          }
        }

        if (event.type === "user" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_result") {
              events.push({timestamp: ts, type: "TOOL_RESULT", data: block});

              const content = typeof block.content === "string" ? block.content : JSON.stringify(block.content);
              const preview = content.substring(0, 100);
              log("EVENT: tool_result", {tool_use_id: block.tool_use_id, preview});

              // Check if this contains "agentId" (agent completion)
              if (content.includes("agentId:")) {
                log("🔴 AGENT COMPLETION (reports done)", {tool_use_id: block.tool_use_id});
              }

              // Check if this contains "done" from bash
              if (content.includes("done") && content.includes("echo")) {
                log("🟢 BASH OUTPUT (actual completion)", {tool_use_id: block.tool_use_id});
              }
            }
          }
        }

        if (event.type === "result") {
          events.push({timestamp: ts, type: "FINAL_RESULT", data: event});
          log("EVENT: Final result");
        }
      } catch (e) {
        // Skip non-JSON lines
      }
    }
  });

  claude.stderr.on("data", (chunk: Buffer) => {
    log("STDERR:", chunk.toString());
  });

  await new Promise<void>((resolve, reject) => {
    claude.on("close", (code) => {
      log(`CLOSE: claude exited with code ${code}`);
      resolve();
    });

    claude.on("error", (err) => {
      log("ERROR:", err);
      reject(err);
    });
  });

  log("\n=== ANALYSIS ===");
  log(`Total events captured: ${events.length}`);

  // Find the Task tool and its result
  const taskTool = events.find(e => e.type === "TASK_TOOL_USE");
  const taskResult = events.findIndex(e =>
    e.type === "TOOL_RESULT" &&
    e.data.tool_use_id === taskTool?.data.id
  );

  // Find bash tool inside agent and its result
  const bashTool = events.find(e => e.type === "BASH_TOOL_USE");
  const bashResult = events.findIndex(e =>
    e.type === "TOOL_RESULT" &&
    e.data.tool_use_id === bashTool?.data.id
  );

  log("\nEvent order:");
  if (taskTool) log(`1. Task tool_use at index: ${events.indexOf(taskTool)}`);
  if (bashTool) log(`2. Bash tool_use at index: ${events.indexOf(bashTool)}`);
  if (bashResult >= 0) log(`3. Bash tool_result at index: ${bashResult}`);
  if (taskResult >= 0) log(`4. Task tool_result at index: ${taskResult}`);

  if (taskResult >= 0 && bashResult >= 0) {
    if (taskResult < bashResult) {
      log("\n❌ BUG CONFIRMED: Agent completion came BEFORE bash output");
      log(`   Task result index: ${taskResult}`);
      log(`   Bash result index: ${bashResult}`);
      log(`   This violates causality - child work should complete before parent reports done`);
    } else {
      log("\n✅ Correct: Bash output came before agent completion");
    }
  }
}

reproduceIssue().catch(err => {
  console.error("Failed:", err);
  process.exit(1);
});
