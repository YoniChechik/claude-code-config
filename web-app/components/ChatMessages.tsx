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
    <div className="flex-1 overflow-y-auto p-6 space-y-6 bg-gradient-to-b from-gray-50 to-white">
      {messages.map((message, index) => (
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
            {message.type === "thinking" && (
              <div className="inline-block px-2.5 py-1 mb-2 bg-purple-100 text-purple-700 text-xs font-medium rounded-lg">
                💭 Thinking
              </div>
            )}
            {message.type === "tool" && (
              <div className="inline-block px-2.5 py-1 mb-2 bg-blue-100 text-blue-700 text-xs font-medium rounded-lg">
                🔧 Tool Use
              </div>
            )}
            {message.type === "error" && (
              <div className="inline-block px-2.5 py-1 mb-2 bg-red-100 text-red-700 text-xs font-medium rounded-lg">
                ⚠️ Error
              </div>
            )}
            <div className="whitespace-pre-wrap break-words">{message.content}</div>
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
          <div className="text-sm leading-relaxed whitespace-pre-wrap break-words">
            {streamingText}
            <span className="inline-block w-0.5 h-5 ml-1 bg-blue-500 animate-pulse">▋</span>
          </div>
        </div>
      )}

      <div ref={messagesEndRef} />
    </div>
  );
}
