"use client";

import { useState } from "react";
import ChatPane from "./ChatPane";
import type { SlashCommand } from "@/lib/types";

interface SplitLayoutProps {
  leftSessionId: string;
  rightSessionId: string;
  commands: SlashCommand[];
}

/**
 * Split-pane layout with two independent chat sessions
 */
export default function SplitLayout({
  leftSessionId,
  rightSessionId,
  commands,
}: SplitLayoutProps) {
  const [splitRatio, setSplitRatio] = useState(50);
  const [isDragging, setIsDragging] = useState(false);

  const handleMouseDown = () => {
    setIsDragging(true);
  };

  const handleMouseUp = () => {
    setIsDragging(false);
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    if (!isDragging) return;

    const container = e.currentTarget as HTMLElement;
    const rect = container.getBoundingClientRect();
    const ratio = ((e.clientX - rect.left) / rect.width) * 100;

    // Constrain ratio between 20% and 80%
    setSplitRatio(Math.max(20, Math.min(80, ratio)));
  };

  return (
    <div
      className="flex h-full w-full select-none"
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseUp}
    >
      <div className="h-full overflow-hidden" style={{ width: `${splitRatio}%` }}>
        <ChatPane sessionId={leftSessionId} commands={commands} />
      </div>

      <div
        className="flex items-center justify-center w-1 bg-gray-300 cursor-col-resize hover:bg-blue-500 active:bg-blue-600"
        onMouseDown={handleMouseDown}
      >
        <div className="text-gray-600 text-xs">⋮</div>
      </div>

      <div className="h-full overflow-hidden" style={{ width: `${100 - splitRatio}%` }}>
        <ChatPane sessionId={rightSessionId} commands={commands} />
      </div>
    </div>
  );
}
