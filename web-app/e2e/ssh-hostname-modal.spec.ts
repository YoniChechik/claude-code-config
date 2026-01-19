import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";

// Helper function to create a complete session mock
function createMockSession(overrides: Record<string, unknown> = {}) {
  return {
    id: "test-session-id",
    cwd: "/home/ubuntu",
    model: "claude-sonnet-4-5-20250929",
    lastDurationMs: 0,
    messages: [],
    createdAt: new Date().toISOString(),
    sessionType: "ssh",
    hostname: "150-136-38-69",
    clientIp: "150.136.38.69",
    audioNotificationsEnabled: false,
    ...overrides,
  };
}

// Helper function to setup common mocks
async function setupBaseMocks(page: Page, sessionOverrides: Record<string, unknown> = {}) {
  const mockSession = createMockSession(sessionOverrides);

  // Mock /api/cwd
  await page.route("**/api/cwd", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ cwd: "/home/ubuntu" }),
    });
  });

  // Mock /api/commands-list
  await page.route("**/api/commands-list", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        commands: [
          { name: "help", source: "builtin" },
          { name: "clear", source: "builtin" },
        ],
      }),
    });
  });

  // Mock session creation and retrieval
  await page.route("**/api/sessions/**", async (route) => {
    if (route.request().method() === "GET") {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          session: mockSession,
        }),
      });
    } else {
      await route.continue();
    }
  });

  await page.route("**/api/sessions", async (route) => {
    if (route.request().method() === "POST") {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          session: mockSession,
        }),
      });
    } else {
      await route.continue();
    }
  });
}

test.describe("SSH Hostname Modal", () => {
  // Remove beforeEach - each test will setup its own mocks before navigation

  test("should show modal when clicking CWD with unmapped SSH session", async ({
    page,
  }) => {
    await setupBaseMocks(page);

    // Mock the SSH host mapping API to return no mapping
    await page.route("**/api/ssh-host-mapping*", async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({ hostname: null }),
        });
      } else {
        await route.continue();
      }
    });

    // Reload to get the mocked session
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Click the CWD button
    const cwdButton = page.locator("button").filter({ hasText: "/home/ubuntu" }).first();
    await cwdButton.click();

    // Wait for the modal to appear
    await page.waitForSelector('h2:has-text("SSH Hostname Configuration")', {
      timeout: 5000,
    });

    // Verify modal is visible with correct content
    await expect(page.locator('h2:has-text("SSH Hostname Configuration")')).toBeVisible();
    await expect(page.locator('text=150.136.38.69')).toBeVisible();
    await expect(page.locator('input[placeholder*="mixtiles"]')).toBeVisible();
  });

  test("should save hostname and open VSCode when user submits", async ({
    page,
  }) => {
    await setupBaseMocks(page, {
      hostname: "192-168-1-50",
      clientIp: "192.168.1.50",
    });

    // Mock the SSH host mapping API
    let savedMapping: { clientIp: string; hostname: string } | null = null;

    await page.route("**/api/ssh-host-mapping*", async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({ hostname: savedMapping?.hostname || null }),
        });
      } else if (route.request().method() === "POST") {
        const postData = route.request().postDataJSON();
        savedMapping = postData;
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({ success: true }),
        });
      } else {
        await route.continue();
      }
    });

    // Reload to get the mocked session
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Track window.open calls
    const openedUrls: string[] = [];
    await page.exposeFunction("trackOpen", (url: string) => {
      openedUrls.push(url);
    });

    // Override window.open to capture URLs
    await page.evaluate(() => {
      window.open = (url: string | URL | undefined) => {
        if (url) {
          (window as any).trackOpen(url.toString());
        }
        return null;
      };
    });

    // Click the CWD button
    const cwdButton = page.locator("button").filter({ hasText: "/home/ubuntu" }).first();
    await cwdButton.click();

    // Wait for the modal to appear
    await page.waitForSelector('h2:has-text("SSH Hostname Configuration")', {
      timeout: 5000,
    });

    // Enter hostname
    const hostnameInput = page.locator('input[placeholder*="mixtiles"]');
    await hostnameInput.fill("my-test-server");

    // Click Save button
    const saveButton = page.locator('button:has-text("Save & Open")');
    await saveButton.click();

    // Wait a bit for the request to complete
    await page.waitForTimeout(500);

    // Verify the mapping was saved
    expect(savedMapping).toEqual({
      clientIp: "192.168.1.50",
      hostname: "my-test-server",
    });

    // Verify VSCode URL was opened
    await page.waitForTimeout(500);
    expect(openedUrls.length).toBe(1);
    expect(openedUrls[0]).toContain("vscode://vscode-remote/ssh-remote+my-test-server");
    expect(openedUrls[0]).toContain("/home/ubuntu");
  });

  test("should close modal when cancel button is clicked", async ({ page }) => {
    await setupBaseMocks(page, {
      hostname: "10-0-0-5",
      clientIp: "10.0.0.5",
    });

    // Mock the SSH host mapping API to return no mapping
    await page.route("**/api/ssh-host-mapping*", async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({ hostname: null }),
        });
      } else {
        await route.continue();
      }
    });

    // Reload to get the mocked session
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Click the CWD button
    const cwdButton = page.locator("button").filter({ hasText: "/home/ubuntu" }).first();
    await cwdButton.click();

    // Wait for the modal to appear
    await page.waitForSelector('h2:has-text("SSH Hostname Configuration")', {
      timeout: 5000,
    });

    // Verify modal is visible
    await expect(page.locator('h2:has-text("SSH Hostname Configuration")')).toBeVisible();

    // Click Cancel button
    const cancelButton = page.locator('button:has-text("Cancel")');
    await cancelButton.click();

    // Wait a bit for the modal to close
    await page.waitForTimeout(300);

    // Modal should not be visible
    const isVisible = await page.locator('h2:has-text("SSH Hostname Configuration")').isVisible().catch(() => false);
    expect(isVisible).toBe(false);
  });

  test("should use saved hostname on subsequent clicks without showing modal", async ({
    page,
  }) => {
    await setupBaseMocks(page, {
      hostname: "172-16-0-10",
      clientIp: "172.16.0.10",
    });

    // Mock the SSH host mapping API to return a saved mapping
    await page.route("**/api/ssh-host-mapping*", async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({ hostname: "saved-server" }),
        });
      } else {
        await route.continue();
      }
    });

    // Reload to get the mocked session
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Track window.open calls
    const openedUrls: string[] = [];
    await page.exposeFunction("trackOpen2", (url: string) => {
      openedUrls.push(url);
    });

    // Override window.open to capture URLs
    await page.evaluate(() => {
      window.open = (url: string | URL | undefined) => {
        if (url) {
          (window as any).trackOpen2(url.toString());
        }
        return null;
      };
    });

    // Click the CWD button
    const cwdButton = page.locator("button").filter({ hasText: "/home/ubuntu" }).first();
    await cwdButton.click();

    // Wait a bit for the request to complete
    await page.waitForTimeout(500);

    // Modal should NOT appear
    const isModalVisible = await page
      .locator('h2:has-text("SSH Hostname Configuration")')
      .isVisible()
      .catch(() => false);
    expect(isModalVisible).toBe(false);

    // Verify VSCode URL was opened with saved hostname
    expect(openedUrls.length).toBe(1);
    expect(openedUrls[0]).toContain("vscode://vscode-remote/ssh-remote+saved-server");
    expect(openedUrls[0]).toContain("/home/ubuntu");
  });

  test("should open VSCode directly for non-SSH sessions without showing modal", async ({
    page,
  }) => {
    await setupBaseMocks(page, {
      sessionType: "local",
    });

    // Reload to get the mocked session
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Track window.open calls
    const openedUrls: string[] = [];
    await page.exposeFunction("trackOpen3", (url: string) => {
      openedUrls.push(url);
    });

    // Override window.open to capture URLs
    await page.evaluate(() => {
      window.open = (url: string | URL | undefined) => {
        if (url) {
          (window as any).trackOpen3(url.toString());
        }
        return null;
      };
    });

    // Click the CWD button
    const cwdButton = page.locator("button").filter({ hasText: "/home/ubuntu" }).first();
    await cwdButton.click();

    // Wait a bit
    await page.waitForTimeout(300);

    // Modal should NOT appear
    const isModalVisible = await page
      .locator('h2:has-text("SSH Hostname Configuration")')
      .isVisible()
      .catch(() => false);
    expect(isModalVisible).toBe(false);

    // Verify VSCode URL was opened with local file protocol
    expect(openedUrls.length).toBe(1);
    expect(openedUrls[0]).toContain("vscode://file/home/ubuntu");
  });
});
