"use client";

import { useEffect, useRef, useState } from "react";
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
  const containerRef = useRef<HTMLDivElement>(null);
  const shouldAutoScrollRef = useRef(true);

  // Check if we're at the bottom before content updates
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const handleScroll = () => {
      const { scrollTop, scrollHeight, clientHeight } = container;
      const distanceFromBottom = scrollHeight - scrollTop - clientHeight;

      // Update auto-scroll based on current position (synchronous via ref)
      // If we're near bottom, enable auto-scroll. Otherwise disable it.
      shouldAutoScrollRef.current = distanceFromBottom <= 100;
    };

    container.addEventListener("scroll", handleScroll, { passive: true });
    return () => container.removeEventListener("scroll", handleScroll);
  }, []);

  // Auto-scroll to bottom only if shouldAutoScroll is true
  useEffect(() => {
    // Use requestAnimationFrame to check flag after DOM updates and scroll events
    let rafId: number;
    const timeoutId = setTimeout(() => {
      rafId = requestAnimationFrame(() => {
        if (shouldAutoScrollRef.current) {
          messagesEndRef.current?.scrollIntoView({ behavior: "auto" });
        }
      });
    }, 0);

    return () => {
      clearTimeout(timeoutId);
      if (rafId !== undefined) {
        cancelAnimationFrame(rafId);
      }
    };
  }, [messages, streamingText, streamingBlocks]);

  // Filter out internal auto-continue messages
  const visibleMessages = messages.filter((msg) => !msg.isAutoContinueMessage);

  return (
    <div
      ref={containerRef}
      className="flex-1 overflow-y-auto p-6 pl-12 pr-12 space-y-6 bg-gradient-to-b from-gray-900 to-gray-900"
    >
      {visibleMessages.length === 0 && !isStreaming && (
        <div className="flex items-center justify-center h-full">
          <p className="text-2xl text-gray-500">Write something special...</p>
        </div>
      )}
      {visibleMessages.map((message, index) => (
        <div
          key={index}
          className={`flex flex-col gap-2 p-4 pl-12 rounded-2xl shadow-sm transition-all duration-200 hover:shadow-md ${
            message.role === "user"
              ? "bg-gradient-to-br from-blue-800 to-blue-900 text-gray-100 ml-auto max-w-[85%]"
              : "bg-gray-800 border border-gray-700 text-gray-100 mr-auto max-w-[85%]"
          }`}
        >
          <div
            className={`flex items-center gap-2 text-xs font-semibold ${
              message.role === "user" ? "text-blue-200" : "text-gray-400"
            }`}
          >
            <span>{message.role === "user" ? "You" : "Claude"}</span>
            <span className="text-xs font-normal opacity-70">
              {(typeof message.timestamp === "string"
                ? new Date(message.timestamp)
                : message.timestamp
              ).toLocaleTimeString("en-US", {
                hour12: false,
                hour: "2-digit",
                minute: "2-digit",
                second: "2-digit",
              })}
            </span>
          </div>
          <div className="text-sm leading-relaxed">
            <div className="whitespace-pre-wrap break-words">
              {groupBlocksByAgent(message.content).map((group, groupIdx) => {
                if (group.type === "agent_task") {
                  return (
                    <AgentTaskFrame
                      key={groupIdx}
                      agentType={group.agentType}
                      description={group.description}
                      taskId={group.taskId}
                      taskToolUse={
                        group.taskToolUse as Extract<
                          ContentBlock,
                          { type: "tool_use" }
                        >
                      }
                      childBlocks={group.blocks}
                    />
                  );
                }
                if (group.type === "standalone") {
                  return (
                    <ContentBlockRenderer key={groupIdx} block={group.block} />
                  );
                }
              })}
            </div>
          </div>
        </div>
      ))}

      {/* Streaming message */}
      {isStreaming && (
        <div className="flex flex-col gap-2 p-4 pl-12 rounded-2xl shadow-sm bg-gray-800 border-2 text-gray-100 mr-auto max-w-[85%] animate-border-spin">
          <div className="text-xs font-semibold text-gray-400">Claude</div>
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
                      taskToolUse={
                        group.taskToolUse as Extract<
                          ContentBlock,
                          { type: "tool_use" }
                        >
                      }
                      childBlocks={group.blocks}
                    />
                  );
                }

                // Add cursor after last text block during streaming
                const isLastGroup =
                  groupIdx === groupBlocksByAgent(streamingBlocks).length - 1;
                const isTextBlock = group.block.type === "text";
                return (
                  <span key={groupIdx}>
                    <ContentBlockRenderer block={group.block} />
                    {isStreaming && isLastGroup && isTextBlock && (
                      <span className="inline-block w-0.5 h-5 ml-1 bg-blue-500 animate-pulse">
                        ▋
                      </span>
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
