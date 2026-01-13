"use client";

import { useState } from "react";
import AutosuggestInput from "./AutosuggestInput";
import type { SlashCommand } from "@/lib/types";

interface ChatInputProps {
  onSubmit: (prompt: string) => void;
  commands: SlashCommand[];
  disabled?: boolean;
}

/**
 * Chat input with autosuggest support
 */
export default function ChatInput({
  onSubmit,
  commands,
  disabled = false,
}: ChatInputProps) {
  const [input, setInput] = useState("");

  const handleSubmit = () => {
    if (input.trim() && !disabled) {
      onSubmit(input.trim());
      setInput("");
    }
  };

  return (
    <div className="flex gap-2 p-4 border-t border-gray-300 bg-white">
      <AutosuggestInput
        value={input}
        onChange={setInput}
        onSubmit={handleSubmit}
        commands={commands}
        disabled={disabled}
      />
      <button
        onClick={handleSubmit}
        disabled={disabled || !input.trim()}
        className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:bg-gray-300 disabled:cursor-not-allowed"
      >
        Send
      </button>
    </div>
  );
}
