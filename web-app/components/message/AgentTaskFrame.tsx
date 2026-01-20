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

export default function AgentTaskFrame({
  agentType,
  description,
  taskId: _taskId,
  taskToolUse,
  childBlocks,
}: AgentTaskFrameProps) {
  return (
    <div className="my-md border-2 border-purple-700 rounded-lg overflow-hidden bg-purple-950/20">
      {/* Agent Header */}
      <div className="bg-purple-900/40 border-b-2 border-purple-700 px-md py-sm flex items-center gap-md">
        <span className="text-lg">🤖</span>
        <div className="flex-1">
          <span className="font-semibold text-purple-300">{agentType}</span>
          {description && (
            <span className="text-purple-400 ml-2">· {description}</span>
          )}
        </div>
        <div className="w-2 h-2 bg-purple-500 rounded-full animate-pulse" title="Running" />
      </div>

      <div className="px-md py-md space-y-sm">
        <div className="ml-sm">
          <ToolUseCard tool={taskToolUse} />
        </div>

        {childBlocks.map((item, index) => {
          if ("type" in item && item.type === "agent_task") {
            const agentItem = item as Extract<typeof item, { type: "agent_task" }>;
            return (
              <div key={index} className="ml-sm">
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
          if ("type" in item && item.type === "standalone") {
            const standaloneItem = item as Extract<typeof item, { type: "standalone" }>;
            return (
              <div key={index} className="ml-sm">
                <ContentBlockRenderer block={standaloneItem.block} isNested />
              </div>
            );
          }
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
