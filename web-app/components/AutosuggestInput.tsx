"use client";

import { useState, useEffect, useRef } from "react";
import type { SlashCommand } from "@/lib/types";
import type { MutableRefObject } from "react";
import { fuzzyMatchCommands } from "@/lib/autosuggest-client";
import StopButton from "./StopButton";

interface AutosuggestInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  commands: SlashCommand[];
  placeholder?: string;
  disabled?: boolean;
  isStreaming?: boolean;
  onFocusRef?: (focusFn: () => void) => void;
  cancelStreamRef?: MutableRefObject<(() => void) | undefined>;
}

export default function AutosuggestInput({
  value,
  onChange,
  onSubmit,
  commands,
  placeholder = "Type your message or /command...",
  disabled = false,
  isStreaming = false,
  onFocusRef,
  cancelStreamRef,
}: AutosuggestInputProps) {
  const [suggestMode, setSuggestMode] = useState(false);
  const [matches, setMatches] = useState<SlashCommand[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [isFlashing, setIsFlashing] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const selectedItemRefs = useRef<(HTMLDivElement | null)[]>([]);

  useEffect(() => {
    if (onFocusRef && inputRef.current) {
      onFocusRef(() => inputRef.current!.focus());
    }
  }, [onFocusRef]);

  useEffect(() => {
    if (inputRef.current) {
      inputRef.current.style.height = "3rem";
      const newHeight = Math.min(inputRef.current.scrollHeight, 200);
      inputRef.current.style.height = newHeight + "px";
    }
  }, [value]);

  useEffect(() => {
    if (suggestMode && selectedItemRefs.current[selectedIndex]) {
      selectedItemRefs.current[selectedIndex]!.scrollIntoView({
        behavior: "smooth",
        block: "nearest",
      });
    }
  }, [selectedIndex, suggestMode]);

  const handleChange = (newValue: string) => {
    onChange(newValue);

    const lastSlashIndex = newValue.lastIndexOf("/");
    if (lastSlashIndex >= 0) {
      const beforeSlash = newValue.substring(0, lastSlashIndex);
      if (beforeSlash === "" || beforeSlash.endsWith(" ")) {
        const pattern = newValue.substring(lastSlashIndex + 1);
        const newMatches = pattern
          ? fuzzyMatchCommands(pattern, commands)
          : commands;
        setMatches(newMatches);
        setSelectedIndex(0);
        setSuggestMode(true);
        return;
      }
    }

    setSuggestMode(false);
    setMatches([]);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "d" && e.ctrlKey) {
      e.preventDefault();
      if (isStreaming) {
        handleStop();
      }
      return;
    }

    if (suggestMode && matches.length > 0) {
      if (e.key === "Tab") {
        e.preventDefault();
        _acceptSuggestion();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((prev) => (prev + 1) % matches.length);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex(
          (prev) => (prev - 1 + matches.length) % matches.length,
        );
      } else if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        _acceptSuggestion();
        return;
      }
    }

    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (isStreaming) {
        setIsFlashing(true);
        setTimeout(() => setIsFlashing(false), 300);
      } else {
        onSubmit();
      }
    }
  };

  const _acceptSuggestion = () => {
    if (matches.length > 0) {
      const lastSlashIndex = value.lastIndexOf("/");
      const base = value.substring(0, lastSlashIndex + 1);
      onChange(base + matches[selectedIndex].name + " ");
      setSuggestMode(false);
      setMatches([]);
    }
  };

  const _getSuggestion = (): string => {
    if (!suggestMode || matches.length === 0) return "";

    const lastSlashIndex = value.lastIndexOf("/");
    const base = value.substring(0, lastSlashIndex + 1);
    return base + matches[selectedIndex].name;
  };

  const suggestion = _getSuggestion();

  const [isStopping, setIsStopping] = useState(false);

  const handleStop = () => {
    if (isStopping) return;
    if (cancelStreamRef?.current) {
      setIsStopping(true);
      cancelStreamRef.current();
    }
  };

  useEffect(() => {
    if (!isStreaming && isStopping) {
      setIsStopping(false);
    }
  }, [isStreaming, isStopping]);

  return (
    <div className="relative flex-1 flex gap-md items-end">
      <div className="relative flex-1">
        {suggestion && (
          <div
            className="absolute inset-0 px-md py-md text-text-muted pointer-events-none whitespace-pre-wrap overflow-hidden border-2 border-transparent"
            aria-hidden="true"
          >
            {suggestion}
          </div>
        )}

        <textarea
          ref={inputRef}
          value={value}
          onChange={(e) => handleChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          disabled={disabled}
          className={`w-full px-md py-md border-2 rounded-xl resize-none overflow-y-auto focus:outline-none disabled:bg-surface-tertiary bg-surface-tertiary text-text-primary transition-all duration-200 shadow-md ${
            isStreaming
              ? "border-brand-primary animate-border-spin"
              : "border-border-default focus:ring-2 focus:ring-brand-primary focus:border-brand-primary"
          } ${isFlashing ? "animate-flash-gray" : ""}`}
        />

        {suggestMode && matches.length > 0 && (
          <div
            ref={dropdownRef}
            className="absolute bottom-full left-0 right-0 mb-md bg-surface-elevated border-2 border-border-emphasis rounded-xl shadow-2xl max-h-60 overflow-y-auto z-10"
          >
            <div className="px-md py-sm text-xs text-text-secondary border-b border-border-default bg-surface-secondary font-medium">
              <span className="font-bold text-brand-primary">Tab</span> to accept •{" "}
              <span className="font-bold text-brand-primary">↑↓</span> to navigate
            </div>

            {matches.slice(0, 10).map((cmd, index) => (
              <div
                key={cmd.name}
                ref={(el) => {
                  selectedItemRefs.current[index] = el;
                }}
                className={`flex items-center justify-between px-lg py-md cursor-pointer transition-all duration-150 ${
                  index === selectedIndex
                    ? "bg-gradient-to-r from-brand-primary to-brand-secondary border-l-4 border-brand-primary shadow-md"
                    : "hover:bg-surface-elevated border-l-4 border-transparent"
                }`}
                onClick={() => {
                  setSelectedIndex(index);
                  _acceptSuggestion();
                }}
              >
                <span className="font-mono text-sm font-semibold text-text-primary">
                  /{cmd.name}
                </span>
                <span
                  className={`text-xs px-sm py-xs rounded-lg font-medium ${_getBadgeStyle(cmd.source)}`}
                >
                  {cmd.source}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

      {isStreaming && <StopButton onClick={handleStop} disabled={isStopping} />}
    </div>
  );
}

function _getBadgeStyle(source: string): string {
  switch (source) {
    case "builtin":
      return "bg-surface-elevated text-text-secondary border border-border-default";
    case "user":
      return "bg-brand-primary/20 text-text-accent border border-brand-primary";
    case "project":
      return "bg-success/20 text-success border border-success";
    default:
      return "bg-surface-elevated text-text-secondary border border-border-default";
  }
}
