"use client";

import { ContentBlock } from "@/lib/types";
import { BlockGroup } from "@/lib/agent-grouping";
import ContentBlockRenderer from "./ContentBlockRenderer";
import ToolUseCard from "./ToolUseCard";

interface AgentTaskFrameProps {
  agentType: string;
  description: string;
  taskId: string;
  taskToolUse: Extract<ContentBlock, { type: "tool_use" }>;
  childBlocks: (ContentBlock | BlockGroup)[];
}

/**
 * Visual frame for agent task execution
 * Shows agent header with type/description and wraps all agent's tool invocations
 */
export default function AgentTaskFrame({
  agentType,
  description,
  taskId: _taskId,
  taskToolUse,
  childBlocks,
}: AgentTaskFrameProps) {
  return (
    <div className="my-3 border-2 border-purple-700 rounded-lg overflow-hidden bg-purple-950/20">
      {/* Agent Header */}
      <div className="bg-purple-900/40 border-b-2 border-purple-700 px-4 py-2 flex items-center gap-2">
        <span className="text-lg">🤖</span>
        <div className="flex-1">
          <span className="font-semibold text-purple-300">{agentType}</span>
          <span className="text-purple-400 ml-2">· {description}</span>
        </div>
        <div className="w-2 h-2 bg-purple-500 rounded-full animate-pulse" title="Running" />
      </div>

      {/* Agent Content - nested tool invocations and nested agents */}
      <div className="px-4 py-3 space-y-2">
        {/* Display the Task tool invocation that spawned this agent */}
        <div className="ml-2">
          <ToolUseCard tool={taskToolUse} />
        </div>

        {childBlocks.map((item, index) => {
          // Handle nested agent task groups recursively
          if ("type" in item && item.type === "agent_task") {
            const agentItem = item as Extract<typeof item, { type: "agent_task" }>;
            return (
              <div key={index} className="ml-2">
                <AgentTaskFrame
                  agentType={agentItem.agentType}
                  description={agentItem.description}
                  taskId={agentItem.taskId}
                  taskToolUse={agentItem.taskToolUse as Extract<ContentBlock, { type: "tool_use" }>}
                  childBlocks={agentItem.blocks}
                />
              </div>
            );
          }
          // Handle standalone block groups
          if ("type" in item && item.type === "standalone") {
            const standaloneItem = item as Extract<typeof item, { type: "standalone" }>;
            return (
              <div key={index} className="ml-2">
                <ContentBlockRenderer block={standaloneItem.block} isNested />
              </div>
            );
          }
          // Handle raw content blocks
          return (
            <div key={index} className="ml-2">
              <ContentBlockRenderer block={item as ContentBlock} isNested />
            </div>
          );
        })}
      </div>
    </div>
  );
}
