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
  isStreaming?: boolean;
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
  isStreaming = false,
  onFocusRef,
}: AutosuggestInputProps) {
  const [suggestMode, setSuggestMode] = useState(false);
  const [matches, setMatches] = useState<SlashCommand[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [isFlashing, setIsFlashing] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const selectedItemRefs = useRef<(HTMLDivElement | null)[]>([]);

  // Expose focus function to parent
  useEffect(() => {
    if (onFocusRef && inputRef.current) {
      onFocusRef(() => inputRef.current?.focus());
    }
  }, [onFocusRef]);

  // Auto-resize textarea based on content
  useEffect(() => {
    if (inputRef.current) {
      inputRef.current.style.height = '3rem'; // Reset to single line height (increased from 1.5rem)
      const newHeight = Math.min(inputRef.current.scrollHeight, 200);
      inputRef.current.style.height = newHeight + 'px';
    }
  }, [value]);

  // Scroll selected item into view
  useEffect(() => {
    if (suggestMode && selectedItemRefs.current[selectedIndex]) {
      selectedItemRefs.current[selectedIndex]?.scrollIntoView({
        behavior: "smooth",
        block: "nearest",
      });
    }
  }, [selectedIndex, suggestMode]);

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
      // If streaming, trigger flash animation instead of submitting
      if (isStreaming) {
        setIsFlashing(true);
        setTimeout(() => setIsFlashing(false), 300);
      } else {
        onSubmit();
      }
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
            className="absolute inset-0 px-4 py-3 text-gray-600 pointer-events-none whitespace-pre-wrap overflow-hidden"
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
          className={`w-full px-4 py-3 border-2 rounded-xl resize-none overflow-y-auto focus:outline-none disabled:bg-gray-800 bg-gray-800 text-gray-100 transition-all duration-200 shadow-sm ${
            isStreaming
              ? 'border-blue-500 animate-border-spin'
              : 'border-gray-700 focus:ring-2 focus:ring-blue-500 focus:border-blue-500'
          } ${isFlashing ? 'animate-flash-gray' : ''}`}
        />
      </div>

      {/* Suggestion dropdown */}
      {suggestMode && matches.length > 0 && (
        <div ref={dropdownRef} className="absolute bottom-full left-0 right-0 mb-3 bg-gray-800 border-2 border-gray-700 rounded-xl shadow-2xl max-h-60 overflow-y-auto z-10">
          {/* Keyboard hint */}
          <div className="px-4 py-2.5 text-xs text-gray-300 border-b border-gray-700 bg-gradient-to-r from-gray-800 to-gray-900 font-medium">
            <span className="font-bold text-blue-400">Tab</span> to accept • <span className="font-bold text-blue-400">↑↓</span> to navigate
          </div>

          {matches.slice(0, 10).map((cmd, index) => {
            // Color-coded badges based on source
            const getBadgeStyle = () => {
              switch (cmd.source) {
                case "builtin":
                  return "bg-gray-700 text-gray-300 border border-gray-600";
                case "user":
                  return "bg-blue-900 text-blue-300 border border-blue-700";
                case "project":
                  return "bg-green-900 text-green-300 border border-green-700";
                default:
                  return "bg-gray-700 text-gray-300 border border-gray-600";
              }
            };

            return (
              <div
                key={cmd.name}
                ref={(el) => {
                  selectedItemRefs.current[index] = el;
                }}
                className={`flex items-center justify-between px-5 py-3 cursor-pointer transition-all duration-150 ${
                  index === selectedIndex
                    ? "bg-gradient-to-r from-blue-900 to-blue-800 border-l-4 border-blue-500 shadow-sm"
                    : "hover:bg-gray-700 border-l-4 border-transparent"
                }`}
                onClick={() => {
                  setSelectedIndex(index);
                  acceptSuggestion();
                }}
              >
                <span className="font-mono text-sm font-semibold text-gray-100">/{cmd.name}</span>
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
