"use client";

import { useEffect, useState } from "react";
import SplitLayout from "@/components/SplitLayout";
import type { SlashCommand } from "@/lib/types";
import { getOrCreateWindowId } from "@/lib/window-id";

/**
 * Main page - initializes session(s) and renders dynamic split layout
 */
export default function Home() {
  const [sessionIds, setSessionIds] = useState<string[]>([]);
  const [commands, setCommands] = useState<SlashCommand[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    initializeSessions();
  }, []);

  // Tab close cleanup and heartbeat
  useEffect(() => {
    if (sessionIds.length === 0) return;

    // Cleanup handler for both beforeunload and pagehide
    const handleCleanup = () => {
      // Use sendBeacon for non-blocking cleanup
      const blob = new Blob(
        [JSON.stringify({ sessionIds })],
        { type: "application/json" },
      );
      navigator.sendBeacon("/api/sessions/cleanup", blob);
    };

    // Beforeunload fires on refresh/navigation (earliest opportunity)
    window.addEventListener("beforeunload", handleCleanup);
    // Pagehide fires on tab close (fallback for edge cases)
    window.addEventListener("pagehide", handleCleanup);

    // Heartbeat every 10s
    const heartbeatInterval = setInterval(() => {
      fetch("/api/sessions/heartbeat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionIds }),
      }).catch((err) => {
        console.error("Heartbeat failed:", err);
      });
    }, 10000);

    return () => {
      window.removeEventListener("beforeunload", handleCleanup);
      window.removeEventListener("pagehide", handleCleanup);
      clearInterval(heartbeatInterval);
    };
  }, [sessionIds]);

  const initializeSessions = async () => {
    try {
      // Get current working directory from backend
      const cwdResponse = await fetch("/api/cwd");
      const cwdData = await cwdResponse.json();
      const cwd = cwdData.cwd || "/home/ubuntu";

      // Get or create windowId
      const windowId = getOrCreateWindowId();

      // Create session without hostname (server will detect from SSH_CONNECTION)
      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd, windowId }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([data.session.id]);

        // Auto-load hostname mapping if SSH session
        if (
          data.session.sessionType === "ssh" &&
          data.session.clientIp
        ) {
          try {
            const mappingResponse = await fetch(
              `/api/ssh-host-mapping?clientIp=${encodeURIComponent(data.session.clientIp)}`,
            );
            const mappingData = await mappingResponse.json();

            // If mapping exists, update session with resolved hostname
            if (mappingData.hostname) {
              // No action needed - SessionHeader will handle this automatically
              console.log(
                `Auto-loaded SSH hostname mapping: ${mappingData.hostname}`,
              );
            }
          } catch (err) {
            console.error("Failed to auto-load SSH hostname mapping:", err);
          }
        }
      } else {
        throw new Error("Failed to create session");
      }

      // Load slash commands from API
      try {
        const commandsResponse = await fetch("/api/commands-list");
        const commandsData = await commandsResponse.json();
        if (commandsData.commands) {
          setCommands(commandsData.commands);
        } else {
          // Fallback to builtins if API fails
          setCommands([
            { name: "help", source: "builtin" },
            { name: "clear", source: "builtin" },
            { name: "model", source: "builtin" },
            { name: "status", source: "builtin" },
          ]);
        }
      } catch (cmdErr) {
        console.error("Failed to load commands:", cmdErr);
        // Fallback to builtins
        setCommands([
          { name: "help", source: "builtin" },
          { name: "clear", source: "builtin" },
          { name: "model", source: "builtin" },
          { name: "status", source: "builtin" },
        ]);
      }

      setLoading(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to initialize");
      setLoading(false);
    }
  };

  const addSession = async () => {
    try {
      // Get current working directory from backend
      const cwdResponse = await fetch("/api/cwd");
      const cwdData = await cwdResponse.json();
      const cwd = cwdData.cwd || "/home/ubuntu";

      // Get or create windowId
      const windowId = getOrCreateWindowId();

      // Create session without hostname (server will detect from SSH_CONNECTION)
      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd, windowId }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([...sessionIds, data.session.id]);
      }
    } catch (err) {
      console.error("Failed to add session:", err);
    }
  };

  const closeSession = async (sessionId: string) => {
    try {
      const windowId = getOrCreateWindowId();

      // If only 1 session, clear messages instead of deleting
      if (sessionIds.length === 1) {
        await fetch(`/api/sessions/${sessionId}`, {
          method: "PATCH",
          headers: {
            "x-window-id": windowId,
          },
        });
      } else {
        // Multiple sessions: delete the session
        await fetch(`/api/sessions/${sessionId}`, {
          method: "DELETE",
          headers: {
            "x-window-id": windowId,
          },
        });

        // Remove from local state
        const newSessionIds = sessionIds.filter((id) => id !== sessionId);
        setSessionIds(newSessionIds);
      }
    } catch (err) {
      console.error("Failed to close session:", err);
    }
  };

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-screen gap-4">
        <h1 className="text-4xl font-bold">ccweb</h1>
        <p className="text-gray-600">Initializing sessions...</p>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-screen gap-4">
        <h1 className="text-4xl font-bold">ccweb</h1>
        <p className="text-red-600">Error: {error}</p>
        <button
          onClick={initializeSessions}
          className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          Retry
        </button>
      </div>
    );
  }

  if (sessionIds.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-screen gap-4">
        <h1 className="text-4xl font-bold">ccweb</h1>
        <p className="text-red-600">Sessions not initialized</p>
      </div>
    );
  }

  return (
    <main className="w-screen" style={{ height: "calc(100vh - 1.75rem)" }}>
      <SplitLayout
        sessionIds={sessionIds}
        commands={commands}
        onAddSession={addSession}
        onCloseSession={closeSession}
      />
    </main>
  );
}
