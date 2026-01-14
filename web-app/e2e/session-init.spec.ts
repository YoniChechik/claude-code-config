import { test, expect } from "@playwright/test";

test.describe("Session Initialization", () => {
  test("should move past 'Initializing sessions...' and load chat interface", async ({
    page,
  }) => {
    // Navigate to the app
    await page.goto("/");

    // Check if we see the loading state
    const loadingText = page.locator("text=Initializing sessions...");

    // If loading state is visible, it should disappear quickly
    // If it's not visible, that's fine - it means initialization was instant
    const isLoadingVisible = await loadingText.isVisible().catch(() => false);

    if (isLoadingVisible) {
      // Wait for the loading state to disappear (should happen within 5 seconds)
      await expect(loadingText).not.toBeVisible({ timeout: 5000 });
    }

    // Verify that the chat interface becomes available
    // The textarea should appear, indicating successful initialization
    const textarea = page.locator("textarea");
    await expect(textarea).toBeVisible({ timeout: 10000 });

    // Verify the "Initializing sessions..." text is no longer visible
    await expect(loadingText).not.toBeVisible();

    // Verify the textarea has the expected placeholder
    await expect(textarea).toHaveAttribute(
      "placeholder",
      "Type your message or /command...",
    );
  });

  test("should not remain stuck on initialization screen for more than 10 seconds", async ({
    page,
  }) => {
    await page.goto("/");

    // This test should fail if the app is stuck on "Initializing sessions..."
    // Wait for textarea to appear within 10 seconds maximum
    const textarea = page.locator("textarea");

    await expect(textarea).toBeVisible({ timeout: 10000 });

    // Double-check that we're not seeing the loading state anymore
    const loadingText = page.locator("text=Initializing sessions...");
    await expect(loadingText).not.toBeVisible();
  });

  test("should display error message if initialization fails", async ({
    page,
  }) => {
    // This test verifies that if initialization fails, we get an error message
    // rather than being stuck in the loading state forever

    await page.goto("/");

    // Wait for either the chat interface OR an error message to appear
    // (within reasonable time - 15 seconds)
    const chatInterface = page.locator("textarea");
    const errorMessage = page.locator("text=/Error:/");

    // At least one of these should appear within 15 seconds
    await Promise.race([
      expect(chatInterface).toBeVisible({ timeout: 15000 }),
      expect(errorMessage).toBeVisible({ timeout: 15000 }),
    ]);

    // Verify we're not stuck on "Initializing sessions..."
    const loadingText = page.locator("text=Initializing sessions...");
    const isStillLoading = await loadingText.isVisible().catch(() => false);

    // If we see an error, that's acceptable - just verify we're not stuck loading
    const hasError = await errorMessage.isVisible().catch(() => false);

    if (!hasError) {
      // No error, so chat interface should be visible
      await expect(chatInterface).toBeVisible();
    }

    // Either way, we should not be stuck on loading screen
    expect(isStillLoading).toBe(false);
  });
});
