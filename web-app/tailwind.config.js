/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: "class",
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        // Background layers
        surface: {
          primary: "#0a0a0a",
          secondary: "#141414",
          tertiary: "#1e1e1e",
          elevated: "#282828",
        },
        // Brand colors
        brand: {
          primary: "#6366f1",
          secondary: "#8b5cf6",
        },
        // Semantic colors
        success: "#10b981",
        warning: "#f59e0b",
        error: "#ef4444",
        info: "#3b82f6",
        // Text colors
        text: {
          primary: "#f5f5f5",
          secondary: "#a3a3a3",
          muted: "#737373",
          accent: "#c7d2fe",
        },
        // Border colors
        border: {
          default: "#262626",
          subtle: "#1c1c1c",
          emphasis: "#404040",
        },
        // Tool colors (for ToolUseCard)
        tool: {
          task: {
            light: "#c084fc",
            DEFAULT: "#a855f7",
            dark: "#7e22ce",
          },
          bash: {
            light: "#fbbf24",
            DEFAULT: "#f59e0b",
            dark: "#d97706",
          },
          read: {
            light: "#34d399",
            DEFAULT: "#10b981",
            dark: "#059669",
          },
          write: {
            light: "#60a5fa",
            DEFAULT: "#3b82f6",
            dark: "#2563eb",
          },
          grep: {
            light: "#22d3ee",
            DEFAULT: "#06b6d4",
            dark: "#0891b2",
          },
          skill: {
            light: "#f472b6",
            DEFAULT: "#ec4899",
            dark: "#db2777",
          },
        },
      },
      spacing: {
        xs: "0.5rem",
        sm: "0.75rem",
        md: "1rem",
        lg: "1.5rem",
        xl: "2rem",
        "2xl": "3rem",
      },
      keyframes: {
        "border-spin": {
          "0%": { borderColor: "#3b82f6" },
          "25%": { borderColor: "#8b5cf6" },
          "50%": { borderColor: "#ec4899" },
          "75%": { borderColor: "#8b5cf6" },
          "100%": { borderColor: "#3b82f6" },
        },
        "flash-gray": {
          "0%, 100%": { backgroundColor: "transparent" },
          "50%": { backgroundColor: "rgba(107, 114, 128, 0.3)" },
        },
      },
      animation: {
        "border-spin": "border-spin 2s ease-in-out infinite",
        "flash-gray": "flash-gray 0.3s ease-in-out",
      },
    },
  },
  plugins: [],
};
