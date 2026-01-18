"use client";

import { useState, useEffect } from "react";
import { formatDuration } from "@/lib/utils";
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
  model,
  lastDurationMs,
  tokenUsage,
  onClose,
  sessionType = "local",
  hostname,
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
  let tokenColor = "text-green-400";
  if (percentUsed > 80) tokenColor = "text-red-400";
  else if (percentUsed > 60) tokenColor = "text-yellow-400";

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
      <div className="flex items-center justify-between px-12 py-3 bg-gradient-to-r from-gray-800 to-gray-900 text-gray-100 border-b border-gray-700 shadow-sm">
        <button
          onClick={handleCwdClick}
          disabled={isLoadingMapping}
          className="truncate font-mono text-sm font-medium hover:text-blue-400 hover:underline cursor-pointer transition-colors disabled:opacity-50 disabled:cursor-wait text-left"
          title={`Open ${cwd} in VSCode`}
        >
          {isLoadingMapping ? `${cwd} (loading...)` : cwd}
        </button>
      </div>
    </>
  );
}
