"use client";

import { useState, useEffect, useRef } from "react";
import type { SlashCommand } from "@/lib/types";

interface AutosuggestInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  commands: SlashCommand[];
  placeholder?: string;
  disabled?: boolean;
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
}: AutosuggestInputProps) {
  const [suggestMode, setSuggestMode] = useState(false);
  const [matches, setMatches] = useState<SlashCommand[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Fuzzy match commands
  const fuzzyMatch = (pattern: string): SlashCommand[] => {
    if (!pattern) return commands;

    const patternLower = pattern.toLowerCase();
    return commands.filter((cmd) => {
      const cmdLower = cmd.name.toLowerCase();
      return cmdLower === patternLower || cmdLower.startsWith(patternLower);
    });
  };

  // Handle input change
  const handleChange = (newValue: string) => {
    onChange(newValue);

    // Check if we should enter suggest mode (after typing /)
    const lastSlashIndex = newValue.lastIndexOf("/");
    if (lastSlashIndex >= 0) {
      const beforeSlash = newValue.substring(0, lastSlashIndex);
      if (beforeSlash === "" || beforeSlash.endsWith(" ")) {
        const pattern = newValue.substring(lastSlashIndex + 1);
        const newMatches = fuzzyMatch(pattern);
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
          className="w-full px-3 py-2 border border-gray-300 rounded resize-none focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100"
        />
      </div>

      {/* Suggestion dropdown */}
      {suggestMode && matches.length > 0 && (
        <div className="absolute bottom-full left-0 right-0 mb-2 bg-white border border-gray-300 rounded shadow-lg max-h-60 overflow-y-auto z-10">
          {matches.slice(0, 10).map((cmd, index) => (
            <div
              key={cmd.name}
              className={`flex items-center justify-between px-3 py-2 cursor-pointer hover:bg-blue-50 ${
                index === selectedIndex ? "bg-blue-100" : ""
              }`}
              onClick={() => {
                setSelectedIndex(index);
                acceptSuggestion();
              }}
            >
              <span className="font-mono text-sm">/{cmd.name}</span>
              <span className="text-xs text-gray-500">{cmd.source}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
