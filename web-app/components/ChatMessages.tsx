"use client";

import { useEffect, useRef } from "react";
import type { Message, ContentBlock } from "@/lib/types";
import ContentBlockRenderer from "./message/ContentBlockRenderer";
import AgentTaskFrame from "./message/AgentTaskFrame";
import { groupBlocksByAgent } from "@/lib/agent-grouping";

interface ChatMessagesProps {
  messages: Message[];
  streamingText?: string;
  streamingBlocks?: ContentBlock[];
  isStreaming?: boolean;
}

/**
 * Chat messages display with streaming support
 */
export default function ChatMessages({
  messages,
  streamingText = "",
  streamingBlocks = [],
  isStreaming = false,
}: ChatMessagesProps) {
  const messagesEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new messages arrive
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, streamingText, streamingBlocks]);

  // Filter out internal auto-continue messages
  const visibleMessages = messages.filter(
    msg => !msg.isAutoContinueMessage
  );

  return (
    <div className="flex-1 overflow-y-auto p-6 space-y-6 bg-gradient-to-b from-gray-50 to-white">
      {visibleMessages.map((message, index) => (
        <div
          key={index}
          className={`flex flex-col gap-2 p-4 rounded-2xl shadow-sm transition-all duration-200 hover:shadow-md ${
            message.role === "user"
              ? "bg-gradient-to-br from-blue-500 to-blue-600 text-white ml-auto max-w-[75%]"
              : "bg-white border border-gray-200 text-gray-800 mr-auto max-w-[85%]"
          }`}
        >
          <div className={`text-xs font-semibold ${
            message.role === "user" ? "text-blue-100" : "text-gray-500"
          }`}>
            {message.role === "user" ? "You" : "Claude"}
          </div>
          <div className="text-sm leading-relaxed">
            <div className="whitespace-pre-wrap break-words">
              {console.log("[CHAT-MESSAGES] Processing", message.role, "message with", message.content.length, "blocks:", message.content.map(b => b.type === "tool_use" ? `${b.type}(${b.name})` : b.type))}
              {groupBlocksByAgent(message.content).map((group, groupIdx) => {
                if (group.type === "agent_task") {
                  return (
                    <AgentTaskFrame
                      key={groupIdx}
                      agentType={group.agentType}
                      description={group.description}
                      taskId={group.taskId}
                      taskToolUse={group.taskToolUse}
                      childBlocks={group.blocks}
                    />
                  );
                }
                return <ContentBlockRenderer key={groupIdx} block={group.block} />;
              })}
            </div>
          </div>
          <div className={`text-xs ${
            message.role === "user" ? "text-blue-200" : "text-gray-400"
          }`}>
            {(typeof message.timestamp === "string"
              ? new Date(message.timestamp)
              : message.timestamp
            ).toLocaleTimeString()}
          </div>
        </div>
      ))}

      {/* Streaming message */}
      {isStreaming && (
        <div className="flex flex-col gap-2 p-4 rounded-2xl shadow-sm bg-white border border-gray-200 text-gray-800 mr-auto max-w-[85%]">
          <div className="text-xs font-semibold text-gray-500">Claude</div>
          <div className="text-sm leading-relaxed">
            <div className="whitespace-pre-wrap break-words">
              {groupBlocksByAgent(streamingBlocks).map((group, groupIdx) => {
                if (group.type === "agent_task") {
                  return (
                    <AgentTaskFrame
                      key={groupIdx}
                      agentType={group.agentType}
                      description={group.description}
                      taskId={group.taskId}
                      taskToolUse={group.taskToolUse}
                      childBlocks={group.blocks}
                    />
                  );
                }

                // Add cursor after last text block during streaming
                const isLastGroup = groupIdx === groupBlocksByAgent(streamingBlocks).length - 1;
                const isTextBlock = group.block.type === "text";
                return (
                  <span key={groupIdx}>
                    <ContentBlockRenderer block={group.block} />
                    {isStreaming && isLastGroup && isTextBlock && (
                      <span className="inline-block w-0.5 h-5 ml-1 bg-blue-500 animate-pulse">▋</span>
                    )}
                  </span>
                );
              })}
            </div>
          </div>
        </div>
      )}

      <div ref={messagesEndRef} />
    </div>
  );
}
