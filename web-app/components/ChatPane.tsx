"use client";

import { useState, useEffect, useRef } from "react";
import SessionHeader from "./SessionHeader";
import ChatMessages from "./ChatMessages";
import ChatInput from "./ChatInput";
import type { Session, Message, SlashCommand, ContentBlock } from "@/lib/types";
import type { ClaudeStreamEvent } from "@/lib/claude-client";
import {
  playAudioNotification,
  updateTabTitle,
  clearTabNotification,
} from "@/lib/notifications";
import { getOrCreateWindowId } from "@/lib/window-id";

interface ChatPaneProps {
  sessionId: string;
  commands: SlashCommand[];
  onClose?: () => void;
  isFocused?: boolean;
}

/**
 * Individual chat pane with session management
 */
export default function ChatPane({
  sessionId,
  commands,
  onClose,
  isFocused = false,
}: ChatPaneProps) {
  const [session, setSession] = useState<Session | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [streamingText, setStreamingText] = useState("");
  const [streamingBlocks, setStreamingBlocks] = useState<ContentBlock[]>([]);
  const [isStreaming, setIsStreaming] = useState(false);
  const [tokenUsage, setTokenUsage] = useState<
    { used: number; total: number; remaining: number } | undefined
  >(undefined);
  const inputFocusRef = useRef<(() => void) | undefined>(undefined);
  const abortControllerRef = useRef<AbortController | null>(null);
  const cancelStreamRef = useRef<(() => void) | undefined>(undefined);
  const [isWindowFocused, setIsWindowFocused] = useState(true);

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

  // Track window/tab focus state using Page Visibility API
  useEffect(() => {
    const handleVisibilityChange = () => {
      const isVisible = !document.hidden;
      setIsWindowFocused(isVisible);
      if (isVisible) {
        clearTabNotification();
      }
    };

    // Set initial state
    setIsWindowFocused(!document.hidden);

    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, []);

  const loadSession = async () => {
    const windowId = getOrCreateWindowId();
    const response = await fetch(`/api/sessions/${sessionId}`, {
      headers: {
        "x-window-id": windowId,
      },
    });
    const data = await response.json();
    setSession(data.session);
    // Convert timestamp strings back to Date objects and handle old string content
    const messagesWithDates = data.session.messages.map((msg: Message) => ({
      ...msg,
      timestamp: new Date(msg.timestamp),
      // Convert old string content to ContentBlock format
      content:
        typeof msg.content === "string"
          ? [{ type: "text" as const, text: msg.content }]
          : msg.content,
    }));
    setMessages(messagesWithDates);
  };

  const handleSubmitInternal = async (
    prompt: string,
    isAutoContinue: boolean = false,
  ) => {
    if (!session) return;

    _addUserMessage(prompt, isAutoContinue);

    setIsStreaming(true);
    setStreamingText("");
    setStreamingBlocks([]);

    abortControllerRef.current = new AbortController();
    cancelStreamRef.current = () => {
      if (!abortControllerRef.current) return;

      abortControllerRef.current.abort();
      abortControllerRef.current = null;
      cancelStreamRef.current = undefined;

      setIsStreaming(false);
      setStreamingText("");
      setStreamingBlocks([]);
    };

    try {
      const windowId = getOrCreateWindowId();

      const response = await fetch("/api/commands", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId, windowId, prompt }),
        signal: abortControllerRef.current.signal,
      });

      let assistantText = "";
      let assistantBlocks: ContentBlock[] = [];

      const streamResult = await _handleStreamEvents(
        response,
        assistantText,
        assistantBlocks,
      );
      assistantText = streamResult.text;
      assistantBlocks = streamResult.blocks;

      // Clear streaming state BEFORE adding final message to prevent flash
      setIsStreaming(false);
      setStreamingText("");
      setStreamingBlocks([]);

      const assistantMessage: Message = {
        role: "assistant",
        content: assistantBlocks,
        timestamp: new Date(),
      };
      setMessages((prev) => [...prev, assistantMessage]);

      await _updateSessionMetadata();

      abortControllerRef.current = null;
      cancelStreamRef.current = undefined;

      // Trigger notifications
      if (session?.audioNotificationsEnabled) {
        playAudioNotification();
      }
      if (!isWindowFocused) {
        updateTabTitle("Done");
      }
    } catch (error: unknown) {
      if ((error as Error).name === "AbortError") {
        return;
      }
      throw error;
    }
  };

  const handleSubmit = async (prompt: string) => {
    return handleSubmitInternal(prompt, false);
  };

  const toggleAudioNotifications = async () => {
    if (!session) return;

    const newValue = !session.audioNotificationsEnabled;
    setSession({ ...session, audioNotificationsEnabled: newValue });

    const windowId = getOrCreateWindowId();

    // Persist to backend
    await fetch(`/api/sessions/${sessionId}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "x-window-id": windowId,
      },
      body: JSON.stringify({ audioNotificationsEnabled: newValue }),
    });
  };


  const handleResumeSession = async (
    resumeSessionId: string,
    filePath: string,
    cwd: string,
  ) => {
    const windowId = getOrCreateWindowId();

    const response = await fetch("/api/sessions/resume", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sessionId: resumeSessionId,
        windowId,
        filePath,
        cwd,
      }),
    });

    if (!response.ok) {
      console.error("Failed to resume session");
      return;
    }

    await loadSession();
  };

  // PRIVATE HELPERS

  const _addUserMessage = (prompt: string, isAutoContinue: boolean): void => {
    if (isAutoContinue) {
      const autoContinueMsg: Message = {
        role: "user",
        content: [{ type: "text", text: prompt }],
        timestamp: new Date(),
        isAutoContinueMessage: true,
      };
      setMessages((prev) => [...prev, autoContinueMsg]);
    } else {
      const userMessage: Message = {
        role: "user",
        content: [{ type: "text", text: prompt }],
        timestamp: new Date(),
      };
      setMessages((prev) => [...prev, userMessage]);
    }
  };

  const _processStreamEvent = (
    event: ClaudeStreamEvent,
    assistantText: string,
    assistantBlocks: ContentBlock[],
  ): { text: string; blocks: ContentBlock[] } => {
    if (event.type === "text") {
      assistantText += event.content || "";
      const lastBlock = assistantBlocks[assistantBlocks.length - 1];
      if (lastBlock && lastBlock.type === "text") {
        lastBlock.text += event.content || "";
      } else {
        assistantBlocks.push({
          type: "text" as const,
          text: event.content || "",
        });
      }
      return { text: assistantText, blocks: assistantBlocks };
    }

    if (event.type === "thinking") {
      assistantBlocks.push({
        type: "thinking" as const,
        thinking: event.content || "",
      });
      return { text: assistantText, blocks: assistantBlocks };
    }

    if (event.type === "tool_use" && event.tool) {
      assistantBlocks.push({
        type: "tool_use" as const,
        id: event.tool.id,
        name: event.tool.name,
        input: event.tool.input,
        timestamp: event.tool.timestamp ? new Date(event.tool.timestamp) : undefined,
        // No result yet - pending state
      });
      return { text: assistantText, blocks: assistantBlocks };
    }

    if (event.type === "tool_result" && event.tool_result) {
      // Find the matching tool_use block and update it with the result
      const toolUseBlock = assistantBlocks.find(
        (block) =>
          block.type === "tool_use" && block.id === event.tool_result!.tool_use_id
      );

      if (toolUseBlock && toolUseBlock.type === "tool_use") {
        // Update the tool_use block with the result
        toolUseBlock.result = event.tool_result.content;
      } else {
        // Fallback: if tool_use not found, add as separate block (shouldn't happen)
        assistantBlocks.push({
          type: "tool_result" as const,
          tool_use_id: event.tool_result.tool_use_id,
          content: event.tool_result.content,
        });
      }
      return { text: assistantText, blocks: assistantBlocks };
    }

    return { text: assistantText, blocks: assistantBlocks };
  };

  const _handleStreamEvents = async (
    response: Response,
    assistantText: string,
    assistantBlocks: ContentBlock[],
  ): Promise<{ text: string; blocks: ContentBlock[] }> => {
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const chunk = decoder.decode(value);
      buffer += chunk;
      const lines = buffer.split("\n");

      // Keep the last incomplete line in the buffer
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;

        const data = line.slice(6);
        if (data === "[DONE]") break;

        try {
          const event = JSON.parse(data);

          if (
            event.type === "text" ||
            event.type === "thinking" ||
            event.type === "tool_use" ||
            event.type === "tool_result"
          ) {
            const result = _processStreamEvent(
              event,
              assistantText,
              assistantBlocks,
            );
            assistantText = result.text;
            assistantBlocks.splice(0, assistantBlocks.length, ...result.blocks);
            setStreamingText(assistantText);
            setStreamingBlocks([...assistantBlocks]);
          } else if (event.type === "cwd_changed") {
            setSession((prev) => (prev ? { ...prev, cwd: event.cwd } : null));
          } else if (event.type === "token_usage") {
            setTokenUsage(event.token_usage);
          } else if (event.type === "error") {
            console.error("Stream error:", event.error);
          }
        } catch (e) {
          console.error("Failed to parse SSE event:", data, e);
        }
      }
    }

    return { text: assistantText, blocks: assistantBlocks };
  };

  const _updateSessionMetadata = async (): Promise<void> => {
    const windowId = getOrCreateWindowId();
    const sessionResponse = await fetch(`/api/sessions/${sessionId}`, {
      headers: {
        "x-window-id": windowId,
      },
    });
    const data = await sessionResponse.json();
    setSession((prev) =>
      prev
        ? {
            ...prev,
            cwd: data.session.cwd,
            model: data.session.model,
            lastDurationMs: data.session.lastDurationMs,
          }
        : null,
    );
  };

  if (!session) {
    return (
      <div className="flex items-center justify-center h-full bg-gray-900 text-gray-400">
        Loading session...
      </div>
    );
  }

  return (
    <div
      className={`relative flex flex-col h-full bg-gray-900 ${isFocused ? "ring-2 ring-blue-500" : ""}`}
    >
      <SessionHeader
        cwd={session.cwd}
        model={session.model}
        lastDurationMs={session.lastDurationMs}
        tokenUsage={tokenUsage}
        onClose={onClose}
        sessionType={session.sessionType}
        hostname={session.hostname}
        distroName={session.distroName}
        clientIp={session.clientIp}
        audioNotificationsEnabled={session.audioNotificationsEnabled}
        onToggleAudioNotifications={toggleAudioNotifications}
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
            disabled={false}
            isStreaming={isStreaming}
            onFocusRef={(ref) => (inputFocusRef.current = ref)}
            cancelStreamRef={cancelStreamRef}
            messagesCount={messages.length}
            onResumeSession={handleResumeSession}
          />
        </div>
      </div>
    </div>
  );
}
