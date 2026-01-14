"use client";

import { useState, useEffect, useRef } from "react";

interface SessionMetadata {
  id: string;
  cwd: string;
  createdAt: string;
  lastActivityAt: string;
  messageCount: number;
  lastMessagePreview: string;
  filePath: string;
  isSymlinked?: boolean;
  originalCwd?: string;
}

interface SessionPickerProps {
  isOpen: boolean;
  onSelect: (sessionId: string, filePath: string, cwd: string) => void;
  onCancel: () => void;
}

export default function SessionPicker({
  isOpen,
  onSelect,
  onCancel,
}: SessionPickerProps) {
  const [sessions, setSessions] = useState<SessionMetadata[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const modalRef = useRef<HTMLDivElement>(null);
  const selectedItemRefs = useRef<(HTMLDivElement | null)[]>([]);

  useEffect(() => {
    if (isOpen) {
      _loadSessions();
    }
  }, [isOpen]);

  useEffect(() => {
    if (!isOpen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.min(prev + 1, sessions.length - 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex((prev) => Math.max(prev - 1, 0));
      } else if (e.key === "Enter" && sessions.length > 0) {
        e.preventDefault();
        const session = sessions[selectedIndex];
        onSelect(session.id, session.filePath, session.cwd);
      } else if (e.key === "Escape") {
        e.preventDefault();
        onCancel();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isOpen, sessions, selectedIndex, onSelect, onCancel]);

  useEffect(() => {
    if (selectedItemRefs.current[selectedIndex]) {
      selectedItemRefs.current[selectedIndex]!.scrollIntoView({
        behavior: "smooth",
        block: "nearest",
      });
    }
  }, [selectedIndex]);

  const _loadSessions = async () => {
    setLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/sessions/recent?limit=20");

      if (!response.ok) {
        throw new Error(`Failed to load sessions: ${response.statusText}`);
      }

      const data = await response.json();
      setSessions(data.sessions);
      setSelectedIndex(0);
    } catch (err) {
      console.error("Error loading sessions:", err);
      setError(err instanceof Error ? err.message : "Failed to load sessions");
      setSessions([]);
    } finally {
      setLoading(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black bg-opacity-50"
      onClick={onCancel}
      data-testid="session-picker-backdrop"
    >
      <div
        ref={modalRef}
        className="bg-gray-800 border-2 border-gray-700 rounded-xl shadow-2xl w-full max-w-3xl max-h-[80vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
        data-testid="session-picker-modal"
      >
        {/* Header */}
        <div className="px-6 py-4 border-b border-gray-700 bg-gradient-to-r from-gray-800 to-gray-900">
          <h2
            className="text-xl font-bold text-gray-100"
            data-testid="session-picker-header"
          >
            Resume Session
          </h2>
          <p className="text-sm text-gray-400 mt-1">
            <span className="font-bold text-blue-400">↑↓</span> to navigate •{" "}
            <span className="font-bold text-blue-400">Enter</span> to select •{" "}
            <span className="font-bold text-blue-400">Esc</span> to cancel
          </p>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto">
          {loading && (
            <div className="flex items-center justify-center py-12">
              <div className="text-gray-400">Loading sessions...</div>
            </div>
          )}

          {error && (
            <div className="flex items-center justify-center py-12">
              <div className="text-red-400">{error}</div>
            </div>
          )}

          {!loading && !error && sessions.length === 0 && (
            <div className="flex flex-col items-center justify-center py-12 px-6 text-center">
              <div className="text-gray-400 text-lg mb-2">
                No previous sessions found
              </div>
              <div className="text-gray-500 text-sm">
                Start a new conversation to create your first session
              </div>
            </div>
          )}

          {!loading && !error && sessions.length > 0 && (
            <div className="divide-y divide-gray-700">
              {sessions.map((session, index) => (
                <div
                  key={`${session.id}-${index}`}
                  ref={(el) => {
                    selectedItemRefs.current[index] = el;
                  }}
                  className={`px-6 py-4 cursor-pointer transition-all duration-150 ${
                    index === selectedIndex
                      ? "bg-gradient-to-r from-blue-900 to-blue-800 border-l-4 border-blue-500"
                      : "hover:bg-gray-700 border-l-4 border-transparent"
                  }`}
                  onClick={() =>
                    onSelect(session.id, session.filePath, session.cwd)
                  }
                  data-testid="session-item"
                  data-session-id={session.id}
                  data-selected={index === selectedIndex}
                >
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-3 mb-2">
                        <span className="font-mono text-sm font-semibold text-blue-400 truncate">
                          {session.cwd}
                        </span>
                        {session.isSymlinked && session.originalCwd && (
                          <span className="text-xs px-2 py-0.5 bg-purple-900 text-purple-200 rounded-full flex-shrink-0">
                            from another directory
                          </span>
                        )}
                        <span className="text-xs text-gray-400 flex-shrink-0">
                          {_formatRelativeTime(session.lastActivityAt)}
                        </span>
                      </div>
                      {session.isSymlinked && session.originalCwd && (
                        <div className="text-xs text-purple-300 mb-1">
                          Originally created in: {session.originalCwd}
                        </div>
                      )}
                      <div className="text-sm text-gray-300 mb-1">
                        {session.messageCount} messages
                      </div>
                      {session.lastMessagePreview && (
                        <div className="text-sm text-gray-400 italic truncate">
                          "{session.lastMessagePreview}"
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-3 border-t border-gray-700 bg-gray-900 flex justify-end">
          <button
            onClick={onCancel}
            className="px-4 py-2 text-sm text-gray-300 hover:text-gray-100 hover:bg-gray-700 rounded-lg transition-colors"
            data-testid="cancel-button"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

function _formatRelativeTime(timestamp: string): string {
  const diff = Date.now() - new Date(timestamp).getTime();
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(hours / 24);

  if (hours < 1) return "< 1h ago";
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;
  return `${Math.floor(days / 7)}w ago`;
}
