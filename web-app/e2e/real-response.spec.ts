import { test, expect } from "@playwright/test";

test.describe("Real Claude Response", () => {
  test("should send a real prompt and receive actual Claude response", async ({
    page,
  }) => {
    await page.goto("/", { waitUntil: "networkidle" });

    await page.waitForSelector("textarea", {
      timeout: 30000,
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("hi");
    await expect(chatInput).toHaveValue("hi");
    await chatInput.press("Enter");

    await expect(chatInput).toHaveValue("", { timeout: 3000 });
    await expect(leftPane.locator("text=hi")).toBeVisible({ timeout: 5000 });

    await expect(async () => {
      const claudeMessages = leftPane.locator("div.bg-gray-800").filter({
        has: page.locator("text=Claude"),
      });

      const count = await claudeMessages.count();
      expect(count).toBeGreaterThan(0);

      const lastMessage = claudeMessages.last();
      const messageText = await lastMessage.textContent();

      expect(messageText).toBeTruthy();
      const contentWithoutLabel = messageText!.replace(/Claude/g, "").replace(/\d{2}:\d{2}:\d{2}/g, "").trim();
      expect(contentWithoutLabel.length).toBeGreaterThan(0);
    }).toPass({ timeout: 30000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    const responseText = await claudeMessage.textContent();
    const contentOnly = responseText!.replace(/Claude/g, "").replace(/\d{2}:\d{2}:\d{2}/g, "").trim();

    expect(contentOnly.length).toBeGreaterThan(0);

    await page.waitForTimeout(2000);
    await expect(claudeMessage).toBeVisible();

    await expect(chatInput).toHaveValue("");
  });
});
