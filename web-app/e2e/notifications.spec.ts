import { test, expect } from "@playwright/test";

test.describe("Notification Features", () => {
  test("should show speaker toggle button in session header", async ({
    page,
  }) => {
    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const sessionHeader = leftPane.locator("div").first();

    // Speaker toggle button should be visible (either 🔊 or 🔇)
    const speakerButton = sessionHeader.locator(
      'button[title*="audio notifications"]',
    );
    await expect(speakerButton).toBeVisible({ timeout: 5000 });
  });

  test("should toggle audio notifications when speaker button is clicked", async ({
    page,
  }) => {
    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const sessionHeader = leftPane.locator("div").first();

    const speakerButton = sessionHeader.locator(
      'button[title*="audio notifications"]',
    );
    await expect(speakerButton).toBeVisible({ timeout: 5000 });

    // Get initial state
    const initialText = await speakerButton.textContent();
    const initialEnabled = initialText?.includes("Audio On");

    // Click to toggle
    await speakerButton.click();

    // Wait for state to update
    await page.waitForTimeout(500);

    // Verify state changed
    const newText = await speakerButton.textContent();
    const newEnabled = newText?.includes("Audio On");

    expect(newEnabled).toBe(!initialEnabled);

    // Click again to toggle back
    await speakerButton.click();
    await page.waitForTimeout(500);

    const finalText = await speakerButton.textContent();
    const finalEnabled = finalText?.includes("Audio On");

    expect(finalEnabled).toBe(initialEnabled);
  });

  test("should update tab title when response completes while window unfocused", async ({
    page,
    context,
  }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Response for notification test"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message
    await chatInput.fill("hi");
    await chatInput.press("Enter");

    // Simulate tab losing focus (hiding the page)
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => true,
      });
      document.dispatchEvent(new Event("visibilitychange"));
    });

    // Wait for response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-100")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Wait a bit for streaming to complete
    await page.waitForTimeout(3000);

    // Check if title was updated to include "Done"
    const title = await page.title();
    expect(title).toContain("Done");
  });
});
