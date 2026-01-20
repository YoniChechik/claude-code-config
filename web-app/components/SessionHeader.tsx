"use client";

import { useState, useEffect } from "react";
import SSHHostPromptModal from "./SSHHostPromptModal";

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
  sessionType?: "ssh" | "wsl" | "local";
  hostname?: string;
  distroName?: string;
  clientIp?: string;
  audioNotificationsEnabled?: boolean;
  onToggleAudioNotifications?: () => void;
}

/**
 * Session header showing cwd, model, and timing
 * Ported from ccui.sh show_prompt function (lines 75-83)
 */
export default function SessionHeader({
  cwd,
  model: _model,
  lastDurationMs: _lastDurationMs,
  tokenUsage,
  onClose,
  sessionType = "local",
  hostname: _hostname,
  distroName,
  clientIp,
  audioNotificationsEnabled = true,
  onToggleAudioNotifications,
}: SessionHeaderProps) {
  const [accountUsage, setAccountUsage] = useState<{
    percentUsed: number;
    resetTime: string;
  } | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [isLoadingMapping, setIsLoadingMapping] = useState(false);
  const [resolvedHostname, setResolvedHostname] = useState<string | undefined>(
    undefined,
  );

  // Generate VSCode URL based on session type
  const getVSCodeUrl = (hostnameOverride?: string): string => {
    const effectiveHostname = hostnameOverride || resolvedHostname;
    if (sessionType === "ssh" && effectiveHostname) {
      return `vscode://vscode-remote/ssh-remote+${effectiveHostname}${cwd}?windowId=_blank`;
    }
    if (sessionType === "wsl" && distroName) {
      return `vscode://vscode-remote/wsl+${distroName}${cwd}?windowId=_blank`;
    }
    return `vscode://file${cwd}?windowId=_blank`;
  };

  // Fetch SSH hostname mapping on mount
  useEffect(() => {
    if (sessionType === "ssh" && clientIp) {
      fetch(`/api/ssh-host-mapping?clientIp=${encodeURIComponent(clientIp)}`)
        .then((res) => res.json())
        .then((data) => {
          if (data.hostname) {
            setResolvedHostname(data.hostname);
          }
        })
        .catch((err) => {
          console.error("Failed to fetch SSH hostname mapping:", err);
        });
    }
  }, [sessionType, clientIp]);

  // Poll account-wide usage every 30 seconds
  useEffect(() => {
    const fetchAccountUsage = async () => {
      try {
        const response = await fetch("/api/usage");
        const data = await response.json();
        if (data.usage) {
          setAccountUsage({
            percentUsed: data.usage.percentUsed,
            resetTime: data.usage.resetTime,
          });
        }
      } catch (error) {
        console.error("Failed to fetch account usage:", error);
      }
    };

    fetchAccountUsage();
    const interval = setInterval(fetchAccountUsage, 30000); // Poll every 30s

    return () => clearInterval(interval);
  }, []);

  // Calculate percentage used for session
  const percentUsed = tokenUsage
    ? (tokenUsage.used / tokenUsage.total) * 100
    : 0;

  // Determine color based on usage
  let _tokenColor = "text-success";
  if (percentUsed > 80) _tokenColor = "text-error";
  else if (percentUsed > 60) _tokenColor = "text-warning";

  // Show high usage warning when account-wide > 70% used
  const _showHighUsageWarning = accountUsage && accountUsage.percentUsed > 70;

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

  const _timeUntilReset = getTimeUntilReset();

  // Handle CWD click
  const handleCwdClick = async (e: React.MouseEvent) => {
    e.preventDefault();

    // If not SSH, open directly
    if (sessionType !== "ssh") {
      window.open(getVSCodeUrl(), "_blank");
      return;
    }

    // If SSH but no clientIp, show error
    if (!clientIp) {
      alert("Cannot resolve SSH hostname: client IP not available");
      return;
    }

    // If already resolved, open directly
    if (resolvedHostname) {
      window.open(getVSCodeUrl(), "_blank");
      return;
    }

    // Try to fetch mapping
    setIsLoadingMapping(true);
    try {
      const response = await fetch(
        `/api/ssh-host-mapping?clientIp=${encodeURIComponent(clientIp)}`,
      );
      const data = await response.json();

      if (data.hostname) {
        setResolvedHostname(data.hostname);
        window.open(getVSCodeUrl(data.hostname), "_blank");
      } else {
        // No mapping found, show modal
        setShowModal(true);
      }
    } catch (error) {
      console.error("Failed to fetch hostname mapping:", error);
      alert("Failed to fetch hostname mapping. Please try again.");
    } finally {
      setIsLoadingMapping(false);
    }
  };

  // Handle modal save
  const handleSaveHostname = async (newHostname: string) => {
    if (!clientIp) {
      alert("Cannot save mapping: client IP not available");
      return;
    }

    try {
      const response = await fetch("/api/ssh-host-mapping", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ clientIp, hostname: newHostname }),
      });

      if (!response.ok) {
        throw new Error("Failed to save hostname mapping");
      }

      setResolvedHostname(newHostname);
      setShowModal(false);
      window.open(getVSCodeUrl(newHostname), "_blank");
    } catch (error) {
      console.error("Failed to save hostname mapping:", error);
      alert("Failed to save hostname mapping. Please try again.");
    }
  };

  return (
    <>
      <SSHHostPromptModal
        isOpen={showModal}
        clientIp={clientIp || ""}
        onSave={handleSaveHostname}
        onCancel={() => setShowModal(false)}
      />
      <div className="flex items-center justify-between px-xl py-md bg-surface-secondary text-text-primary border-b border-border-default shadow-md">
        <button
          onClick={handleCwdClick}
          disabled={isLoadingMapping}
          className="truncate font-mono text-sm font-medium hover:text-brand-primary hover:underline cursor-pointer transition-colors disabled:opacity-50 disabled:cursor-wait text-left"
          title={`Open ${cwd} in VSCode`}
        >
          {isLoadingMapping ? `${cwd} (loading...)` : cwd}
        </button>

        <div className="flex items-center gap-md">
          {onToggleAudioNotifications && (
            <button
              onClick={onToggleAudioNotifications}
              className="px-md py-sm text-xs font-medium rounded-md bg-surface-elevated hover:bg-border-emphasis transition-colors"
              title={`${audioNotificationsEnabled ? "Disable" : "Enable"} audio notifications`}
            >
              {audioNotificationsEnabled ? "🔊" : "🔇"}
            </button>
          )}
          {onClose && (
            <button
              onClick={onClose}
              className="w-6 h-6 flex items-center justify-center rounded-md hover:bg-surface-elevated transition-all duration-200 text-xl leading-none font-light"
              title="Close session"
            >
              ×
            </button>
          )}
        </div>
      </div>
    </>
  );
}
