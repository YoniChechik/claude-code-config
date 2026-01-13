"use client";

import { formatDuration } from "@/lib/utils";

interface SessionHeaderProps {
  cwd: string;
  model: string;
  lastDurationMs: number;
  onClose?: () => void;
}

/**
 * Session header showing cwd, model, and timing
 * Ported from ccui.sh show_prompt function (lines 75-83)
 */
export default function SessionHeader({
  cwd,
  model,
  lastDurationMs,
  onClose,
}: SessionHeaderProps) {
  return (
    <div className="flex items-center justify-between px-5 py-3 bg-gradient-to-r from-amber-500 to-amber-600 text-white border-b border-amber-700 shadow-sm">
      <div className="truncate font-mono text-sm font-medium" title={cwd}>
        {cwd}
      </div>
      <div className="flex items-center gap-3">
        {lastDurationMs > 0 && (
          <div className="flex items-center gap-3 text-sm font-medium bg-amber-600/30 px-3 py-1 rounded-md">
            <span>{formatDuration(lastDurationMs)}</span>
            <span className="text-amber-200">│</span>
            <span>{model}</span>
          </div>
        )}
        {onClose && (
          <button
            onClick={onClose}
            className="w-6 h-6 flex items-center justify-center rounded-md hover:bg-amber-700 transition-all duration-200 text-xl leading-none font-light"
            title="Close session"
          >
            ×
          </button>
        )}
      </div>
    </div>
  );
}
