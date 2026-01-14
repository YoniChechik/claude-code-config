import { test, expect } from "@playwright/test";

test.describe("Features Integration", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should show progress indicator and stop button together", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message
    await chatInput.fill("hello world");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(500);

    // Both progress indicator and stop button should be visible
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Verify both have correct classes
    const messageClasses = await streamingMessage.getAttribute("class");
    expect(messageClasses).toContain("animate-border-spin");

    const buttonClasses = await stopButton.getAttribute("class");
    expect(buttonClasses).toContain("bg-red-600");
  });

  test("should hide both progress and stop button when complete", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a short message
    await chatInput.fill("hi");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify both appear
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait for completion
    await page.waitForTimeout(5000);

    // Both should be hidden
    const animatingCount = await leftPane.locator("div.animate-border-spin").count();
    expect(animatingCount).toBe(0);
    await expect(stopButton).not.toBeVisible();
  });

  test("should handle stop during progress indicator animation", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send a message
    await chatInput.fill("tell me something long");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for both to appear
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Click stop while animating
    await page.waitForTimeout(1000);
    await stopButton.click();

    // Both should disappear
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });
    const animatingAfterStop = await leftPane
      .locator("div.animate-border-spin")
      .count();
    expect(animatingAfterStop).toBe(0);
  });

  test("should handle multiple rapid messages with stops", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // First message
    await chatInput.fill("first");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });
    await page.waitForTimeout(500);
    await stopButton.click();
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // Second message immediately after
    await chatInput.fill("second");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });
    await page.waitForTimeout(500);
    await stopButton.click();
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // Third message
    await chatInput.fill("third");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Let this one complete
    await page.waitForTimeout(5000);
    await expect(stopButton).not.toBeVisible();

    // All user messages should be visible
    await expect(leftPane.locator("text=first")).toBeVisible();
    await expect(leftPane.locator("text=second")).toBeVisible();
    await expect(leftPane.locator("text=third")).toBeVisible();
  });

  test("should stop during text content streaming", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send message that will stream text
    await chatInput.fill("tell me a story");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait for some text to appear
    await page.waitForTimeout(1500);

    // Stop during text streaming
    await stopButton.click();

    // Everything should clean up
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });
    const animating = await leftPane.locator("div.animate-border-spin").count();
    expect(animating).toBe(0);

    // Input should work
    await chatInput.fill("works after stop");
    await expect(chatInput).toHaveValue("works after stop");
  });

  test("should stop during tool use blocks", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send message that triggers tools
    await chatInput.fill("search for **/*.md files");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming and stop button
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait for tool use to potentially start
    await page.waitForTimeout(2000);

    // Stop during tool use
    await stopButton.click();

    // Should clean up properly
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });
    const animating = await leftPane.locator("div.animate-border-spin").count();
    expect(animating).toBe(0);
  });

  test("should stop during thinking blocks", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send message that might trigger thinking
    await chatInput.fill("solve this complex problem: what is the meaning of life");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Wait a moment for potential thinking block
    await page.waitForTimeout(1500);

    // Stop
    await stopButton.click();

    // Clean up
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });
    const animating = await leftPane.locator("div.animate-border-spin").count();
    expect(animating).toBe(0);
  });

  test("should maintain all content rendering after stop", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send first message and let it complete
    await chatInput.fill("first complete message");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await page.waitForTimeout(5000);

    // Verify first message content is visible
    await expect(leftPane.locator("text=first complete message")).toBeVisible();
    const firstResponse = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .first();
    await expect(firstResponse).toBeVisible();

    // Send second message and stop it
    await chatInput.fill("second stopped message");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });
    await page.waitForTimeout(1000);
    await stopButton.click();
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });

    // First message should STILL be visible
    await expect(leftPane.locator("text=first complete message")).toBeVisible();
    await expect(firstResponse).toBeVisible();

    // Both user messages should be visible
    await expect(leftPane.locator("text=second stopped message")).toBeVisible();
  });

  test("should handle stop with no partial content loss", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send multiple messages, stopping some
    const messages = ["msg1", "msg2", "msg3"];

    for (let i = 0; i < messages.length; i++) {
      await chatInput.fill(messages[i]);
      await sendButton.click();
      await expect(chatInput).toHaveValue("", { timeout: 3000 });
      await expect(stopButton).toBeVisible({ timeout: 2000 });

      if (i < 2) {
        // Stop first two
        await page.waitForTimeout(500);
        await stopButton.click();
        await expect(stopButton).not.toBeVisible({ timeout: 2000 });
      } else {
        // Let last one complete
        await page.waitForTimeout(5000);
      }
    }

    // All user messages should be visible
    for (const msg of messages) {
      await expect(leftPane.locator(`text=${msg}`)).toBeVisible();
    }

    // No streaming indicators should remain
    const animating = await leftPane.locator("div.animate-border-spin").count();
    expect(animating).toBe(0);
  });

  test("existing chat functionality still works with new features", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Test basic chat flow (regression test)
    await chatInput.fill("hello");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // User message should appear
    await expect(leftPane.locator("text=hello")).toBeVisible({ timeout: 5000 });

    // Response should appear
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Content should be present
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(contentDiv).toBeVisible();
    const responseText = await contentDiv.textContent();
    expect(responseText).toBeTruthy();
    expect(responseText!.length).toBeGreaterThan(0);

    // Should be able to send another message
    await chatInput.fill("second message");
    await expect(sendButton).not.toBeDisabled();
  });

  test("should handle progress and stop with tool causal ordering", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();
    const stopButton = leftPane.locator("button:has-text('Stop')");

    // Send message that triggers multiple tool calls
    await chatInput.fill("use glob to search for these: **/*.ts, **/*.json");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify streaming starts with progress indicator
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });
    await expect(stopButton).toBeVisible({ timeout: 2000 });

    // Let it run for a bit to potentially show some tool calls
    await page.waitForTimeout(3000);

    // Stop during tool execution
    await stopButton.click();

    // Should clean up
    await expect(stopButton).not.toBeVisible({ timeout: 2000 });
    const animating = await leftPane.locator("div.animate-border-spin").count();
    expect(animating).toBe(0);

    // User message should still be visible
    await expect(
      leftPane.locator("text=use glob to search for these"),
    ).toBeVisible();

    // Can send new message
    await chatInput.fill("new message after tool stop");
    await expect(sendButton).not.toBeDisabled();
  });
});
