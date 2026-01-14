import { test } from "@playwright/test";

test("debug page load", async ({ page }) => {
  // Listen to all requests
  page.on('request', request => console.log('REQUEST:', request.url()));
  page.on('response', response => console.log('RESPONSE:', response.status(), response.url()));
  page.on('console', msg => console.log('PAGE LOG:', msg.text()));
  page.on('pageerror', error => console.log('PAGE ERROR:', error.message));

  // Navigate
  console.log('Navigating to /...');
  await page.goto("/");

  // Wait a bit
  await page.waitForTimeout(5000);

  // Get visible text
  const text = await page.locator('body').textContent();
  console.log('Page text (first 200 chars):', text?.substring(0, 200));
});
