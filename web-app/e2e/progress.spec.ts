import { test, expect } from "@playwright/test";

test.describe("Progress Indicator", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should show progress indicator animation during streaming", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send a message that will trigger streaming
    await chatInput.fill("hi");
    await chatInput.press("Enter");

    // Wait for input to clear
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Find the streaming message container - should appear quickly
    const streamingMessage = leftPane
      .locator("div.animate-border-spin")
      .first();

    // Verify streaming message is visible
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Verify the animation class is applied
    const classes = await streamingMessage.getAttribute("class");
    expect(classes).toContain("animate-border-spin");
  });

  test("should hide progress indicator when streaming completes", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send a short message
    await chatInput.fill("hi");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify streaming message appears with animation
    const streamingMessage = leftPane
      .locator("div.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Wait for response to complete (longer wait for real API)
    await page.waitForTimeout(15000);

    // Check if animate-border-spin is gone
    const animatingMessages = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(animatingMessages).toBe(0);

    // Verify completed message is visible
    const completedMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(completedMessage).toBeVisible();
  });

  test("should show progress indicator for multiple messages", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send first message
    await chatInput.fill("first");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify first streaming message has animation
    const streamingMessage1 = leftPane
      .locator("div.animate-border-spin")
      .first();
    await expect(streamingMessage1).toBeVisible({ timeout: 5000 });

    // Wait for first message to complete
    await page.waitForTimeout(15000);
    const animatingAfterFirst = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(animatingAfterFirst).toBe(0);

    // Send second message
    await chatInput.fill("second");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify second streaming message has animation
    const streamingMessage2 = leftPane
      .locator("div.animate-border-spin")
      .first();
    await expect(streamingMessage2).toBeVisible({ timeout: 5000 });

    // Verify animation class is applied
    const classes = await streamingMessage2.getAttribute("class");
    expect(classes).toContain("animate-border-spin");
  });

  test("should maintain message readability during animation", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send a message
    await chatInput.fill("test");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Find streaming message
    const streamingMessage = leftPane
      .locator("div.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Verify message content is visible (Claude label should be present)
    await expect(streamingMessage.locator("text=Claude")).toBeVisible();

    // Content should be readable - check that the message has content
    const messageText = await streamingMessage.textContent();
    expect(messageText).toContain("Claude");
  });
});
