import type { ContentBlock } from "./types";

// Public types
export type BlockGroup =
  | {
      type: "agent_task";
      agentType: string;
      description: string;
      taskId: string;
      taskToolUse: ContentBlock;
      blocks: (ContentBlock | BlockGroup)[];
    }
  | {
      type: "standalone";
      block: ContentBlock;
    };

// Public functions
export function groupBlocksByAgent(blocks: ContentBlock[]): BlockGroup[] {
  const filteredBlocks = _filterTodoWriteBlocks(blocks);
  const sortedBlocks = _sortToolBlocks(filteredBlocks);
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

// Private functions

function _filterTodoWriteBlocks(blocks: ContentBlock[]): ContentBlock[] {
  const todoWriteIds = new Set<string>();
  for (const block of blocks) {
    if (block.type === "tool_use" && block.name === "TodoWrite") {
      todoWriteIds.add(block.id);
    }
  }

  return blocks.filter((block) => {
    if (block.type === "tool_use" && block.name === "TodoWrite") {
      return false;
    }
    if (block.type === "tool_result" && todoWriteIds.has(block.tool_use_id)) {
      return false;
    }
    return true;
  });
}

function _isTaskTool(block: ContentBlock): boolean {
  return (
    block.type === "tool_use" &&
    block.name === "Task" &&
    block.input.subagent_type !== undefined
  );
}

function _sortToolBlocks(blocks: ContentBlock[]): ContentBlock[] {
  const toolUseMap = new Map<string, ContentBlock>();
  const toolResultMap = new Map<string, ContentBlock>();
  const taskToolIds = new Set<string>();

  for (const block of blocks) {
    if (block.type === "tool_use") {
      toolUseMap.set(block.id, block);
      if (_isTaskTool(block)) {
        taskToolIds.add(block.id);
      }
    } else if (block.type === "tool_result") {
      toolResultMap.set(block.tool_use_id, block);
    }
  }

  const sorted: ContentBlock[] = [];
  const processedToolUseIds = new Set<string>();

  for (const block of blocks) {
    if (block.type === "tool_use") {
      if (processedToolUseIds.has(block.id)) continue;

      sorted.push(block);
      processedToolUseIds.add(block.id);

      if (!taskToolIds.has(block.id)) {
        const toolResult = toolResultMap.get(block.id);
        if (toolResult) {
          sorted.push(toolResult);
        }
      }
    } else if (block.type === "tool_result") {
      if (
        processedToolUseIds.has(block.tool_use_id) &&
        !taskToolIds.has(block.tool_use_id)
      ) {
        continue;
      }

      sorted.push(block);
    } else {
      sorted.push(block);
    }
  }

  return sorted;
}

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

function _extractChildBlocks(
  taskToolIndex: number,
  toolResultIndex: number,
  blocks: ContentBlock[],
  processedIndices: Set<number>
): ContentBlock[] {
  const childBlocks: ContentBlock[] = [];

  const streamingBlocks = blocks.slice(taskToolIndex + 1, toolResultIndex);
  childBlocks.push(...streamingBlocks);

  for (let k = taskToolIndex + 1; k < toolResultIndex; k++) {
    processedIndices.add(k);
  }

  const toolResult = blocks[toolResultIndex] as Extract<
    ContentBlock,
    { type: "tool_result" }
  >;
  if (Array.isArray(toolResult.content)) {
    childBlocks.push(...toolResult.content);
  }

  processedIndices.add(toolResultIndex);
  return childBlocks;
}

function _processAgentTask(
  block: ContentBlock,
  blockIndex: number,
  blocks: ContentBlock[],
  groups: BlockGroup[],
  processedIndices: Set<number>
): void {
  const taskTool = block as Extract<ContentBlock, { type: "tool_use" }>;

  const toolResultIndex = _findToolResultIndex(taskTool, blockIndex, blocks);

  let childBlocks: ContentBlock[] = [];
  if (toolResultIndex !== -1) {
    childBlocks = _extractChildBlocks(
      blockIndex,
      toolResultIndex,
      blocks,
      processedIndices
    );
  }

  const childGroups = groupBlocksByAgent(childBlocks);

  const input = taskTool.input as Record<string, unknown>;
  groups.push({
    type: "agent_task",
    agentType: input.subagent_type ? String(input.subagent_type) : "(unnamed)",
    description: input.description ? String(input.description) : "",
    taskId: taskTool.id,
    taskToolUse: taskTool,
    blocks: childGroups as BlockGroup[],
  });

  processedIndices.add(blockIndex);
}
