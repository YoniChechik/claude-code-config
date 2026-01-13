"use client";

import { useEffect, useState } from "react";
import SplitLayout from "@/components/SplitLayout";
import type { SlashCommand } from "@/lib/types";

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

  const initializeSessions = async () => {
    try {
      // Get current working directory (default to /home/ubuntu)
      const cwd = process.env.NEXT_PUBLIC_DEFAULT_CWD || "/home/ubuntu";

      // Create one session to start
      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([data.session.id]);
      } else {
        throw new Error("Failed to create session");
      }

      // Load slash commands (client-side we'll use a simplified version)
      // In a real implementation, this would call an API endpoint
      setCommands([
        { name: "help", source: "builtin" },
        { name: "clear", source: "builtin" },
        { name: "model", source: "builtin" },
        { name: "status", source: "builtin" },
      ]);

      setLoading(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to initialize");
      setLoading(false);
    }
  };

  const addSession = async () => {
    try {
      const cwd = process.env.NEXT_PUBLIC_DEFAULT_CWD || "/home/ubuntu";

      const response = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cwd }),
      });

      const data = await response.json();

      if (data.session) {
        setSessionIds([...sessionIds, data.session.id]);
      }
    } catch (err) {
      console.error("Failed to add session:", err);
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
      />
    </main>
  );
}
