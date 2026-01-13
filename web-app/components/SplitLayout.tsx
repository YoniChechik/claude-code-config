"use client";

import { useState, useEffect } from "react";
import ChatPane from "./ChatPane";
import type { SlashCommand } from "@/lib/types";

interface SplitLayoutProps {
  sessionIds: string[];
  commands: SlashCommand[];
  onAddSession: () => void;
  onCloseSession: (sessionId: string) => void;
}

/**
 * Dynamic split-pane layout supporting N chat sessions
 */
export default function SplitLayout({
  sessionIds,
  commands,
  onAddSession,
  onCloseSession,
}: SplitLayoutProps) {
  const [isDragging, setIsDragging] = useState(false);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [paneWidths, setPaneWidths] = useState<number[]>(
    sessionIds.map(() => 100 / sessionIds.length)
  );
  const [focusedPaneIndex, setFocusedPaneIndex] = useState(0);

  const handleMouseDown = (index: number) => {
    setIsDragging(true);
    setDragIndex(index);
  };

  const handleMouseUp = () => {
    setIsDragging(false);
    setDragIndex(null);
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    if (!isDragging || dragIndex === null) return;

    const container = e.currentTarget as HTMLElement;
    const rect = container.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const totalWidth = rect.width;

    // Calculate cumulative widths
    const cumulativeWidths = paneWidths.reduce((acc, width) => {
      const last = acc[acc.length - 1] || 0;
      acc.push(last + (width / 100) * totalWidth);
      return acc;
    }, [] as number[]);

    // Calculate new widths for the two panes being resized
    const leftPaneStart = dragIndex === 0 ? 0 : cumulativeWidths[dragIndex - 1];
    const rightPaneEnd = cumulativeWidths[dragIndex + 1];

    const newLeftWidth = ((mouseX - leftPaneStart) / totalWidth) * 100;
    const newRightWidth = ((rightPaneEnd - mouseX) / totalWidth) * 100;

    // Constrain minimum width to 10%
    if (newLeftWidth >= 10 && newRightWidth >= 10) {
      const newWidths = [...paneWidths];
      newWidths[dragIndex] = newLeftWidth;
      newWidths[dragIndex + 1] = newRightWidth;
      setPaneWidths(newWidths);
    }
  };

  // Update widths when sessions change
  if (paneWidths.length !== sessionIds.length) {
    setPaneWidths(sessionIds.map(() => 100 / sessionIds.length));
  }

  // Keep focused index in bounds
  useEffect(() => {
    if (focusedPaneIndex >= sessionIds.length) {
      setFocusedPaneIndex(Math.max(0, sessionIds.length - 1));
    }
  }, [sessionIds.length, focusedPaneIndex]);

  // Keyboard shortcuts for pane navigation
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.altKey) {
        if (e.key === "ArrowLeft") {
          e.preventDefault();
          setFocusedPaneIndex((prev) => Math.max(0, prev - 1));
        } else if (e.key === "ArrowRight") {
          e.preventDefault();
          setFocusedPaneIndex((prev) => Math.min(sessionIds.length - 1, prev + 1));
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [sessionIds.length]);

  return (
    <div
      className="flex h-full w-full relative"
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseUp}
    >
      {/* Floating + button */}
      <button
        onClick={onAddSession}
        className="absolute top-5 right-5 z-50 w-8 h-8 p-0 bg-gradient-to-br from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white rounded-full shadow-xl hover:shadow-2xl flex items-center justify-center text-xl leading-none transition-all duration-200 hover:scale-110"
        title="Add new chat"
      >
        +
      </button>

      {sessionIds.map((sessionId, index) => (
        <div key={sessionId} className="flex">
          <div
            className="h-full overflow-hidden"
            style={{ width: `${paneWidths[index]}vw` }}
          >
            <ChatPane
              sessionId={sessionId}
              commands={commands}
              onClose={() => onCloseSession(sessionId)}
              isFocused={index === focusedPaneIndex}
            />
          </div>

          {index < sessionIds.length - 1 && (
            <div
              className="flex items-center justify-center w-1.5 bg-gradient-to-b from-gray-200 via-gray-300 to-gray-200 cursor-col-resize hover:from-blue-400 hover:via-blue-500 hover:to-blue-400 active:from-blue-600 active:via-blue-700 active:to-blue-600 transition-all duration-200"
              onMouseDown={() => handleMouseDown(index)}
            >
              <div className="text-gray-500 text-xs">⋮</div>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
