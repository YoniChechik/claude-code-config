"use client";

import { useState } from "react";
import AutosuggestInput from "./AutosuggestInput";
import type { SlashCommand } from "@/lib/types";

interface ChatInputProps {
  onSubmit: (prompt: string) => void;
  commands: SlashCommand[];
  disabled?: boolean;
  onFocusRef?: (focusFn: () => void) => void;
}

/**
 * Chat input with autosuggest support
 */
export default function ChatInput({
  onSubmit,
  commands,
  disabled = false,
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
        onFocusRef={onFocusRef}
      />
      <button
        onClick={handleSubmit}
        disabled={disabled || !input.trim()}
        className="px-6 py-2.5 bg-gradient-to-r from-blue-600 to-blue-700 text-white font-medium rounded-xl hover:from-blue-700 hover:to-blue-800 disabled:from-gray-600 disabled:to-gray-700 disabled:cursor-not-allowed transition-all duration-200 shadow-md hover:shadow-lg disabled:shadow-none"
      >
        Send
      </button>
    </div>
  );
}
