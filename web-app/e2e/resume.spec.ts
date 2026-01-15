import { test, expect } from "@playwright/test";

test.describe("Resume button", () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to the app
    await page.goto("http://localhost:6379");

    // Wait for the chat input to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should open SessionPicker modal when resume button is clicked", async ({
    page,
  }) => {
    // Wait for page to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Find the resume button (📂 icon) in the session header
    const resumeButton = page.locator('button[title="Resume a previous session"]');

    // Verify button is visible
    await expect(resumeButton).toBeVisible();

    // Click the resume button
    await resumeButton.click();

    // Wait for the modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Verify modal is visible
    const modal = page.locator('[data-testid="session-picker-modal"]');
    await expect(modal).toBeVisible();

    // Verify header text
    const header = page.locator('[data-testid="session-picker-header"]');
    await expect(header).toHaveText("Resume Session");
  });

  test("should close modal when cancel is clicked from resume button flow", async ({
    page,
  }) => {
    // Wait for page to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Find and click the resume button
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Verify modal is visible
    const modal = page.locator('[data-testid="session-picker-modal"]');
    await expect(modal).toBeVisible();

    // Click Cancel button
    const cancelButton = page.locator('[data-testid="cancel-button"]');
    await cancelButton.click();

    // Modal should close
    await page.waitForTimeout(300);

    // Modal should not be visible
    const isVisible = await modal.isVisible().catch(() => false);
    expect(isVisible).toBe(false);
  });

  test("should list saved sessions in the modal", async ({ page }) => {
    // Send a message to create a session
    const textarea = page.locator("textarea");
    await textarea.fill("Test message for session listing");
    await textarea.press("Enter");

    // Wait for response to complete
    await page.waitForTimeout(2000);

    // Open the resume modal
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Wait for sessions to load (loading state should disappear)
    await page.waitForFunction(
      () => {
        const loadingText = document.querySelector(
          '[data-testid="session-picker-modal"] :text("Loading sessions...")'
        );
        return !loadingText;
      },
      { timeout: 10000 }
    );

    // Check if sessions are displayed
    const sessionItems = page.locator('[data-testid="session-item"]');
    const sessionCount = await sessionItems.count();

    // Should have at least one session (the one we just created)
    expect(sessionCount).toBeGreaterThan(0);

    // Verify session items have expected content
    const firstSession = sessionItems.first();
    await expect(firstSession).toBeVisible();

    // Session should have a cwd displayed
    const cwdText = await firstSession.locator(".font-mono.text-sm").textContent();
    expect(cwdText).toBeTruthy();
  });

  test("should resume a session when clicking on it", async ({ page }) => {
    // Create a session with a distinct message
    const distinctMessage = `Distinct test message ${Date.now()}`;
    const textarea = page.locator("textarea");
    await textarea.fill(distinctMessage);
    await textarea.press("Enter");

    // Wait for response
    await page.waitForTimeout(2000);

    // Start a new session by reloading
    await page.goto("http://localhost:6379");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Open the resume modal
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal and sessions to load
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });
    await page.waitForFunction(
      () => {
        const loadingText = document.querySelector(
          '[data-testid="session-picker-modal"] :text("Loading sessions...")'
        );
        return !loadingText;
      },
      { timeout: 10000 }
    );

    // Find and click the first session
    const firstSession = page.locator('[data-testid="session-item"]').first();
    await expect(firstSession).toBeVisible();
    await firstSession.click();

    // Modal should close
    await page.waitForTimeout(500);
    const modal = page.locator('[data-testid="session-picker-modal"]');
    const isVisible = await modal.isVisible().catch(() => false);
    expect(isVisible).toBe(false);

    // The session should be loaded - check for message history
    // Wait for the chat container to load with messages
    await page.waitForTimeout(1000);

    // Verify the message appears in the chat history
    const messageLocator = page.getByText(distinctMessage, { exact: false });
    await expect(messageLocator).toBeVisible({ timeout: 5000 });
  });
});
