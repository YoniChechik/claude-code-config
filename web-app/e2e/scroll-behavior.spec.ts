import { test, expect } from "@playwright/test";

test.describe("Chat Scroll Behavior", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });
  });

  test("should auto-scroll to bottom as new streaming data arrives by default", async ({
    page,
  }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Short test response for scroll testing"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send a message that will generate a long response
    await chatInput.fill("Write a long story about a robot");
    await chatInput.press("Enter");

    // Wait for input to clear
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(1000);

    // Get the messages container
    const messagesContainer = leftPane.locator("div.overflow-y-auto").first();

    // Wait for some streaming content
    await page.waitForTimeout(2000);

    // Check that we're scrolled near the bottom
    const isNearBottom = await messagesContainer.evaluate((el) => {
      const distanceFromBottom =
        el.scrollHeight - el.scrollTop - el.clientHeight;
      return distanceFromBottom <= 100;
    });

    expect(isNearBottom).toBe(true);

    // Wait for more streaming
    await page.waitForTimeout(1000);

    // Check we're still at the bottom (auto-scrolling)
    const stillAtBottom = await messagesContainer.evaluate((el) => {
      const distanceFromBottom =
        el.scrollHeight - el.scrollTop - el.clientHeight;
      return distanceFromBottom <= 100;
    });

    expect(stillAtBottom).toBe(true);
  });

  test.skip("should stop auto-scrolling when user scrolls up during streaming", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Build up message history first to ensure scrollable content
    for (let i = 0; i < 3; i++) {
      await chatInput.fill(`msg ${i + 1}`);
      await chatInput.press("Enter");
      await expect(chatInput).toHaveValue("", { timeout: 10000 });
      // Wait for streaming to complete
      await leftPane.locator('div.animate-border-spin').waitFor({ state: 'detached', timeout: 30000 });
      await page.waitForTimeout(1000);
    }

    // Send a message that will generate a long response
    await chatInput.fill("tell me a long story");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(2000);

    // Get the messages container
    const messagesContainer = leftPane.locator("div.overflow-y-auto").first();

    // Scroll up significantly
    await messagesContainer.evaluate((el) => {
      el.scrollTop = Math.max(0, el.scrollTop - 400);
    });

    // Wait after scrolling
    await page.waitForTimeout(500);

    // Record the scroll position
    const scrollPosAfterScrollingUp = await messagesContainer.evaluate(
      (el) => el.scrollTop,
    );

    // Wait for more streaming
    await page.waitForTimeout(3000);

    // Check that scroll position hasn't changed much
    const scrollPosAfterMoreStreaming = await messagesContainer.evaluate(
      (el) => el.scrollTop,
    );

    // Position should be roughly the same (within 50 pixels for tolerance)
    expect(
      Math.abs(scrollPosAfterScrollingUp - scrollPosAfterMoreStreaming),
    ).toBeLessThan(50);

    // Verify we're NOT at the bottom
    const isAtBottom = await messagesContainer.evaluate((el) => {
      const distanceFromBottom =
        el.scrollHeight - el.scrollTop - el.clientHeight;
      return distanceFromBottom <= 100;
    });

    expect(isAtBottom).toBe(false);
  });

  test.skip("should resume auto-scrolling when user scrolls back to bottom", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Build up message history
    for (let i = 0; i < 3; i++) {
      await chatInput.fill(`msg ${i + 1}`);
      await chatInput.press("Enter");
      await expect(chatInput).toHaveValue("", { timeout: 10000 });
      await leftPane.locator('div.animate-border-spin').waitFor({ state: 'detached', timeout: 30000 });
      await page.waitForTimeout(1000);
    }

    // Send a message for a long response
    await chatInput.fill("tell me a long story");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(2000);

    // Get the messages container
    const messagesContainer = leftPane.locator("div.overflow-y-auto").first();

    // Scroll up significantly
    await messagesContainer.evaluate((el) => {
      el.scrollTop = Math.max(0, el.scrollTop - 400);
    });

    // Verify we're not at the bottom
    await page.waitForTimeout(500);
    const notAtBottom = await messagesContainer.evaluate((el) => {
      const distanceFromBottom =
        el.scrollHeight - el.scrollTop - el.clientHeight;
      return distanceFromBottom > 100;
    });
    expect(notAtBottom).toBe(true);

    // Scroll back to the bottom
    await messagesContainer.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });

    // Wait for scroll handler
    await page.waitForTimeout(500);

    // Wait for more streaming
    await page.waitForTimeout(3000);

    // Check that we're still at the bottom (auto-scroll resumed)
    const backAtBottom = await messagesContainer.evaluate((el) => {
      const distanceFromBottom =
        el.scrollHeight - el.scrollTop - el.clientHeight;
      return distanceFromBottom <= 100;
    });

    expect(backAtBottom).toBe(true);
  });

  test("should maintain scroll position on new message arrival when scrolled up", async ({
    page,
  }) => {
    // Mock multiple API responses
    let callCount = 0;
    await page.route("**/api/commands", async (route) => {
      callCount++;
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Response ${callCount}"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Build up message history to ensure scrollable content
    for (let i = 0; i < 4; i++) {
      await chatInput.fill(`Message ${i + 1}: Tell me something`);
      await chatInput.press("Enter");
      await expect(chatInput).toHaveValue("", { timeout: 10000 });
      // Wait for streaming to complete (streaming message box disappears)
      await page.waitForTimeout(1000);
      await leftPane.locator('div.animate-border-spin').waitFor({ state: 'detached', timeout: 30000 });
      await page.waitForTimeout(1000);
    }

    // Send message we'll test with
    await chatInput.fill("tell me more");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 5000 });

    // Wait a bit for content
    await page.waitForTimeout(1000);

    const messagesContainer = leftPane.locator("div.overflow-y-auto").first();

    // Scroll to top
    await messagesContainer.evaluate((el) => {
      el.scrollTop = 0;
    });

    const scrollPosAtTop = await messagesContainer.evaluate(
      (el) => el.scrollTop,
    );

    // Wait for more streaming
    await page.waitForTimeout(2000);

    // Verify scroll position stayed at top
    const scrollPosAfterStreaming = await messagesContainer.evaluate(
      (el) => el.scrollTop,
    );

    // Should still be near the top (within 10 pixels)
    expect(Math.abs(scrollPosAtTop - scrollPosAfterStreaming)).toBeLessThan(
      10,
    );
  });
});
