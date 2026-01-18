"use client";

import { useState } from "react";
import AutosuggestInput from "./AutosuggestInput";
import SessionPicker from "./SessionPicker";
import type { SlashCommand } from "@/lib/types";
import type { MutableRefObject } from "react";

interface ChatInputProps {
  onSubmit: (prompt: string) => void;
  commands: SlashCommand[];
  disabled?: boolean;
  isStreaming?: boolean;
  onFocusRef?: (focusFn: () => void) => void;
  cancelStreamRef?: MutableRefObject<(() => void) | undefined>;
  messagesCount?: number;
  onResumeSession?: (sessionId: string, filePath: string, cwd: string) => void;
}

/**
 * Chat input with autosuggest support
 */
export default function ChatInput({
  onSubmit,
  commands,
  disabled = false,
  isStreaming = false,
  onFocusRef,
  cancelStreamRef,
  messagesCount = 0,
  onResumeSession,
}: ChatInputProps) {
  const [input, setInput] = useState("");
  const [showResumePicker, setShowResumePicker] = useState(false);

  const handleSubmit = () => {
    if (input.trim() && !disabled) {
      onSubmit(input.trim());
      setInput("");
    }
  };

  const showResumeButton = messagesCount === 0 && onResumeSession;

  return (
    <>
      <SessionPicker
        isOpen={showResumePicker}
        onSelect={(sessionId, filePath, cwd) => {
          setShowResumePicker(false);
          onResumeSession?.(sessionId, filePath, cwd);
        }}
        onCancel={() => setShowResumePicker(false)}
      />
      <div className="flex flex-col gap-3 px-12 py-5 border-t border-gray-700 bg-gradient-to-b from-gray-800 to-gray-900">
        {showResumeButton && (
          <div className="flex justify-center pb-2">
            <button
              onClick={() => setShowResumePicker(true)}
              className="flex items-center gap-2 px-4 py-2 text-sm text-gray-300 hover:text-gray-100 hover:bg-gray-700/50 rounded-lg transition-all duration-200 border border-gray-700 hover:border-gray-600"
              title="Resume a previous session"
            >
              <span className="text-base">📂</span>
              <span>Resume previous session</span>
            </button>
          </div>
        )}
        <AutosuggestInput
          value={input}
          onChange={setInput}
          onSubmit={handleSubmit}
          commands={commands}
          disabled={disabled}
          isStreaming={isStreaming}
          onFocusRef={onFocusRef}
          cancelStreamRef={cancelStreamRef}
        />
      </div>
    </>
  );
}
