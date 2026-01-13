"use client";

import { useState, useEffect, useRef } from "react";
import SessionHeader from "./SessionHeader";
import ChatMessages from "./ChatMessages";
import ChatInput from "./ChatInput";
import type { Session, Message, SlashCommand, ContentBlock } from "@/lib/types";

interface ChatPaneProps {
  sessionId: string;
  commands: SlashCommand[];
  onClose?: () => void;
  isFocused?: boolean;
}

/**
 * Individual chat pane with session management
 */
export default function ChatPane({ sessionId, commands, onClose, isFocused = false }: ChatPaneProps) {
  const [session, setSession] = useState<Session | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [streamingText, setStreamingText] = useState("");
  const [streamingBlocks, setStreamingBlocks] = useState<ContentBlock[]>([]);
  const [isStreaming, setIsStreaming] = useState(false);
  const inputFocusRef = useRef<(() => void) | undefined>(undefined);

  // Load session on mount
  useEffect(() => {
    loadSession();
  }, [sessionId]);

  // Focus input when pane becomes focused
  useEffect(() => {
    if (isFocused && inputFocusRef.current) {
      inputFocusRef.current();
    }
  }, [isFocused]);

  const loadSession = async () => {
    try {
      const response = await fetch(`/api/sessions/${sessionId}`);
      const data = await response.json();
      if (data.session) {
        setSession(data.session);
        // Convert timestamp strings back to Date objects and handle old string content
        const messagesWithDates = (data.session.messages || []).map(
          (msg: Message) => ({
            ...msg,
            timestamp: new Date(msg.timestamp),
            // Convert old string content to ContentBlock format
            content: typeof msg.content === "string"
              ? [{ type: "text" as const, text: msg.content }]
              : msg.content,
          })
        );
        setMessages(messagesWithDates);
      }
    } catch (error) {
      console.error("Failed to load session:", error);
    }
  };

  const handleSubmitInternal = async (prompt: string, isAutoContinue: boolean = false) => {
    if (!session) return;

    // Add user message (only if not auto-continue)
    if (!isAutoContinue) {
      const userMessage: Message = {
        role: "user",
        content: [{ type: "text", text: prompt }],
        timestamp: new Date(),
      };
      setMessages((prev) => [...prev, userMessage]);
    } else {
      // Add auto-continue message marked as internal
      const autoContinueMsg: Message = {
        role: "user",
        content: [{ type: "text", text: prompt }],
        timestamp: new Date(),
        isAutoContinueMessage: true,
      };
      setMessages((prev) => [...prev, autoContinueMsg]);
    }

    // Start streaming
    setIsStreaming(true);
    setStreamingText("");
    setStreamingBlocks([]);

    try {
      const response = await fetch("/api/commands", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId, prompt }),
      });

      const reader = response.body?.getReader();
      const decoder = new TextDecoder();

      if (!reader) {
        throw new Error("No response stream");
      }

      let assistantText = "";
      const assistantBlocks: ContentBlock[] = [];

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value);
        const lines = chunk.split("\n");

        for (const line of lines) {
          if (line.startsWith("data: ")) {
            const data = line.slice(6);

            if (data === "[DONE]") {
              // Stream complete
              break;
            }

            try {
              const event = JSON.parse(data);

              if (event.type === "text") {
                assistantText += event.content || "";
                setStreamingText(assistantText);
                // Add text block
                const textBlock = {
                  type: "text" as const,
                  text: event.content || "",
                };
                assistantBlocks.push(textBlock);
                setStreamingBlocks([...assistantBlocks]);
              } else if (event.type === "thinking") {
                // Add thinking block
                const thinkingBlock = {
                  type: "thinking" as const,
                  thinking: event.content || "",
                };
                assistantBlocks.push(thinkingBlock);
                setStreamingBlocks([...assistantBlocks]);
              } else if (event.type === "tool_use") {
                // Add tool use block
                const toolBlock = {
                  type: "tool_use" as const,
                  id: event.tool.id,
                  name: event.tool.name,
                  input: event.tool.input,
                };
                assistantBlocks.push(toolBlock);
                setStreamingBlocks([...assistantBlocks]);
              } else if (event.type === "tool_result") {
                // Add tool result block
                const toolResultBlock = {
                  type: "tool_result" as const,
                  tool_use_id: event.tool_result.tool_use_id,
                  content: event.tool_result.content,
                };
                assistantBlocks.push(toolResultBlock);
                setStreamingBlocks([...assistantBlocks]);
              } else if (event.type === "error") {
                console.error("Stream error:", event.error);
              }
            } catch (e) {
              // Ignore parse errors
            }
          }
        }
      }

      // Add assistant message
      if (assistantBlocks.length > 0) {
        const assistantMessage: Message = {
          role: "assistant",
          content: assistantBlocks,
          timestamp: new Date(),
        };
        setMessages((prev) => [...prev, assistantMessage]);
      }

      // Update session metadata (cwd, model, duration) from server without overwriting messages
      const sessionResponse = await fetch(`/api/sessions/${sessionId}`);
      const data = await sessionResponse.json();
      if (data.session) {
        const previousCwd = session.cwd; // Store before update

        setSession({
          ...session,
          cwd: data.session.cwd,
          model: data.session.model,
          lastDurationMs: data.session.lastDurationMs,
        });

        // Check if directory changed and trigger auto-continue
        if (data.session.previousCwd && data.session.previousCwd !== data.session.cwd && !isAutoContinue) {
          // Directory changed - trigger auto-continue
          const continuePrompt = `Now we are in ${data.session.cwd}. CONTINUE`;

          // Recursively call with auto-continue flag
          await handleSubmitInternal(continuePrompt, true);
        }
      }
    } catch (error) {
      console.error("Failed to send command:", error);
    } finally {
      setIsStreaming(false);
      setStreamingText("");
      setStreamingBlocks([]);
    }
  };

  const handleSubmit = async (prompt: string) => {
    return handleSubmitInternal(prompt, false);
  };

  if (!session) {
    return (
      <div className="flex items-center justify-center h-full bg-gray-50 text-gray-600">
        Loading session...
      </div>
    );
  }

  return (
    <div className={`relative flex flex-col h-full bg-white ${isFocused ? 'ring-2 ring-blue-500' : ''}`}>
      <SessionHeader
        cwd={session.cwd}
        model={session.model}
        lastDurationMs={session.lastDurationMs}
        onClose={onClose}
      />

      <div className="flex flex-1 overflow-hidden">
        <div className="flex flex-col flex-1">
          <ChatMessages
            messages={messages}
            streamingText={streamingText}
            streamingBlocks={streamingBlocks}
            isStreaming={isStreaming}
          />
          <ChatInput
            onSubmit={handleSubmit}
            commands={commands}
            disabled={isStreaming}
            onFocusRef={(ref) => (inputFocusRef.current = ref)}
          />
        </div>
      </div>
    </div>
  );
}
