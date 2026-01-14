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
    const initialEnabled = initialText?.includes("🔊");

    // Click to toggle
    await speakerButton.click();

    // Wait for state to update
    await page.waitForTimeout(500);

    // Verify state changed
    const newText = await speakerButton.textContent();
    const newEnabled = newText?.includes("🔊");

    expect(newEnabled).toBe(!initialEnabled);

    // Click again to toggle back
    await speakerButton.click();
    await page.waitForTimeout(500);

    const finalText = await speakerButton.textContent();
    const finalEnabled = finalText?.includes("🔊");

    expect(finalEnabled).toBe(initialEnabled);
  });

  test("should update tab title when response completes while window unfocused", async ({
    page,
    context,
  }) => {
    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send a message
    await chatInput.fill("hi");
    await sendButton.click();

    // Simulate window blur (losing focus)
    await page.evaluate(() => {
      window.dispatchEvent(new Event("blur"));
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

  test("should clear tab notification when window regains focus", async ({
    page,
  }) => {
    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Get original title
    const originalTitle = await page.title();

    // Send a message while unfocused
    await page.evaluate(() => {
      window.dispatchEvent(new Event("blur"));
    });

    await chatInput.fill("hi");
    await sendButton.click();

    // Wait for response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-100")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    await page.waitForTimeout(3000);

    // Verify title was modified
    const modifiedTitle = await page.title();
    expect(modifiedTitle).toContain("Done");

    // Simulate window focus
    await page.evaluate(() => {
      window.dispatchEvent(new Event("focus"));
    });

    // Wait for title to be restored
    await page.waitForTimeout(500);

    // Title should be restored to original
    const restoredTitle = await page.title();
    expect(restoredTitle).toBe(originalTitle);
    expect(restoredTitle).not.toContain("Done");
  });

  test("should not update tab title when window is focused", async ({
    page,
  }) => {
    await page.goto("/");

    await page.waitForSelector("textarea", { timeout: 10000 });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Get original title
    const originalTitle = await page.title();

    // Ensure window is focused
    await page.evaluate(() => {
      window.dispatchEvent(new Event("focus"));
    });

    // Send a message while focused
    await chatInput.fill("hi");
    await sendButton.click();

    // Wait for response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-100")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    await page.waitForTimeout(3000);

    // Title should NOT be modified
    const currentTitle = await page.title();
    expect(currentTitle).toBe(originalTitle);
    expect(currentTitle).not.toContain("Done");
  });

  test("should persist audio notification preference across page reload", async ({
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
    const initialEnabled = initialText?.includes("🔊");

    // Toggle the setting
    await speakerButton.click();
    await page.waitForTimeout(500);

    // Reload the page
    await page.reload();
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Find speaker button again after reload
    const leftPaneAfterReload = page.locator("main > div > div").first();
    const sessionHeaderAfterReload = leftPaneAfterReload.locator("div").first();
    const speakerButtonAfterReload = sessionHeaderAfterReload.locator(
      'button[title*="audio notifications"]',
    );

    await expect(speakerButtonAfterReload).toBeVisible({ timeout: 5000 });

    // Verify state persisted
    const textAfterReload = await speakerButtonAfterReload.textContent();
    const enabledAfterReload = textAfterReload?.includes("🔊");

    expect(enabledAfterReload).toBe(!initialEnabled);
  });
});
