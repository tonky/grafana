import { expect, test } from '@playwright/test';
import { existsSync, readdirSync, realpathSync } from 'node:fs';
import { join } from 'node:path';

test('playwright launches headless chromium from the store and renders DOM', async ({ page }) => {
  const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH;
  expect(browsersPath).toBeTruthy();
  const resolvedPath = realpathSync(browsersPath!);
  expect(browsersPath!.startsWith('/nix/store/') || resolvedPath.includes('/enve/store/')).toBe(true);

  const headlessDirectories = readdirSync(browsersPath!).filter((entry) =>
    entry.startsWith('chromium_headless_shell-')
  );
  expect(headlessDirectories.length).toBeGreaterThan(0);
  for (const directory of headlessDirectories) {
    expect(existsSync(join(browsersPath!, directory, 'INSTALLATION_COMPLETE'))).toBe(true);
  }

  await page.setContent('<main id="grafana-browser-probe">store-browser-ok</main>');
  await expect(page.locator('#grafana-browser-probe')).toHaveText('store-browser-ok');
});
