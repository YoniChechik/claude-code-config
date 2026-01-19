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
});
