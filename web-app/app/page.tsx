"use client";

import { useEffect, useState } from "react";
import SplitLayout from "@/components/SplitLayout";
import type { SlashCommand } from "@/lib/types";

/**
 * Main page - initializes two sessions and renders split layout
 */
export default function Home() {
  const [leftSessionId, setLeftSessionId] = useState<string | null>(null);
  const [rightSessionId, setRightSessionId] = useState<string | null>(null);
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

      // Create two sessions
      const [leftResponse, rightResponse] = await Promise.all([
        fetch("/api/sessions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ cwd }),
        }),
        fetch("/api/sessions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ cwd }),
        }),
      ]);

      const leftData = await leftResponse.json();
      const rightData = await rightResponse.json();

      if (leftData.session && rightData.session) {
        setLeftSessionId(leftData.session.id);
        setRightSessionId(rightData.session.id);
      } else {
        throw new Error("Failed to create sessions");
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

  if (!leftSessionId || !rightSessionId) {
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
        leftSessionId={leftSessionId}
        rightSessionId={rightSessionId}
        commands={commands}
      />
    </main>
  );
}
