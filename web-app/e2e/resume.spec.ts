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
});
