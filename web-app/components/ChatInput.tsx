"use client";

import { useState } from "react";
import AutosuggestInput from "./AutosuggestInput";
import type { SlashCommand } from "@/lib/types";

interface ChatInputProps {
  onSubmit: (prompt: string) => void;
  commands: SlashCommand[];
  disabled?: boolean;
  isStreaming?: boolean;
  onFocusRef?: (focusFn: () => void) => void;
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
}: ChatInputProps) {
  const [input, setInput] = useState("");

  const handleSubmit = () => {
    if (input.trim() && !disabled) {
      onSubmit(input.trim());
      setInput("");
    }
  };

  return (
    <div className="flex gap-3 p-5 border-t border-gray-700 bg-gradient-to-b from-gray-800 to-gray-900">
      <AutosuggestInput
        value={input}
        onChange={setInput}
        onSubmit={handleSubmit}
        commands={commands}
        disabled={disabled}
        isStreaming={isStreaming}
        onFocusRef={onFocusRef}
      />
    </div>
  );
}
