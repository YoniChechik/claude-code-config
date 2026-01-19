import { test, expect } from "@playwright/test";

/**
 * Stop Button E2E Tests - Real Streaming Cancellation
 *
 * These tests verify stop button behavior with real API streaming.
 * UI-only tests are covered in __tests__/components/StopButton.test.tsx
 */
test.describe("Stop Button - Real Streaming Behavior", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should cancel request when stop button is clicked", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message that would normally take time to respond
    await chatInput.fill("tell me a long story");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for stop button to appear
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait a moment to ensure streaming has started
    await page.waitForTimeout(1000);

    // Click stop button
    await stopButton.click();

    // Stop button should disappear immediately
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // Streaming message should be cleared (no animate-border-spin visible)
    const streamingMessages = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(streamingMessages).toBe(0);
  });

  test("should allow sending new message after cancellation", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send first message
    await chatInput.fill("first message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for stop button and click it
    await expect(stopButton).toBeVisible({ timeout: 2000 });
    await page.waitForTimeout(500);
    await stopButton.click();

    // Wait for stop button to disappear
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // Send a new message
    await chatInput.fill("second message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // New streaming should start (stop button appears again)
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Verify streaming message appears
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 3000 });
  });

  test("should work when stopping during tool use blocks", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message that will trigger tool calls
    await chatInput.fill("search for files matching **/*.ts");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for stop button
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait for tool use to appear
    await page.waitForTimeout(2000);

    // Click stop while tool use is active
    await stopButton.click();

    // Stop button should disappear
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // No streaming message should remain
    const streamingMessages = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(streamingMessages).toBe(0);

    // Input should be functional
    await chatInput.fill("works after stop");
    await expect(chatInput).toHaveValue("works after stop");
  });
});
