"use client";

import { useEffect, useRef } from "react";
import type { Message } from "@/lib/types";

interface ChatMessagesProps {
  messages: Message[];
  streamingText?: string;
  isStreaming?: boolean;
}

/**
 * Chat messages display with streaming support
 */
export default function ChatMessages({
  messages,
  streamingText = "",
  isStreaming = false,
}: ChatMessagesProps) {
  const messagesEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new messages arrive
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, streamingText]);

  return (
    <div className="flex-1 overflow-y-auto p-4 space-y-4">
      {messages.map((message, index) => (
        <div
          key={index}
          className={`flex flex-col gap-1 p-3 rounded-lg ${
            message.role === "user"
              ? "bg-blue-100 ml-auto max-w-[80%]"
              : "bg-gray-100 mr-auto max-w-[80%]"
          }`}
        >
          <div className="text-xs font-semibold text-gray-600">
            {message.role === "user" ? "You" : "Claude"}
          </div>
          <div className="text-sm">
            {message.type === "thinking" && (
              <div className="inline-block px-2 py-1 mb-1 bg-gray-300 text-gray-700 text-xs rounded">
                Thinking
              </div>
            )}
            {message.type === "tool" && (
              <div className="inline-block px-2 py-1 mb-1 bg-blue-300 text-blue-700 text-xs rounded">
                Tool Use
              </div>
            )}
            {message.type === "error" && (
              <div className="inline-block px-2 py-1 mb-1 bg-red-300 text-red-700 text-xs rounded">
                Error
              </div>
            )}
            <div className="whitespace-pre-wrap break-words">{message.content}</div>
          </div>
          <div className="text-xs text-gray-500">
            {(typeof message.timestamp === "string"
              ? new Date(message.timestamp)
              : message.timestamp
            ).toLocaleTimeString()}
          </div>
        </div>
      ))}

      {/* Streaming message */}
      {isStreaming && (
        <div className="flex flex-col gap-1 p-3 rounded-lg bg-gray-100 mr-auto max-w-[80%]">
          <div className="text-xs font-semibold text-gray-600">Claude</div>
          <div className="text-sm whitespace-pre-wrap break-words">
            {streamingText}
            <span className="inline-block w-2 h-4 ml-1 bg-gray-600 animate-pulse">▋</span>
          </div>
        </div>
      )}

      <div ref={messagesEndRef} />
    </div>
  );
}
