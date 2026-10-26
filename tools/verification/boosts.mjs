// Real headless Chrome flows, following the temporary puppeteer-core shot.mjs approach.
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const origin = process.argv[2];
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: 'new',
  args: ['--window-size=1280,900', '--no-first-run', '--disable-background-networking'],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.setRequestInterception(true);
  page.on('request', request => {
    if (request.url().startsWith(`${origin}/`) || request.url().startsWith('data:')) request.continue();
    else request.abort();
  });
  const cdp = await page.createCDPSession();

  // Chrome's DOM protocol can inspect the closed overlay for verification. Page JS
  // cannot reach it. This harness does not claim isolated-world/native authority.
  async function overlayNodes(selector) {
    const { root } = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
    function find(node) {
      if (node.attributes?.includes('open-zap-overlay-host')) return node;
      for (const child of [...(node.children || []), ...(node.shadowRoots || [])]) {
        const result = find(child);
        if (result) return result;
      }
    }
    const host = find(root);
    assert.ok(host?.shadowRoots?.[0], 'closed picker overlay exists');
    const { nodeIds } = await cdp.send('DOM.querySelectorAll', { nodeId: host.shadowRoots[0].nodeId, selector });
    const results = [];
    for (const nodeId of nodeIds) {
      const { object } = await cdp.send('DOM.resolveNode', { nodeId });
      const { result } = await cdp.send('Runtime.callFunctionOn', {
        objectId: object.objectId,
        functionDeclaration: `function() {
          const r = this.getBoundingClientRect(), s = getComputedStyle(this);
          return { x:r.x, y:r.y, width:r.width, height:r.height,
            display:s.display, border:s.borderColor, background:s.backgroundColor, text:this.textContent };
        }`,
        returnByValue: true,
      });
      results.push(result.value);
      await cdp.send('Runtime.releaseObject', { objectId: object.objectId });
    }
    return results;
  }
  async function rectangle(selector) {
    return page.$eval(selector, element => {
      const r = element.getBoundingClientRect();
      return { x:r.x, y:r.y, width:r.width, height:r.height };
    });
  }
  const near = (a, b) => Math.abs(a - b) < 2;
  const aligned = (a, b) => ['x', 'y', 'width', 'height'].every(key => near(a[key], b[key]));
  const settle = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  async function fresh() {
    const response = await page.goto(`${origin}/Harness/static.html`, { waitUntil: 'load' });
    assert.equal(response.status(), 200);
    await page.waitForFunction(() => window.__openBoosts?.version === 1 && window.__openZap?.version === 1);
  }

  await fresh();
  await page.click('#enter-zap');
  const banner = await rectangle('#promo-banner');
  await page.mouse.move(banner.x + banner.width / 2, banner.y + banner.height / 2, { steps: 5 });
  await settle();
  const [highlight] = await overlayNodes('.hl');
  assert.ok(aligned(highlight, banner), 'A7 highlight covers the banner');
  assert.equal(highlight.border, 'rgb(76, 141, 255)', 'A7 blue outline');
  assert.notEqual(highlight.background, 'rgba(0, 0, 0, 0)', 'A7 visible tint');
  await page.screenshot({ path: 'a7-hover.png' });
  await page.mouse.click(banner.x + banner.width / 2, banner.y + banner.height / 2);
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
  const commit = await page.evaluate(() => window.__harness.messages.find(message => message.type === 'zap:committed')?.payload);
  assert.equal(commit?.selector, '#promo-banner');
  assert.equal(commit.matches, 1);
  assert.equal(await page.evaluate(() => window.__openZap.isActive()), true);
  assert.deepEqual(await page.evaluate(() => window.__harness.errors), []);
  console.log('A7 PASS: banner highlight, commit, hide, and active picker');

  await fresh();
  await page.click('#enter-zap');
  const article = await rectangle('article.post');
  await page.mouse.move(article.x + article.width / 2, article.y + 12, { steps: 5 });
  await page.mouse.click(article.x + article.width / 2, article.y + 12);
  await page.waitForFunction(() => window.__harness.messages.some(message => message.type === 'zap:committed'));
  const [related] = await overlayNodes('.related');
  assert.match(related.text, /Zap all related \(3\)/);
  assert.ok(related.width > 0 && related.height > 0);
  await page.mouse.move(related.x + related.width / 2, related.y + related.height / 2, { steps: 3 });
  await settle();
  const boxes = await overlayNodes('.hl-multi');
  assert.equal(boxes.length, 2, 'A11 previews only the two still-visible articles');
  const second = await rectangle('[data-testid="post-2"]');
  const third = await rectangle('[data-testid="post-3"]');
  assert.ok(boxes.some(box => aligned(box, second)) && boxes.some(box => aligned(box, third)));
  await page.screenshot({ path: 'a11-related.png' });
  await page.mouse.click(related.x + related.width / 2, related.y + related.height / 2);
  await page.waitForFunction(() => [...document.querySelectorAll('article.post')].every(element => getComputedStyle(element).display === 'none'));
  const replacement = await page.evaluate(() => window.__harness.messages.find(message => message.type === 'zap:replaced')?.payload);
  assert.equal(replacement?.matches, 3);
  assert.deepEqual(await page.evaluate(() => window.__harness.errors), []);
  assert.deepEqual(errors, []);
  console.log('A11 PASS: precise pick, two related previews, replacement, and three hidden posts');
  console.log('boosts: 2/2 passed');
} finally {
  await browser.close();
}
