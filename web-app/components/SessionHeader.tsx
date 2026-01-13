"use client";

import { formatDuration } from "@/lib/utils";

interface SessionHeaderProps {
  cwd: string;
  model: string;
  lastDurationMs: number;
  tokenUsage?: {
    used: number;
    total: number;
    remaining: number;
  };
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
  tokenUsage,
  onClose,
}: SessionHeaderProps) {
  // Calculate percentage used
  const percentUsed = tokenUsage ? (tokenUsage.used / tokenUsage.total) * 100 : 0;

  // Determine color based on usage
  let tokenColor = "text-green-200";
  if (percentUsed > 80) tokenColor = "text-red-300";
  else if (percentUsed > 60) tokenColor = "text-yellow-300";

  // Calculate time until 6 PM EST reset
  const getTimeUntilReset = () => {
    const now = new Date();
    const est = new Date(now.toLocaleString("en-US", { timeZone: "America/New_York" }));
    const resetTime = new Date(est);
    resetTime.setHours(18, 0, 0, 0); // 6 PM EST

    if (est.getHours() >= 18) {
      // Already past 6 PM, next reset is tomorrow
      resetTime.setDate(resetTime.getDate() + 1);
    }

    const diff = resetTime.getTime() - est.getTime();
    const hours = Math.floor(diff / (1000 * 60 * 60));
    const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));

    return { hours, minutes, totalMinutes: hours * 60 + minutes };
  };

  const { hours, minutes, totalMinutes } = getTimeUntilReset();
  const showResetWarning = percentUsed > 70 || totalMinutes < 120; // Show if >70% used OR <2h until reset

  return (
    <div className="flex items-center justify-between px-5 py-3 bg-gradient-to-r from-amber-500 to-amber-600 text-white border-b border-amber-700 shadow-sm">
      <div className="truncate font-mono text-sm font-medium" title={cwd}>
        {cwd}
      </div>
      <div className="flex items-center gap-3">
        {tokenUsage && (
          <div className={`flex items-center gap-2 text-xs font-medium bg-amber-600/30 px-3 py-1 rounded-md ${tokenColor}`} title={`Token usage: ${tokenUsage.used}/${tokenUsage.total}`}>
            <span>🪙 {tokenUsage.used.toLocaleString()}/{tokenUsage.total.toLocaleString()}</span>
            <span className="text-amber-200">({percentUsed.toFixed(0)}%)</span>
          </div>
        )}
        {showResetWarning && (
          <div className="flex items-center gap-2 text-xs font-medium bg-amber-600/30 px-3 py-1 rounded-md text-amber-100" title="Tokens reset daily at 6 PM EST">
            <span>⏰ Reset in {hours}h {minutes}m</span>
          </div>
        )}
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
