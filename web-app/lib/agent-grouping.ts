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
 * Groups content blocks by agent tasks
 *
 * When a Task tool_use is found, all subsequent blocks until the next Task
 * or end of array are grouped as children of that agent task.
 */
export function groupBlocksByAgent(blocks: ContentBlock[]): BlockGroup[] {
  const groups: BlockGroup[] = [];
  let i = 0;

  while (i < blocks.length) {
    const block = blocks[i];

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
      while (i < blocks.length) {
        const nextBlock = blocks[i];

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
