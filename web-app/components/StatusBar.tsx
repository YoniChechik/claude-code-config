"use client";

import { useEffect, useState } from "react";

interface StatusData {
  version: string;
  buildTimestamp: string;
  buildCommit: string;
  currentCommit: string;
  isOutdated: boolean;
}

export default function StatusBar() {
  const [status, setStatus] = useState<StatusData | null>(null);

  useEffect(() => {
    fetch("/api/version")
      .then((res) => res.json())
      .then((data) => setStatus(data))
      .catch((err) => console.error("Failed to fetch status:", err));
  }, []);

  if (!status) return null;

  return (
    <div
      className={`w-full border-b px-4 py-1 text-xs flex items-center justify-center gap-4 ${
        status.isOutdated
          ? "bg-yellow-900 border-yellow-700 text-yellow-100"
          : "bg-gray-800 border-gray-700 text-gray-400"
      }`}
    >
      <span>Claude Version: {status.version}</span>
      {status.isOutdated && (
        <span className="flex items-center gap-1 font-semibold">
          <svg
            className="w-4 h-4"
            fill="currentColor"
            viewBox="0 0 20 20"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              fillRule="evenodd"
              d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
              clipRule="evenodd"
            />
          </svg>
          Build outdated - rebuild required
        </span>
      )}
    </div>
  );
}
