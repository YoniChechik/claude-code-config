"use client";

import { ContentBlock } from "@/lib/types";
import { BlockGroup } from "@/lib/agent-grouping";
import ContentBlockRenderer from "./ContentBlockRenderer";
import ToolUseCard from "./ToolUseCard";

interface AgentTaskFrameProps {
  agentType: string;
  description: string;
  taskId: string;
  taskToolUse: ContentBlock;
  childBlocks: BlockGroup[];
}

/**
 * Visual frame for agent task execution
 * Shows agent header with type/description and wraps all agent's tool invocations
 */
export default function AgentTaskFrame({
  agentType,
  description,
  taskId,
  taskToolUse,
  childBlocks,
}: AgentTaskFrameProps) {
  return (
    <div className="my-3 border-2 border-purple-300 rounded-lg overflow-hidden bg-purple-50/30">
      {/* Agent Header */}
      <div className="bg-purple-100 border-b-2 border-purple-300 px-4 py-2 flex items-center gap-2">
        <span className="text-lg">🤖</span>
        <div className="flex-1">
          <span className="font-semibold text-purple-900">{agentType}</span>
          {description && (
            <span className="text-purple-700 ml-2">· {description}</span>
          )}
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
          if (item.type === "agent_task") {
            return (
              <div key={index} className="ml-2">
                <AgentTaskFrame
                  agentType={item.agentType}
                  description={item.description}
                  taskId={item.taskId}
                  taskToolUse={item.taskToolUse}
                  childBlocks={item.blocks}
                />
              </div>
            );
          }
          // Handle standalone block groups
          if (item.type === "standalone") {
            return (
              <div key={index} className="ml-2">
                <ContentBlockRenderer block={item.block} isNested />
              </div>
            );
          }
        })}
      </div>
    </div>
  );
}
