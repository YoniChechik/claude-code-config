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
    <div className="w-full border-b px-md py-xs text-xs flex items-center justify-center gap-md bg-surface-secondary border-border-default text-text-secondary">
      <span>Claude Version: {status.version}</span>
    </div>
  );
}
