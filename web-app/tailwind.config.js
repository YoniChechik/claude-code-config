/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: 'class',
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      keyframes: {
        'border-spin': {
          '0%': { borderColor: '#3b82f6' },
          '25%': { borderColor: '#8b5cf6' },
          '50%': { borderColor: '#ec4899' },
          '75%': { borderColor: '#8b5cf6' },
          '100%': { borderColor: '#3b82f6' },
        },
        'flash-gray': {
          '0%, 100%': { backgroundColor: 'transparent' },
          '50%': { backgroundColor: 'rgba(107, 114, 128, 0.3)' },
        },
      },
      animation: {
        'border-spin': 'border-spin 2s ease-in-out infinite',
        'flash-gray': 'flash-gray 0.3s ease-in-out',
      },
    },
  },
  plugins: [],
}
