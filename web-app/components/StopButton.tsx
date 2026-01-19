"use client";

interface StopButtonProps {
  onClick: () => void;
  disabled?: boolean;
}

/**
 * Stop button for canceling streaming requests
 */
export default function StopButton({
  onClick,
  disabled = false,
}: StopButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="px-md py-sm bg-error hover:bg-error/80 disabled:bg-surface-elevated disabled:cursor-not-allowed text-text-primary font-semibold rounded-xl transition-colors duration-200 shadow-md hover:shadow-lg"
      title="Stop generation"
    >
      <span className="flex items-center gap-md">
        <svg
          className="w-4 h-4"
          fill="currentColor"
          viewBox="0 0 20 20"
          xmlns="http://www.w3.org/2000/svg"
        >
          <rect x="4" y="4" width="12" height="12" rx="1" />
        </svg>
        Stop
      </span>
    </button>
  );
}
