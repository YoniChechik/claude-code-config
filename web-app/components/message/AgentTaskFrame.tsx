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
    <div className="my-md border-2 border-brand-secondary rounded-lg overflow-hidden bg-brand-secondary/10">
      {/* Agent Header */}
      <div className="bg-brand-secondary/20 border-b-2 border-brand-secondary px-md py-sm flex items-center gap-md">
        <span className="text-lg">🤖</span>
        <div className="flex-1">
          <span className="font-semibold text-text-accent">{agentType}</span>
          <span className="text-brand-primary ml-2">· {description}</span>
        </div>
        <div
          className="w-2 h-2 bg-brand-primary rounded-full animate-pulse"
          title="Running"
        />
      </div>

      {/* Agent Content - nested tool invocations and nested agents */}
      <div className="px-md py-md space-y-sm">
        {/* Display the Task tool invocation that spawned this agent */}
        <div className="ml-sm">
          <ToolUseCard tool={taskToolUse} />
        </div>

        {childBlocks.map((item, index) => {
          // Handle nested agent task groups recursively
          if ("type" in item && item.type === "agent_task") {
            const agentItem = item as Extract<
              typeof item,
              { type: "agent_task" }
            >;
            return (
              <div key={index} className="ml-sm">
                <AgentTaskFrame
                  agentType={agentItem.agentType}
                  description={agentItem.description}
                  taskId={agentItem.taskId}
                  taskToolUse={
                    agentItem.taskToolUse as Extract<
                      ContentBlock,
                      { type: "tool_use" }
                    >
                  }
                  childBlocks={agentItem.blocks}
                />
              </div>
            );
          }
          // Handle standalone block groups
          if ("type" in item && item.type === "standalone") {
            const standaloneItem = item as Extract<
              typeof item,
              { type: "standalone" }
            >;
            return (
              <div key={index} className="ml-sm">
                <ContentBlockRenderer block={standaloneItem.block} isNested />
              </div>
            );
          }
          // Handle raw content blocks
          return (
            <div key={index} className="ml-sm">
              <ContentBlockRenderer block={item as ContentBlock} isNested />
            </div>
          );
        })}
      </div>
    </div>
  );
}
