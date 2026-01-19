"use client";

import { useState } from "react";

interface ErrorModalProps {
  error: Error;
  errorInfo?: React.ErrorInfo | null;
  isOpen: boolean;
  onDismiss: () => void;
}

export default function ErrorModal({
  error,
  errorInfo,
  isOpen,
  onDismiss,
}: ErrorModalProps) {
  const [showStack, setShowStack] = useState(false);
  const [showComponentStack, setShowComponentStack] = useState(false);
  const [copied, setCopied] = useState(false);

  if (!isOpen) return null;

  const handleReload = () => {
    window.location.reload();
  };

  const handleCopyError = async () => {
    const errorText = `Error Name: ${error.name || "Error"}
Error Message: ${error.message || "An unknown error occurred"}

Stack Trace:
${error.stack || "No stack trace available"}

Component Stack:
${errorInfo?.componentStack || "No component stack available"}`;

    await navigator.clipboard.writeText(errorText);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div
      className="fixed inset-0 bg-black/70 flex items-center justify-center z-50"
      onClick={onDismiss}
    >
      <div
        className="bg-surface-elevated rounded-lg shadow-xl max-w-2xl w-full mx-md p-xl max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-xl font-semibold text-error mb-md">
          Application Error
        </h2>

        <div className="space-y-md">
          <div>
            <p className="text-text-primary text-lg font-semibold mb-sm">
              {error.message || "An unknown error occurred"}
            </p>
            <p className="text-text-secondary text-sm">
              {error.name || "Error"}
            </p>
          </div>

          {error.stack && (
            <div>
              <button
                onClick={() => setShowStack(!showStack)}
                className="text-sm text-text-accent hover:text-brand-primary mb-sm"
              >
                {showStack ? "▼" : "▶"} Stack Trace
              </button>
              {showStack && (
                <pre className="bg-surface-primary p-md rounded text-xs font-mono text-text-secondary overflow-x-auto max-h-60 overflow-y-auto">
                  {error.stack}
                </pre>
              )}
            </div>
          )}

          {errorInfo?.componentStack && (
            <div>
              <button
                onClick={() => setShowComponentStack(!showComponentStack)}
                className="text-sm text-text-accent hover:text-brand-primary mb-sm"
              >
                {showComponentStack ? "▼" : "▶"} Component Stack
              </button>
              {showComponentStack && (
                <pre className="bg-surface-primary p-md rounded text-xs font-mono text-text-secondary overflow-x-auto max-h-60 overflow-y-auto">
                  {errorInfo.componentStack}
                </pre>
              )}
            </div>
          )}

          <div className="flex justify-end gap-md pt-md">
            <button
              type="button"
              onClick={handleCopyError}
              className="px-md py-sm bg-surface-tertiary text-text-secondary rounded-md hover:bg-surface-elevated transition-colors"
            >
              {copied ? "Copied!" : "Copy Error"}
            </button>
            <button
              type="button"
              onClick={onDismiss}
              className="px-md py-sm bg-surface-tertiary text-text-secondary rounded-md hover:bg-surface-elevated transition-colors"
            >
              Dismiss
            </button>
            <button
              type="button"
              onClick={handleReload}
              className="px-md py-sm bg-brand-primary text-text-primary rounded-md hover:bg-brand-secondary transition-colors"
            >
              Reload Page
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
