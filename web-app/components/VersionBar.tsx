"use client";

import { useEffect, useState } from "react";

export default function VersionBar() {
  const [version, setVersion] = useState<string>("");

  useEffect(() => {
    fetch("/api/version")
      .then((res) => res.json())
      .then((data) => setVersion(data.version))
      .catch((err) => console.error("Failed to fetch version:", err));
  }, []);

  if (!version) return null;

  return (
    <div className="w-full bg-gray-800 border-b border-gray-700 px-4 py-1 text-xs text-gray-400 flex items-center justify-center">
      <span>Claude Version: {version}</span>
    </div>
  );
}
