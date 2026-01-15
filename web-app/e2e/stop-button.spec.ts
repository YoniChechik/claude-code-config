import { test, expect } from "@playwright/test";

test.describe("Stop Button Functionality", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should show stop button when message is sent", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Verify stop button is not visible initially
    const stopButton = leftPane.locator("button:has-text('Stop')");
    await expect(stopButton).not.toBeVisible();

    // Send a message
    await chatInput.fill("hello");
    await chatInput.press("Enter");

    // Wait for input to clear
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Stop button should appear during streaming
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Verify stop button has correct styling (red background)
    const classes = await stopButton.getAttribute("class");
    expect(classes).toContain("bg-red-600");
  });

  test("should hide stop button when streaming completes", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a short message
    await chatInput.fill("hi");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Stop button should appear
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait for response to complete
    const completedMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(completedMessage).toBeVisible({ timeout: 20000 });

    // Give a moment for state to update
    await page.waitForTimeout(1000);

    // Stop button should disappear
    await expect(stopButton).not.toBeVisible({ timeout: 10000 });
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

  test("should re-enable input immediately after stopping", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message
    await chatInput.fill("hello");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for stop button
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Click stop
    await stopButton.click();

    // Input should be immediately usable
    await page.waitForTimeout(500);

    // Type in input field
    await chatInput.fill("new message");

    // Verify text was entered
    await expect(chatInput).toHaveValue("new message");

    // Input should be enabled
    await expect(chatInput).not.toBeDisabled();
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

  test("should handle multiple rapid stop clicks gracefully", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message
    await chatInput.fill("test message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for stop button
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Click stop multiple times rapidly
    await stopButton.click();
    await stopButton.click().catch(() => {
      /* May not be visible anymore */
    });
    await stopButton.click().catch(() => {
      /* May not be visible anymore */
    });

    // Wait longer before checking to ensure state is stable
    await page.waitForTimeout(2000);

    // Should not crash - stop button should disappear
    await expect(stopButton).not.toBeVisible({ timeout: 3000 });

    // Input should still be functional
    await chatInput.fill("still works");
    await expect(chatInput).toHaveValue("still works");
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

  test("should keep user message visible after cancellation", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message
    const testMessage = "keep this message";
    await chatInput.fill(testMessage);
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify user message is visible
    await expect(leftPane.locator(`text=${testMessage}`)).toBeVisible({
      timeout: 5000,
    });

    // Wait for stop button and click it
    await expect(stopButton).toBeVisible({ timeout: 2000 });
    await page.waitForTimeout(500);
    await stopButton.click();

    // Wait for stop to complete
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // User message should STILL be visible
    await expect(leftPane.locator(`text=${testMessage}`)).toBeVisible({
      timeout: 2000,
    });

    // But streaming message should be gone
    const streamingMessages = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(streamingMessages).toBe(0);
  });

  test("should not show stop button when not streaming", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Initially, stop button should not be visible
    await expect(stopButton).not.toBeVisible();

    // Wait a bit to ensure it doesn't appear unexpectedly
    await page.waitForTimeout(2000);

    // Should still not be visible
    await expect(stopButton).not.toBeVisible();
  });
});
