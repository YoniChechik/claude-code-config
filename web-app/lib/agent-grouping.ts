import type { ContentBlock } from "./types";

/**
 * Represents a group of content blocks, either:
 * - An agent task with nested blocks
 * - A standalone block
 */
export type BlockGroup =
  | {
      type: "agent_task";
      agentType: string;
      description: string;
      taskId: string;
      blocks: ContentBlock[];
    }
  | {
      type: "standalone";
      block: ContentBlock;
    };

/**
 * Sorts content blocks to ensure tool_use blocks appear before their matching tool_result blocks.
 * This fixes the issue where tool inputs and outputs appear in scrambled order.
 */
function sortToolBlocks(blocks: ContentBlock[]): ContentBlock[] {
  // Build a map of tool_use_id -> tool_use block for quick lookup
  const toolUseMap = new Map<string, ContentBlock>();
  const toolResultMap = new Map<string, ContentBlock>();
  const otherBlocks: ContentBlock[] = [];

  // Separate blocks by type
  for (const block of blocks) {
    if (block.type === "tool_use") {
      toolUseMap.set(block.id, block);
    } else if (block.type === "tool_result") {
      toolResultMap.set(block.tool_use_id, block);
    } else {
      otherBlocks.push(block);
    }
  }

  // Reconstruct the array with proper ordering
  const sorted: ContentBlock[] = [];
  const processedToolUseIds = new Set<string>();

  // First pass: maintain relative order but pair tool_use with tool_result
  for (const block of blocks) {
    if (block.type === "tool_use") {
      if (!processedToolUseIds.has(block.id)) {
        sorted.push(block);
        processedToolUseIds.add(block.id);

        // Add matching tool_result immediately after if it exists
        const toolResult = toolResultMap.get(block.id);
        if (toolResult) {
          sorted.push(toolResult);
        }
      }
    } else if (block.type === "tool_result") {
      // Skip if already added with its tool_use
      if (processedToolUseIds.has(block.tool_use_id)) {
        continue;
      }
      // Orphaned tool_result (tool_use not found) - add it anyway
      sorted.push(block);
    } else {
      sorted.push(block);
    }
  }

  return sorted;
}

/**
 * Groups content blocks by agent tasks
 *
 * When a Task tool_use is found, all subsequent blocks until the next Task
 * or end of array are grouped as children of that agent task.
 */
export function groupBlocksByAgent(blocks: ContentBlock[]): BlockGroup[] {
  // First, sort blocks to ensure tool_use appears before tool_result
  const sortedBlocks = sortToolBlocks(blocks);
  const groups: BlockGroup[] = [];
  let i = 0;

  while (i < sortedBlocks.length) {
    const block = sortedBlocks[i];

    // Check if this is a Task tool
    if (
      block.type === "tool_use" &&
      block.name === "Task" &&
      block.input.subagent_type
    ) {
      // Start agent task group
      const agentBlocks: ContentBlock[] = [];
      i++; // Move past the Task tool itself

      // Collect blocks until next Task or end
      while (i < sortedBlocks.length) {
        const nextBlock = sortedBlocks[i];

        // Stop if we hit another Task tool
        if (
          nextBlock.type === "tool_use" &&
          nextBlock.name === "Task" &&
          nextBlock.input.subagent_type
        ) {
          break;
        }

        agentBlocks.push(nextBlock);
        i++;
      }

      // Add agent task group
      groups.push({
        type: "agent_task",
        agentType: block.input.subagent_type,
        description: block.input.description || "",
        taskId: block.id,
        blocks: agentBlocks,
      });
    } else {
      // Standalone block
      groups.push({
        type: "standalone",
        block,
      });
      i++;
    }
  }

  return groups;
}
