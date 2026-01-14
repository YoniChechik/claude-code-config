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
      className="px-4 py-2 bg-red-600 hover:bg-red-500 disabled:bg-gray-600 disabled:cursor-not-allowed text-white font-semibold rounded-xl transition-colors duration-200 shadow-sm hover:shadow-md"
      title="Stop generation"
    >
      <span className="flex items-center gap-2">
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
