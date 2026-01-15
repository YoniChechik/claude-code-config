import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : 5, // Increased concurrency: 5 workers instead of default
  reporter: "html",
  use: {
    baseURL: "http://localhost:6380", // Use separate test port
    trace: "on-first-retry",
  },

  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 720 },
      },
    },
  ],

  webServer: {
    command: "NEXT_DIR=.next-test npm run start:test",
    url: "http://localhost:6380",
    reuseExistingServer: !process.env.CI,
    timeout: 120000,
  },
});
