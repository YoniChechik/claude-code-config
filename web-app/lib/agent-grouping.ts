import type { ContentBlock } from "./types";

// EXPORTS: Public types and functions

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
 * Groups content blocks by agent tasks (recursive)
 *
 * When a Task tool_use is found, we look for its matching tool_result.
 * The tool_result.content array contains the agent's child blocks.
 * Those child blocks are recursively processed to find nested agents.
 */
export function groupBlocksByAgent(blocks: ContentBlock[]): BlockGroup[] {
  const sortedBlocks = _sortToolBlocks(blocks);
  const groups: BlockGroup[] = [];
  const processedIndices = new Set<number>();

  for (let i = 0; i < sortedBlocks.length; i++) {
    if (processedIndices.has(i)) continue;

    const block = sortedBlocks[i];

    if (_isTaskTool(block)) {
      _processAgentTask(block, i, sortedBlocks, groups, processedIndices);
    } else {
      groups.push({
        type: "standalone",
        block,
      });
      processedIndices.add(i);
    }
  }

  return groups;
}

// PRIVATE HELPERS

/**
 * Checks if a block is a Task tool
 */
function _isTaskTool(block: ContentBlock): boolean {
  return (
    block.type === "tool_use" &&
    block.name === "Task" &&
    block.input.subagent_type !== undefined
  );
}

/**
 * Sorts content blocks to ensure tool_use blocks appear before their matching tool_result blocks.
 * This fixes the issue where tool inputs and outputs appear in scrambled order.
 */
function _sortToolBlocks(blocks: ContentBlock[]): ContentBlock[] {
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

  for (const block of blocks) {
    if (block.type === "tool_use") {
      if (processedToolUseIds.has(block.id)) continue;

      sorted.push(block);
      processedToolUseIds.add(block.id);

      // Add matching tool_result immediately after if it exists
      const toolResult = toolResultMap.get(block.id);
      if (toolResult) {
        sorted.push(toolResult);
      }
    } else if (block.type === "tool_result") {
      // Skip if already added with its tool_use
      if (processedToolUseIds.has(block.tool_use_id)) continue;

      // Orphaned tool_result (tool_use not found) - add it anyway
      sorted.push(block);
    } else {
      sorted.push(block);
    }
  }

  return sorted;
}

/**
 * Find the matching tool_result for a Task tool_use
 */
function _findToolResultIndex(
  taskTool: Extract<ContentBlock, { type: "tool_use" }>,
  startIdx: number,
  blocks: ContentBlock[]
): number {
  for (let j = startIdx + 1; j < blocks.length; j++) {
    const block = blocks[j];
    if (block.type === "tool_result" && block.tool_use_id === taskTool.id) {
      return j;
    }
  }
  return -1;
}

/**
 * Extract child blocks from tool_result and streaming blocks
 */
function _extractChildBlocks(
  taskToolIndex: number,
  toolResultIndex: number,
  blocks: ContentBlock[],
  processedIndices: Set<number>
): ContentBlock[] {
  const childBlocks: ContentBlock[] = [];

  // Collect all blocks between tool_use and tool_result (streaming agent work)
  const streamingBlocks = blocks.slice(taskToolIndex + 1, toolResultIndex);
  childBlocks.push(...streamingBlocks);

  // Mark all streaming blocks as processed
  for (let k = taskToolIndex + 1; k < toolResultIndex; k++) {
    processedIndices.add(k);
  }

  // Extract blocks from tool_result.content (if any)
  const toolResult = blocks[toolResultIndex] as Extract<
    ContentBlock,
    { type: "tool_result" }
  >;
  if (Array.isArray(toolResult.content)) {
    childBlocks.push(...toolResult.content);
  }

  // Mark tool_result as processed
  processedIndices.add(toolResultIndex);

  return childBlocks;
}

/**
 * Process an agent task and add it to groups
 */
function _processAgentTask(
  block: ContentBlock,
  blockIndex: number,
  blocks: ContentBlock[],
  groups: BlockGroup[],
  processedIndices: Set<number>
): void {
  const taskTool = block as Extract<ContentBlock, { type: "tool_use" }>;

  // Find the matching tool_result
  const toolResultIndex = _findToolResultIndex(taskTool, blockIndex, blocks);

  // Extract child blocks
  let childBlocks: ContentBlock[] = [];
  if (toolResultIndex !== -1) {
    childBlocks = _extractChildBlocks(
      blockIndex,
      toolResultIndex,
      blocks,
      processedIndices
    );
  }

  // Recursively group the child blocks
  const childGroups = groupBlocksByAgent(childBlocks);

  // Add agent task group
  const input = taskTool.input as Record<string, unknown>;
  groups.push({
    type: "agent_task",
    agentType: String(input.subagent_type),
    description: String(input.description || ""),
    taskId: taskTool.id,
    taskToolUse: taskTool,
    blocks: childGroups as BlockGroup[],
  });

  processedIndices.add(blockIndex);
}
