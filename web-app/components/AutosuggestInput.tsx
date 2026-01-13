"use client";

import { useState, useEffect, useRef } from "react";
import type { SlashCommand } from "@/lib/types";
import { fuzzyMatchCommands } from "@/lib/autosuggest-client";

interface AutosuggestInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  commands: SlashCommand[];
  placeholder?: string;
  disabled?: boolean;
  onFocusRef?: (focusFn: () => void) => void;
}

/**
 * Input with slash command autosuggest (ported from autosuggest.sh)
 */
export default function AutosuggestInput({
  value,
  onChange,
  onSubmit,
  commands,
  placeholder = "Type your message or /command...",
  disabled = false,
  onFocusRef,
}: AutosuggestInputProps) {
  const [suggestMode, setSuggestMode] = useState(false);
  const [matches, setMatches] = useState<SlashCommand[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Expose focus function to parent
  useEffect(() => {
    if (onFocusRef && inputRef.current) {
      onFocusRef(() => inputRef.current?.focus());
    }
  }, [onFocusRef]);

  // Handle input change
  const handleChange = (newValue: string) => {
    onChange(newValue);

    // Check if we should enter suggest mode (after typing /)
    const lastSlashIndex = newValue.lastIndexOf("/");
    if (lastSlashIndex >= 0) {
      const beforeSlash = newValue.substring(0, lastSlashIndex);
      if (beforeSlash === "" || beforeSlash.endsWith(" ")) {
        const pattern = newValue.substring(lastSlashIndex + 1);
        // Use shared fuzzyMatchCommands function for consistent matching
        const newMatches = pattern ? fuzzyMatchCommands(pattern, commands) : commands;
        setMatches(newMatches);
        setSelectedIndex(0);
        setSuggestMode(true);
        return;
      }
    }

    setSuggestMode(false);
    setMatches([]);
  };

  // Handle key down
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (suggestMode && matches.length > 0) {
      if (e.key === "Tab") {
        e.preventDefault();
        acceptSuggestion();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((prev) => (prev + 1) % matches.length);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex((prev) => (prev - 1 + matches.length) % matches.length);
      } else if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        acceptSuggestion();
        return;
      }
    }

    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      onSubmit();
    }
  };

  // Accept suggestion
  const acceptSuggestion = () => {
    if (matches.length > 0) {
      const lastSlashIndex = value.lastIndexOf("/");
      const base = value.substring(0, lastSlashIndex + 1);
      onChange(base + matches[selectedIndex].name + " ");
      setSuggestMode(false);
      setMatches([]);
    }
  };

  // Get current suggestion text
  const getSuggestion = (): string => {
    if (!suggestMode || matches.length === 0) return "";

    const lastSlashIndex = value.lastIndexOf("/");
    const base = value.substring(0, lastSlashIndex + 1);
    return base + matches[selectedIndex].name;
  };

  const suggestion = getSuggestion();

  return (
    <div className="relative flex-1">
      <div className="relative">
        {/* Ghost text showing suggestion */}
        {suggestion && (
          <div
            className="absolute inset-0 px-3 py-2 text-gray-400 pointer-events-none whitespace-pre-wrap"
            aria-hidden="true"
          >
            {suggestion}
          </div>
        )}

        {/* Actual input */}
        <textarea
          ref={inputRef}
          value={value}
          onChange={(e) => handleChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          disabled={disabled}
          rows={1}
          className="w-full px-4 py-3 border-2 border-gray-300 rounded-xl resize-none focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 transition-all duration-200 shadow-sm"
        />
      </div>

      {/* Suggestion dropdown */}
      {suggestMode && matches.length > 0 && (
        <div className="absolute bottom-full left-0 right-0 mb-3 bg-white border-2 border-gray-200 rounded-xl shadow-2xl max-h-60 overflow-y-auto z-10">
          {/* Keyboard hint */}
          <div className="px-4 py-2.5 text-xs text-gray-600 border-b border-gray-100 bg-gradient-to-r from-gray-50 to-gray-100 font-medium">
            <span className="font-bold text-blue-600">Tab</span> to accept • <span className="font-bold text-blue-600">↑↓</span> to navigate
          </div>

          {matches.slice(0, 10).map((cmd, index) => {
            // Color-coded badges based on source
            const getBadgeStyle = () => {
              switch (cmd.source) {
                case "builtin":
                  return "bg-gray-100 text-gray-700 border border-gray-300";
                case "user":
                  return "bg-blue-100 text-blue-700 border border-blue-300";
                case "project":
                  return "bg-green-100 text-green-700 border border-green-300";
                default:
                  return "bg-gray-100 text-gray-700 border border-gray-300";
              }
            };

            return (
              <div
                key={cmd.name}
                className={`flex items-center justify-between px-5 py-3 cursor-pointer transition-all duration-150 ${
                  index === selectedIndex
                    ? "bg-gradient-to-r from-blue-50 to-blue-100 border-l-4 border-blue-500 shadow-sm"
                    : "hover:bg-gray-50 border-l-4 border-transparent"
                }`}
                onClick={() => {
                  setSelectedIndex(index);
                  acceptSuggestion();
                }}
              >
                <span className="font-mono text-sm font-semibold text-gray-800">/{cmd.name}</span>
                <span className={`text-xs px-2.5 py-1 rounded-lg font-medium ${getBadgeStyle()}`}>
                  {cmd.source}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
