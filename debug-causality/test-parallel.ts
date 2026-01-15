#!/usr/bin/env tsx
/**
 * Test if parallel tool calls from CLI arrive in scrambled order
 */

import { spawn } from "child_process";

function log(msg: string) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function testParallelTools() {
  log("START: Testing parallel tool calls ordering");

  const args = [
    "-p",
    "Use Glob to find these files in parallel: **/*.md, **/*.json, **/*.ts. Make all 3 glob calls in a single message.",
    "--output-format",
    "stream-json",
    "--verbose"
  ];

  const claude = spawn("/home/ubuntu/.local/bin/claude", args, {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: "/home/ubuntu/.claude",
  });

  claude.stdin.end();

  const events: Array<{ts: string, type: string, id: string, name?: string}> = [];

  claude.stdout.on("data", (chunk: Buffer) => {
    const lines = chunk.toString().split("\n");

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const event = JSON.parse(line);
        const ts = new Date().toISOString();

        if (event.type === "assistant" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_use") {
              events.push({ts, type: "tool_use", id: block.id, name: block.name});
              log(`tool_use: ${block.name} [${block.id.slice(0,12)}]`);
            }
          }
        }

        if (event.type === "user" && event.message?.content) {
          for (const block of event.message.content) {
            if (block.type === "tool_result") {
              events.push({ts, type: "tool_result", id: block.tool_use_id});
              log(`tool_result: [${block.tool_use_id.slice(0,12)}]`);
            }
          }
        }
      } catch (e) {}
    }
  });

  await new Promise<void>((resolve) => {
    claude.on("close", () => {
      log("CLOSE");
      resolve();
    });
  });

  log("\n=== ANALYSIS ===");
  log(`Total events: ${events.length}`);

  // Check if we have proper pairing
  const toolUses = events.filter(e => e.type === "tool_use");
  log(`\nTool uses: ${toolUses.length}`);

  let violations = 0;
  for (const toolUse of toolUses) {
    const useIdx = events.findIndex(e => e.type === "tool_use" && e.id === toolUse.id);
    const resultIdx = events.findIndex(e => e.type === "tool_result" && e.id === toolUse.id);

    if (resultIdx === -1) {
      log(`⚠️  No result for ${toolUse.name} [${toolUse.id.slice(0,12)}]`);
      continue;
    }

    // Check if anything comes between tool_use and its result
    const between = events.slice(useIdx + 1, resultIdx);
    if (between.length > 0) {
      log(`❌ VIOLATION: ${between.length} events between ${toolUse.name} tool_use and result:`);
      between.forEach(e => {
        log(`   - ${e.type} [${e.id.slice(0,12)}]`);
      });
      violations++;
    } else {
      log(`✅ ${toolUse.name}: tool_use immediately followed by result`);
    }
  }

  if (violations > 0) {
    log(`\n❌ Found ${violations} ordering violations - buffering IS needed`);
  } else {
    log(`\n✅ All tool calls properly ordered - buffering NOT needed`);
  }
}

testParallelTools().catch(err => {
  console.error("Failed:", err);
  process.exit(1);
});
