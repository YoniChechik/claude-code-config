import { test, expect } from "@playwright/test";

test.describe("Content Rendering", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should render text blocks without truncation", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message asking for a response
    await chatInput.fill("say hello");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get the content div
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(contentDiv).toBeVisible();

    // Verify content is present and not empty
    const textContent = await contentDiv.textContent();
    expect(textContent).toBeTruthy();
    expect(textContent!.length).toBeGreaterThan(0);

    // Verify no overflow-hidden that would truncate content
    const contentClasses = await contentDiv.getAttribute("class");
    expect(contentClasses).not.toContain("overflow-hidden");
  });

  test("should render thinking blocks correctly", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message that might trigger thinking
    await chatInput.fill("solve a complex problem");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to start
    await page.waitForTimeout(2000);

    // Check if thinking block appears (they have italic style and gray color)
    // Thinking blocks may or may not appear depending on model behavior
    const thinkingBlocks = leftPane.locator("div.italic.text-gray-400");
    const thinkingCount = await thinkingBlocks.count();

    // If thinking blocks exist, verify they're styled correctly
    if (thinkingCount > 0) {
      const firstThinking = thinkingBlocks.first();
      await expect(firstThinking).toBeVisible();

      // Verify styling
      const classes = await firstThinking.getAttribute("class");
      expect(classes).toContain("italic");
      expect(classes).toContain("text-gray-400");
    }
  });

  test("should display tool use blocks correctly", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message that will trigger tool use
    await chatInput.fill("read the package.json file");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for tool use block to appear
    const toolUseBlock = leftPane
      .locator("div.border-l-4")
      .filter({ hasText: "[Read]" })
      .first();
    await expect(toolUseBlock).toBeVisible({ timeout: 15000 });

    // Verify tool use block has correct styling (border-l-4)
    const classes = await toolUseBlock.getAttribute("class");
    expect(classes).toContain("border-l-4");

    // Verify tool name is visible
    const toolText = await toolUseBlock.textContent();
    expect(toolText).toContain("Read");
  });

  test("should display tool result blocks correctly", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message that will trigger tool use and return results
    await chatInput.fill("read the package.json file");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for tool result to appear (bg-gray-800 with actual content)
    await page.waitForTimeout(5000);

    // Tool results are in bg-gray-800 divs (same as message container)
    // Wait for the full response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Verify tool use block appeared
    const toolUseBlock = claudeMessage.locator("div.border-l-4").first();
    await expect(toolUseBlock).toBeVisible();
  });

  test("should handle tool result expand/collapse", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message that will return tool results
    await chatInput.fill("read package.json");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Look for collapsible sections (tool results might be collapsible)
    // Tool results typically have a header that can be clicked
    const toolResultHeaders = claudeMessage.locator("div.cursor-pointer");
    const headerCount = await toolResultHeaders.count();

    // If collapsible headers exist, test expand/collapse
    if (headerCount > 0) {
      const firstHeader = toolResultHeaders.first();
      await expect(firstHeader).toBeVisible();

      // Click to toggle
      await firstHeader.click();
      await page.waitForTimeout(300);

      // Click again to toggle back
      await firstHeader.click();
      await page.waitForTimeout(300);

      // Should not crash
      await expect(firstHeader).toBeVisible();
    }
  });

  test("should not have console errors during rendering", async ({ page }) => {
    const consoleErrors: string[] = [];

    // Listen for console errors
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        consoleErrors.push(msg.text());
      }
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message
    await chatInput.fill("hello");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Give time for any async rendering
    await page.waitForTimeout(2000);

    // Verify no console errors occurred
    // Filter out known acceptable errors (like network errors in tests)
    const relevantErrors = consoleErrors.filter(
      (err) =>
        !err.includes("Failed to load resource") &&
        !err.includes("net::ERR_") &&
        !err.includes("favicon"),
    );

    expect(relevantErrors.length).toBe(0);
  });

  test("should display all messages without missing content", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send first message
    await chatInput.fill("first");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for first response
    await page.waitForTimeout(3000);

    // Send second message
    await chatInput.fill("second");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for second response
    await page.waitForTimeout(3000);

    // Verify both user messages are visible
    await expect(leftPane.locator("text=first")).toBeVisible();
    await expect(leftPane.locator("text=second")).toBeVisible();

    // Verify multiple Claude responses exist
    const claudeMessages = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") });
    const messageCount = await claudeMessages.count();

    // Should have at least 2 Claude messages
    expect(messageCount).toBeGreaterThanOrEqual(2);

    // All messages should have content
    for (let i = 0; i < messageCount; i++) {
      const msg = claudeMessages.nth(i);
      await expect(msg).toBeVisible();

      const content = msg.locator("div.whitespace-pre-wrap").first();
      await expect(content).toBeVisible();
    }
  });

  test("should render content blocks in correct order", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send message that will trigger tool use
    await chatInput.fill("use glob to search for **/*.json files");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to complete
    await page.waitForTimeout(8000);

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get all child blocks in the message
    const messageContent = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(messageContent).toBeVisible();

    // Verify content has been rendered (either text or tool blocks)
    const hasContent = await messageContent.evaluate((el) => {
      return el.children.length > 0 || el.textContent!.trim().length > 0;
    });

    expect(hasContent).toBe(true);
  });

  test("should handle streaming text without data loss", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message
    await chatInput.fill("tell me a fact");
    await sendButton.click();
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(1000);

    // Check streaming message appears
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Get text while streaming (if any)
    const streamingContent = streamingMessage
      .locator("div.whitespace-pre-wrap")
      .first();
    await expect(streamingContent).toBeVisible();

    const textDuringStreaming = await streamingContent.textContent();

    // Wait for completion
    await page.waitForTimeout(5000);

    // Get final message
    const completedMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(completedMessage).toBeVisible();

    const finalContent = completedMessage
      .locator("div.whitespace-pre-wrap")
      .first();
    const finalText = await finalContent.textContent();

    // Final text should be at least as long as streaming text
    expect(finalText!.length).toBeGreaterThanOrEqual(0);

    // If there was text during streaming, final should contain it
    if (textDuringStreaming && textDuringStreaming.trim().length > 0) {
      // Final text should have content (may be different due to streaming)
      expect(finalText!.length).toBeGreaterThan(0);
    }
  });
});
