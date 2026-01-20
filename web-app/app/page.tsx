"use client";

import { useEffect, useState } from "react";
import SplitLayout from "@/components/SplitLayout";
import type { SlashCommand } from "@/lib/types";
import { getHeartbeatClient } from "@/lib/heartbeat-client";
import { getCleanupHandler } from "@/lib/cleanup-handler";
import { getOrCreateWindowId } from "@/lib/window-id";

export default function Home() {
  const [sessionIds, setSessionIds] = useState<string[]>([]);
  const [commands, setCommands] = useState<SlashCommand[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [windowId, setWindowId] = useState<string>("");

  useEffect(() => {
    const wid = getOrCreateWindowId();
    setWindowId(wid);

    const cleanupHandler = getCleanupHandler();
    cleanupHandler.start();

    return () => {
      const heartbeatClient = getHeartbeatClient();
      heartbeatClient.stop();

      cleanupHandler.stop();
    };
  }, []);

  useEffect(() => {
    if (windowId) {
      initializeSessions();
    }
  }, [windowId]);

  const initializeSessions = async () => {
    try {
      const cwdResponse = await fetch("/api/cwd");
      const cwdData = await cwdResponse.json();
      const cwd = cwdData.cwd || "/home/ubuntu";

      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd, windowId }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([data.session.id]);

        const heartbeatClient = getHeartbeatClient();
        heartbeatClient.addSession(data.session.id);

        const cleanupHandler = getCleanupHandler();
        cleanupHandler.addSession(data.session.id);

        if (
          data.session.sessionType === 'ssh' &&
          data.session.clientIp &&
          (data.session.hostname === 'localhost' || data.session.hostname === '127.0.0.1')
        ) {
          try {
            const mappingResponse = await fetch(
              `/api/ssh-host-mapping?clientIp=${encodeURIComponent(data.session.clientIp)}`
            );
            const mappingData = await mappingResponse.json();

            if (mappingData.hostname) {
              console.log(`Auto-loaded SSH hostname mapping: ${mappingData.hostname}`);
            }
          } catch (err) {
            throw err;
          }
        }
      } else {
        throw new Error("Failed to create session");
      }

      try {
        const commandsResponse = await fetch("/api/commands-list");
        const commandsData = await commandsResponse.json();
        setCommands(commandsData.commands || [
          { name: "help", source: "builtin" },
          { name: "clear", source: "builtin" },
          { name: "model", source: "builtin" },
          { name: "status", source: "builtin" },
        ]);
      } catch (cmdErr) {
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
      const cwdResponse = await fetch("/api/cwd");
      const cwdData = await cwdResponse.json();
      const cwd = cwdData.cwd || "/home/ubuntu";

      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd, windowId }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([...sessionIds, data.session.id]);

        const heartbeatClient = getHeartbeatClient();
        heartbeatClient.addSession(data.session.id);

        const cleanupHandler = getCleanupHandler();
        cleanupHandler.addSession(data.session.id);
      }
    } catch (err) {
      throw err;
    }
  };

  const closeSession = async (sessionId: string) => {
    try {
      const heartbeatClient = getHeartbeatClient();
      heartbeatClient.removeSession(sessionId);

      const cleanupHandler = getCleanupHandler();
      cleanupHandler.removeSession(sessionId);

      if (sessionIds.length === 1) {
        await fetch(`/api/sessions/${sessionId}`, {
          method: "PATCH",
          headers: { "x-window-id": windowId },
        });
      } else {
        await fetch(`/api/sessions/${sessionId}`, {
          method: "DELETE",
          headers: { "x-window-id": windowId },
        });

        const newSessionIds = sessionIds.filter((id) => id !== sessionId);
        setSessionIds(newSessionIds);
      }
    } catch (err) {
      throw err;
    }
  };

  const resumeSession = async (
    sessionId: string,
    filePath: string,
    cwd: string
  ) => {
    const response = await fetch("/api/sessions/resume", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-window-id": windowId,
      },
      body: JSON.stringify({ sessionId, filePath, cwd }),
    });

    const data = await response.json();

    if (data.session) {
      setSessionIds([data.session.id]);

      const heartbeatClient = getHeartbeatClient();
      heartbeatClient.addSession(data.session.id);

      const cleanupHandler = getCleanupHandler();
      cleanupHandler.addSession(data.session.id);
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
    <main className="h-screen w-screen">
      <SplitLayout
        sessionIds={sessionIds}
        commands={commands}
        onAddSession={addSession}
        onCloseSession={closeSession}
        onResumeSession={resumeSession}
      />
    </main>
  );
}
