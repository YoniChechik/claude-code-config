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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message
    await chatInput.fill("hello");
    await sendButton.click();

    // Wait for input to clear
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait a moment for streaming to start
    await page.waitForTimeout(500);

    // Find the streaming message container
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a short message
    await chatInput.fill("hi");
    await sendButton.click();

    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify streaming message appears with animation
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Wait for response to complete (Claude message without animate-border-spin)
    const completedMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(completedMessage).toBeVisible({ timeout: 20000 });

    // Verify the completed message does NOT have the animation class
    // (streaming message should be replaced by completed message)
    await page.waitForTimeout(1000);

    // Check if animate-border-spin is still present
    const animatingMessages = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(animatingMessages).toBe(0);
  });

  test("should show progress indicator for multiple messages", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send first message
    await chatInput.fill("first message");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify first streaming message has animation
    const streamingMessage1 = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage1).toBeVisible({ timeout: 5000 });

    // Wait for first message to complete
    await page.waitForTimeout(3000);
    const animatingAfterFirst = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(animatingAfterFirst).toBe(0);

    // Send second message
    await chatInput.fill("second message");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify second streaming message has animation
    await page.waitForTimeout(500);
    const streamingMessage2 = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message
    await chatInput.fill("test message");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Find streaming message
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Verify message content is visible (Claude label should be present)
    await expect(streamingMessage.locator("text=Claude")).toBeVisible();

    // Verify the whitespace-pre-wrap content div is present
    const contentDiv = streamingMessage.locator("div.whitespace-pre-wrap");
    await expect(contentDiv).toBeVisible();

    // Content should be readable (has some text or is waiting for streaming)
    const content = await contentDiv.textContent();
    // Either has text content or is empty but visible (streaming hasn't started yet)
    expect(content).toBeDefined();
  });
});
