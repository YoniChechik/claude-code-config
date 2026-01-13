"use client";

import { useState } from "react";
import ChatPane from "./ChatPane";
import type { SlashCommand } from "@/lib/types";

interface SplitLayoutProps {
  sessionIds: string[];
  commands: SlashCommand[];
  onAddSession: () => void;
}

/**
 * Dynamic split-pane layout supporting N chat sessions
 */
export default function SplitLayout({
  sessionIds,
  commands,
  onAddSession,
}: SplitLayoutProps) {
  const [isDragging, setIsDragging] = useState(false);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [paneWidths, setPaneWidths] = useState<number[]>(
    sessionIds.map(() => 100 / sessionIds.length)
  );

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
    const totalPairWidth = rightPaneEnd - leftPaneStart;

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

  return (
    <div
      className="flex h-full w-full select-none relative"
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseUp}
    >
      {/* Floating + button */}
      <button
        onClick={onAddSession}
        className="absolute top-4 right-4 z-50 w-12 h-12 bg-blue-600 hover:bg-blue-700 text-white rounded-full shadow-lg flex items-center justify-center text-2xl font-light transition-colors"
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
            <ChatPane sessionId={sessionId} commands={commands} />
          </div>

          {index < sessionIds.length - 1 && (
            <div
              className="flex items-center justify-center w-1 bg-gray-300 cursor-col-resize hover:bg-blue-500 active:bg-blue-600"
              onMouseDown={() => handleMouseDown(index)}
            >
              <div className="text-gray-600 text-xs">⋮</div>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
