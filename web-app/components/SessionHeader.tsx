"use client";

import { formatDuration } from "@/lib/utils";

interface SessionHeaderProps {
  cwd: string;
  model: string;
  lastDurationMs: number;
}

/**
 * Session header showing cwd, model, and timing
 * Ported from ccui.sh show_prompt function (lines 75-83)
 */
export default function SessionHeader({
  cwd,
  model,
  lastDurationMs,
}: SessionHeaderProps) {
  return (
    <div className="flex items-center justify-between px-4 py-2 bg-yellow-500 text-black border-b border-gray-300">
      <div className="truncate font-mono text-sm" title={cwd}>
        {cwd}
      </div>
      {lastDurationMs > 0 && (
        <div className="flex items-center gap-2 text-sm">
          <span>{formatDuration(lastDurationMs)}</span>
          <span>│</span>
          <span>{model}</span>
        </div>
      )}
    </div>
  );
}
