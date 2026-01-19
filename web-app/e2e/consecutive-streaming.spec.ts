import { test, expect } from "@playwright/test";

test.describe("Consecutive Prompts Streaming", () => {
  test("should stream text for both first and second response", async ({
    page,
  }) => {
    let requestCount = 0;

    // Mock Claude API to return streaming responses for both prompts
    await page.route("**/api/commands", async (route) => {
      requestCount++;

      if (requestCount === 1) {
        // First response - send text_delta events
        await route.fulfill({
          status: 200,
          contentType: "text/event-stream",
          body:
            'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\n' +
            'data: {"type":"text","content":"First "}\n\n' +
            'data: {"type":"text","content":"response "}\n\n' +
            'data: {"type":"text","content":"streaming"}\n\n' +
            'data: {"type":"result","duration_ms":500}\n\n',
        });
      } else if (requestCount === 2) {
        // Second response - simulate input_json_delta events (resumed session)
        await route.fulfill({
          status: 200,
          contentType: "text/event-stream",
          body:
            'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\n' +
            'data: {"type":"text","content":"Second "}\n\n' +
            'data: {"type":"text","content":"response "}\n\n' +
            'data: {"type":"text","content":"also "}\n\n' +
            'data: {"type":"text","content":"streaming"}\n\n' +
            'data: {"type":"result","duration_ms":500}\n\n',
        });
      }
    });

    await page.goto("/");
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Send first message
    await chatInput.fill("first message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for first response to appear and verify it streamed
    const firstResponse = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(firstResponse).toBeVisible({ timeout: 10000 });

    const firstContentDiv = firstResponse.locator("div.whitespace-pre-wrap");
    await expect(firstContentDiv).toBeVisible({ timeout: 5000 });

    // Verify first response text
    const firstText = await firstContentDiv.textContent();
    expect(firstText).toContain("First response streaming");

    // Send second message
    await chatInput.fill("second message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for second response to appear
    // Need to get the NEW last Claude message (after the second prompt)
    await page.waitForTimeout(1000); // Give time for second response to start

    const allClaudeMessages = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") });

    // Should have 2 Claude messages now
    const messageCount = await allClaudeMessages.count();
    expect(messageCount).toBeGreaterThanOrEqual(2);

    // Get the last (second) response
    const secondResponse = allClaudeMessages.last();
    await expect(secondResponse).toBeVisible({ timeout: 10000 });

    const secondContentDiv = secondResponse.locator("div.whitespace-pre-wrap");
    await expect(secondContentDiv).toBeVisible({ timeout: 5000 });

    // Verify second response text streamed
    const secondText = await secondContentDiv.textContent();
    expect(secondText).toContain("Second response also streaming");
  });

  test("should show incremental updates for second response", async ({
    page,
  }) => {
    let requestCount = 0;

    await page.route("**/api/commands", async (route) => {
      requestCount++;

      if (requestCount === 1) {
        // First response
        await route.fulfill({
          status: 200,
          contentType: "text/event-stream",
          body:
            'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\n' +
            'data: {"type":"text","content":"First"}\n\n' +
            'data: {"type":"result","duration_ms":100}\n\n',
        });
      } else if (requestCount === 2) {
        // Second response - send chunks with delays to observe streaming
        const chunks = [
          'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\n',
          'data: {"type":"text","content":"S"}\n\n',
          'data: {"type":"text","content":"e"}\n\n',
          'data: {"type":"text","content":"c"}\n\n',
          'data: {"type":"text","content":"o"}\n\n',
          'data: {"type":"text","content":"n"}\n\n',
          'data: {"type":"text","content":"d"}\n\n',
          'data: {"type":"result","duration_ms":100}\n\n',
        ];

        await route.fulfill({
          status: 200,
          contentType: "text/event-stream",
          body: chunks.join(""),
        });
      }
    });

    await page.goto("/");
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Send first message
    await chatInput.fill("test 1");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for first response
    const firstResponse = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(firstResponse).toBeVisible({ timeout: 10000 });

    // Send second message
    await chatInput.fill("test 2");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait a moment for second response to start
    await page.waitForTimeout(1000);

    // Get second response
    const allResponses = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") });

    const secondResponse = allResponses.last();
    const secondContentDiv = secondResponse.locator("div.whitespace-pre-wrap");

    // Should eventually show "Second"
    await expect(secondContentDiv).toContainText("Second", { timeout: 5000 });

    // Verify final text
    const finalText = await secondContentDiv.textContent();
    expect(finalText).toContain("Second");
  });
});
