"use client";

import { useState, useEffect } from "react";
import ChatPane from "./ChatPane";
import type { SlashCommand } from "@/lib/types";
import { notificationManager } from "@/lib/notification-manager";

interface SplitLayoutProps {
  sessionIds: string[];
  commands: SlashCommand[];
  onAddSession: () => void;
  onCloseSession: (sessionId: string) => void;
}

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
  const [isWindowFocused, setIsWindowFocused] = useState(!document.hidden);

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

    const cumulativeWidths = paneWidths.reduce((acc, width) => {
      const last = acc[acc.length - 1] || 0;
      acc.push(last + (width / 100) * totalWidth);
      return acc;
    }, [] as number[]);

    const leftPaneStart = dragIndex === 0 ? 0 : cumulativeWidths[dragIndex - 1];
    const rightPaneEnd = cumulativeWidths[dragIndex + 1];

    const newLeftWidth = ((mouseX - leftPaneStart) / totalWidth) * 100;
    const newRightWidth = ((rightPaneEnd - mouseX) / totalWidth) * 100;

    if (newLeftWidth >= 10 && newRightWidth >= 10) {
      const newWidths = [...paneWidths];
      newWidths[dragIndex] = newLeftWidth;
      newWidths[dragIndex + 1] = newRightWidth;
      setPaneWidths(newWidths);
    }
  };

  if (paneWidths.length !== sessionIds.length) {
    setPaneWidths(sessionIds.map(() => 100 / sessionIds.length));
  }

  useEffect(() => {
    if (focusedPaneIndex >= sessionIds.length) {
      setFocusedPaneIndex(Math.max(0, sessionIds.length - 1));
    }
  }, [sessionIds.length, focusedPaneIndex]);

  useEffect(() => {
    const handleVisibilityChange = () => {
      const isVisible = !document.hidden;
      setIsWindowFocused(isVisible);
      if (isVisible) {
        notificationManager.clearAll();
      }
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => document.removeEventListener("visibilitychange", handleVisibilityChange);
  }, []);

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

  const dividerCount = sessionIds.length - 1;
  const dividerWidthPx = dividerCount * 6;

  return (
    <div
      className="flex h-full w-full relative"
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseUp}
    >
      <button
        onClick={onAddSession}
        className="absolute top-5 right-5 z-50 w-8 h-8 p-0 bg-gradient-to-br from-brand-primary to-brand-secondary hover:from-brand-secondary hover:to-brand-primary text-text-primary rounded-full shadow-xl hover:shadow-2xl flex items-center justify-center text-xl leading-none transition-all duration-200 hover:scale-110"
        title="Add new chat"
      >
        +
      </button>

      {sessionIds.map((sessionId, index) => (
        <div key={sessionId} className="flex">
          <div
            className="h-full overflow-hidden"
            style={{ width: `calc(${paneWidths[index]}vw - ${paneWidths[index] / 100 * dividerWidthPx}px)` }}
          >
            <ChatPane
              sessionId={sessionId}
              commands={commands}
              onClose={() => onCloseSession(sessionId)}
              isFocused={index === focusedPaneIndex}
              isWindowFocused={isWindowFocused}
            />
          </div>

          {index < sessionIds.length - 1 && (
            <div
              className="flex items-center justify-center w-1.5 bg-gradient-to-b from-border-default via-border-emphasis to-border-default cursor-col-resize hover:from-brand-primary hover:via-brand-secondary hover:to-brand-primary active:from-brand-secondary active:via-brand-primary active:to-brand-secondary transition-all duration-200"
              onMouseDown={() => handleMouseDown(index)}
            >
              <div className="text-text-muted text-xs">⋮</div>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
