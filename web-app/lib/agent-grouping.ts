import type { ContentBlock } from "./types";

/**
 * Represents a group of content blocks, either:
 * - An agent task with nested blocks (which can contain nested agents)
 * - A standalone block
 */
export type BlockGroup =
  | {
      type: "agent_task";
      agentType: string;
      description: string;
      taskId: string;
      taskToolUse: ContentBlock; // The Task tool_use block itself
      blocks: (ContentBlock | BlockGroup)[]; // Child blocks from tool_result.content
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
 * Checks if a block is a Task tool
 */
function isTaskTool(block: ContentBlock): boolean {
  return (
    block.type === "tool_use" &&
    block.name === "Task" &&
    block.input.subagent_type !== undefined
  );
}

/**
 * Groups content blocks by agent tasks (recursive)
 *
 * When a Task tool_use is found, we look for its matching tool_result.
 * The tool_result.content array contains the agent's child blocks.
 * Those child blocks are recursively processed to find nested agents.
 */
export function groupBlocksByAgent(blocks: ContentBlock[]): BlockGroup[] {
  // First, sort blocks to ensure tool_use appears before tool_result
  const sortedBlocks = sortToolBlocks(blocks);
  const groups: BlockGroup[] = [];
  const processedIndices = new Set<number>();

  for (let i = 0; i < sortedBlocks.length; i++) {
    if (processedIndices.has(i)) {
      continue;
    }

    const block = sortedBlocks[i];

    // Check if this is a Task tool
    if (isTaskTool(block)) {
      const taskTool = block as Extract<ContentBlock, { type: "tool_use" }>;

      // Find the matching tool_result
      let toolResultIndex = -1;
      for (let j = i + 1; j < sortedBlocks.length; j++) {
        const candidateBlock = sortedBlocks[j];
        if (
          candidateBlock.type === "tool_result" &&
          candidateBlock.tool_use_id === taskTool.id
        ) {
          toolResultIndex = j;
          break;
        }
      }

      // Extract child blocks from tool_result.content
      let childBlocks: ContentBlock[] = [];
      if (toolResultIndex !== -1) {
        const toolResult = sortedBlocks[toolResultIndex] as Extract<
          ContentBlock,
          { type: "tool_result" }
        >;

        // tool_result.content can be a string or an array of blocks
        if (Array.isArray(toolResult.content)) {
          childBlocks = toolResult.content;
        }

        // Mark tool_result as processed so we skip it
        processedIndices.add(toolResultIndex);
      }

      // Recursively group the child blocks
      const childGroups = groupBlocksByAgent(childBlocks);

      // Add agent task group
      groups.push({
        type: "agent_task",
        agentType: taskTool.input.subagent_type,
        description: taskTool.input.description || "",
        taskId: taskTool.id,
        taskToolUse: taskTool,
        blocks: childGroups,
      });

      processedIndices.add(i);
    } else {
      // Standalone block
      groups.push({
        type: "standalone",
        block,
      });
      processedIndices.add(i);
    }
  }

  return groups;
}
