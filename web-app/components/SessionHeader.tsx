"use client";

import { useState, useEffect } from "react";
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
  const [accountUsage, setAccountUsage] = useState<{ percentUsed: number; resetTime: string } | null>(null);

  // Poll account-wide usage every 30 seconds
  useEffect(() => {
    const fetchAccountUsage = async () => {
      try {
        const response = await fetch('/api/usage');
        const data = await response.json();
        if (data.usage) {
          setAccountUsage({
            percentUsed: data.usage.percentUsed,
            resetTime: data.usage.resetTime,
          });
        }
      } catch (error) {
        console.error('Failed to fetch account usage:', error);
      }
    };

    fetchAccountUsage();
    const interval = setInterval(fetchAccountUsage, 30000); // Poll every 30s

    return () => clearInterval(interval);
  }, []);

  // Calculate percentage used for session
  const percentUsed = tokenUsage ? (tokenUsage.used / tokenUsage.total) * 100 : 0;

  // Determine color based on usage
  let tokenColor = "text-green-200";
  if (percentUsed > 80) tokenColor = "text-red-300";
  else if (percentUsed > 60) tokenColor = "text-yellow-300";

  // Show high usage warning when account-wide > 70% used
  const showHighUsageWarning = accountUsage && accountUsage.percentUsed > 70;

  // Calculate time until reset
  const getTimeUntilReset = () => {
    if (!accountUsage) return null;
    const now = new Date();
    const reset = new Date(accountUsage.resetTime);
    const diff = reset.getTime() - now.getTime();
    if (diff < 0) return null;

    const hours = Math.floor(diff / (1000 * 60 * 60));
    const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
    return { hours, minutes };
  };

  const timeUntilReset = getTimeUntilReset();

  return (
    <div className="flex items-center justify-between px-5 py-3 bg-gradient-to-r from-amber-500 to-amber-600 text-white border-b border-amber-700 shadow-sm">
      <div className="truncate font-mono text-sm font-medium" title={cwd}>
        {cwd}
      </div>
      <div className="flex items-center gap-3">
        {tokenUsage && (
          <div className={`flex items-center gap-2 text-xs font-medium bg-amber-600/30 px-3 py-1 rounded-md ${tokenColor}`} title={`Token usage: ${tokenUsage.used}/${tokenUsage.total} (resets every 5 hours)`}>
            <span>🪙 {tokenUsage.used.toLocaleString()}/{tokenUsage.total.toLocaleString()}</span>
            <span className="text-amber-200">({percentUsed.toFixed(0)}%)</span>
          </div>
        )}
        {showHighUsageWarning && timeUntilReset && (
          <div className="flex items-center gap-2 text-xs font-medium bg-red-600/40 px-3 py-1 rounded-md text-red-100" title={`Account usage at ${accountUsage?.percentUsed.toFixed(0)}% - resets at 6 PM EST`}>
            <span>⚠️ Resets in {timeUntilReset.hours}h {timeUntilReset.minutes}m</span>
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
