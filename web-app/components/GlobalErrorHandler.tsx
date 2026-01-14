"use client";

import { useEffect, useState } from "react";
import ErrorModal from "./ErrorModal";

export default function GlobalErrorHandler() {
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    const handleError = (event: ErrorEvent) => {
      console.error("Global error:", event.error);
      setError(event.error || new Error(event.message));
      event.preventDefault();
    };

    const handleUnhandledRejection = (event: PromiseRejectionEvent) => {
      console.error("Unhandled promise rejection:", event.reason);
      const error =
        event.reason instanceof Error
          ? event.reason
          : new Error(String(event.reason));
      setError(error);
      event.preventDefault();
    };

    window.addEventListener("error", handleError);
    window.addEventListener("unhandledrejection", handleUnhandledRejection);

    return () => {
      window.removeEventListener("error", handleError);
      window.removeEventListener("unhandledrejection", handleUnhandledRejection);
    };
  }, []);

  const handleDismiss = () => {
    setError(null);
  };

  if (!error) return null;

  return (
    <ErrorModal
      error={error}
      isOpen={true}
      onDismiss={handleDismiss}
    />
  );
}
