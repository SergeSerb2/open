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
  page.on('pageerror', error => { errors.push(error.message); console.error(error.stack); });
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
            display:s.display, zIndex:s.zIndex, border:s.borderColor, borderWidth:s.borderTopWidth, radius:s.borderRadius, font:s.fontSize, background:s.backgroundColor, text:this.textContent };
        }`,
        returnByValue: true,
      });
      results.push(result.value);
      await cdp.send('Runtime.releaseObject', { objectId: object.objectId });
    }
    return results;
  }
  async function clickOverlay(selector) {
    const [target] = await overlayNodes(selector);
    assert.ok(target?.width > 0 && target.height > 0, `${selector} is visible`);
    await page.mouse.click(target.x + target.width / 2, target.y + target.height / 2);
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

  for (const fixture of ['loader', 'static', 'spa', 'shadow-dom', 'obfuscated', 'large']) {
    const response = await page.goto(`${origin}/Harness/${fixture}.html`, { waitUntil: 'load' });
    assert.equal(response.status(), 200);
    await page.waitForFunction(() => window.__openBoosts?.version === 1 && window.__openZap?.version === 1);
    if (fixture === 'spa') {
      await page.click('#fixture-F1');
      await page.click('#go-view-b');
      await page.waitForSelector('#view-b-marker');
      await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
      await page.click('#reset-head');
      await page.waitForSelector('#view-a-marker');
      await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
    }
    assert.deepEqual(await page.evaluate(() => window.__harness.errors), []);
    assert.deepEqual(errors, [], `${fixture} has no script errors`);
  }
  console.log('H0 PASS: all six harness pages load both runtimes without script errors');
  await fresh();
  await page.click('#enter-zap');
  const banner = await rectangle('#promo-banner');
  await page.mouse.move(banner.x + banner.width / 2, banner.y + banner.height / 2, { steps: 5 });
  await settle();
  const [highlight] = await overlayNodes('.hl');
  assert.ok(aligned(highlight, banner), 'A7 highlight covers the banner');
  assert.equal(highlight.background, 'rgba(255, 214, 10, 0.35)', 'A7 yellow hover tint');
  assert.notEqual(highlight.background, 'rgba(0, 0, 0, 0)', 'A7 visible tint');
  await page.screenshot({ path: 'a7-hover.png' });
  await page.mouse.click(banner.x + banner.width / 2, banner.y + banner.height / 2);
  const [bar] = await overlayNodes('.bar'), [done] = await overlayNodes('.done'), [frame] = await overlayNodes('.content-frame');
  assert.equal(bar.height, 56); assert.equal(bar.width, 1280); assert.equal(bar.background, 'rgb(251, 251, 253)');
  assert.equal(done.text, 'Done'); assert.equal(done.width, 59); assert.equal(done.height, 38);
  assert.equal(frame.border, 'rgb(49, 57, 255)'); assert.equal(frame.borderWidth, '3px');
  assert.equal(done.radius, '8px'); assert.equal(done.font, '13px');
  assert.equal((await overlayNodes('.instruction'))[0].text, 'Click elements on the page to Zap them');
  assert.equal((await overlayNodes('.accent'))[0].text, 'Zap');
  const [popup] = await overlayNodes('.popup');
  assert.equal(popup.width, 428); assert.equal(popup.height, 90); assert.equal(popup.radius, '12px'); assert.equal(popup.zIndex, '3');
  assert.equal((await overlayNodes('.band'))[0].font, '11px');
  assert.equal((await overlayNodes('.this'))[0].text, 'Zap this');
  assert.equal((await overlayNodes('.related'))[0].text, 'Zap all related elements');
  assert.equal((await overlayNodes('.cancel'))[0].text, 'Cancel');
  assert.match((await overlayNodes('.band'))[0].text, /^1 #promo-banner$/);
  assert.equal(await page.evaluate(() => window.__harness.messages.filter(m => m.type === 'zap:committed').length), 0, 'opening popup commits nothing');
  await clickOverlay('.this');
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
  const commit = await page.evaluate(() => window.__harness.messages.find(message => message.type === 'zap:committed')?.payload);
  assert.equal(commit?.selector, '#promo-banner');
  assert.equal(commit.matches, 1);
  assert.equal(await page.evaluate(() => window.__openZap.isActive()), true);
  assert.deepEqual(await page.evaluate(() => window.__harness.errors), []);
  console.log('A7 PASS: yellow hover, content frame, bar, Done, popup actions/count, explicit commit, hide, and active picker');
  assert.equal((await overlayNodes('.popup'))[0].display, 'none', 'precise choice closes card');
  const [reveal] = await overlayNodes('.reveal');
  assert.equal(reveal.text, 'div#promo-banner');
  assert.match((await overlayNodes('.reveals'))[0].text, /Click to reveal/);
  await page.mouse.move(reveal.x + reveal.width / 2, reveal.y + reveal.height / 2);
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display !== 'none');
  await page.mouse.move(1100, 70);
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
  await clickOverlay('.reveal');
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display !== 'none');
  const revealRequest = await page.evaluate(() => window.__harness.messages.find(m => m.type === 'zap:revealRequested'));
  assert.equal(revealRequest.payload.selector, '#promo-banner');
  assert.ok(revealRequest.payload.sessionNonce.length >= 16);
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0);
  await clickOverlay('.done');
  assert.equal(await page.evaluate(() => window.__openZap.isActive()), false);
  assert.equal(await page.evaluate(() => window.__harness.messages.at(-1).payload.reason), 'done');
  console.log('R1 PASS: labeled reveal chip previews, restores hiding on leave, requests native removal, and Done exits');

  await fresh();
  await page.click('#enter-zap');
  const article = await rectangle('article.post');
  const pickArticle = () => page.mouse.click(article.x + article.width / 2, article.y + 12);
  const undo = async () => { await page.keyboard.down('Meta'); await page.keyboard.press('z'); await page.keyboard.up('Meta'); };
  const mutationTypes = () => page.evaluate(() => window.__harness.messages.filter(m => /^zap:(committed|replaced|removed)$/.test(m.type)).map(m => m.type));
  const hiddenPosts = () => page.evaluate(() => [...document.querySelectorAll('article.post')].filter(e => getComputedStyle(e).display === 'none').length);
  await pickArticle();
  await clickOverlay('.cancel');
  assert.equal((await overlayNodes('.popup'))[0].display, 'none', 'Cancel closes card');
  await undo();
  assert.deepEqual(await mutationTypes(), [], 'Cancel commits nothing and creates no undo');
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0, 'Cancel leaves store empty');
  assert.equal(await hiddenPosts(), 0, 'Cancel hides no posts');
  await pickArticle();
  await clickOverlay('.this');
  assert.equal((await overlayNodes('.popup'))[0].display, 'none', 'A11 precise choice closes card');
  assert.deepEqual(await mutationTypes(), ['zap:committed'], 'precise choice commits once');
  const precise = await page.evaluate(() => window.__harness.messages.find(m => m.type === 'zap:committed').payload);
  assert.equal(precise.matches, 1, 'precise choice has one match');
  assert.equal(await hiddenPosts(), 1, 'precise choice hides only one post');
  await undo();
  assert.equal(await hiddenPosts(), 0, 'one undo restores the precise post');
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0);
  assert.deepEqual(await mutationTypes(), ['zap:committed', 'zap:removed']);
  await undo();
  assert.deepEqual(await mutationTypes(), ['zap:committed', 'zap:removed'], 'precise choice creates one undo step');
  await fresh();
  await page.click('#enter-zap');
  await pickArticle();
  const [related] = await overlayNodes('.related');
  assert.equal(related.text, 'Zap all related elements');
  assert.ok(related.width > 0 && related.height > 0);
  await page.mouse.move(related.x + related.width / 2, related.y + related.height / 2, { steps: 3 });
  await settle();
  assert.match((await overlayNodes('.band'))[0].text, /^3 /, 'related count lives in popup band');
  const boxes = await overlayNodes('.hl-multi');
  assert.ok(boxes.every(box => box.zIndex === '0'), 'related tint stays below popup');
  assert.equal(boxes.length, 3, 'A11 previews all three articles before commit');
  for (const selector of ['[data-testid="post-1"]', '[data-testid="post-2"]', '[data-testid="post-3"]']) {
    const expected = await rectangle(selector);
    assert.ok(boxes.some(box => aligned(box, expected)), `related preview covers ${selector}`);
  }
  assert.deepEqual(await mutationTypes(), [], 'related preview commits nothing');
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0, 'related preview leaves store empty');
  await page.screenshot({ path: 'a11-related.png' });
  await page.mouse.click(related.x + related.width / 2, related.y + related.height / 2);
  await page.waitForFunction(() => [...document.querySelectorAll('article.post')].every(element => getComputedStyle(element).display === 'none'));
  const direct = await page.evaluate(() => window.__harness.messages.find(message => message.type === 'zap:committed')?.payload);
  assert.equal(direct?.matches, 3, 'related choice commits all three matches directly');
  assert.deepEqual(await mutationTypes(), ['zap:committed'], 'related choice sends one direct commit and no replacement');
  assert.deepEqual(await page.evaluate(() => [...window.__harness.persistedZaps]), [direct.selector], 'related choice stores one selector');
  assert.equal((await overlayNodes('.popup'))[0].display, 'none', 'related choice closes card');
  await undo();
  assert.equal(await hiddenPosts(), 0, 'one undo restores all related posts');
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0, 'one undo removes the related selector');
  assert.deepEqual(await mutationTypes(), ['zap:committed', 'zap:removed']);
  await undo();
  assert.deepEqual(await mutationTypes(), ['zap:committed', 'zap:removed'], 'related choice creates one undo step');
  assert.deepEqual(await page.evaluate(() => window.__harness.errors), []);
  assert.deepEqual(errors, []);
  console.log('A11 PASS: Cancel is empty; precise and related choices close, commit once, and undo once; three related previews and hidden posts');
  await fresh();
  await page.evaluate(() => {
    window.__harness.armed = { boostID: 'harness-boost', sessionNonce: crypto.randomUUID() };
    send('zap:enter', { ...window.__harness.armed, mode: 'select' });
  });
  const selectBanner = await rectangle('#promo-banner');
  await page.mouse.move(selectBanner.x + 10, selectBanner.y + 10);
  await settle();
  assert.equal((await overlayNodes('.hl'))[0].background, 'rgba(255, 214, 10, 0.35)');
  await page.mouse.click(selectBanner.x + 10, selectBanner.y + 10);
  // Pick Selector uses Arc's copy labels (BO-20) on the same two buttons; Zap actions stay out.
  assert.equal((await overlayNodes('.this'))[0].text, 'Copy selector for this');
  assert.equal((await overlayNodes('.related'))[0].text, 'Copy selector for related');
  assert.equal((await overlayNodes('.select')).length, 0);
  await clickOverlay('.cancel');
  assert.equal(await page.evaluate(() => window.__harness.messages.filter(m => m.type === 'picker:selected').length), 0);
  await page.mouse.click(selectBanner.x + 10, selectBanner.y + 10);
  await clickOverlay('.this');
  assert.equal((await overlayNodes('.popup'))[0].display, 'none', 'Copy selector for this closes card');
  const selection = await page.evaluate(() => window.__harness.messages.find(m => m.type === 'picker:selected'));
  assert.equal(selection.v, 1);
  assert.deepEqual(Object.keys(selection.payload).sort(), ['boostID', 'matches', 'selector', 'sessionNonce']);
  assert.equal(selection.payload.selector, '#promo-banner'); assert.equal(selection.payload.matches, 1);
  assert.equal(selection.payload.boostID, 'harness-boost');
  assert.ok(selection.payload.sessionNonce.length >= 16);
  await page.keyboard.down('Meta'); await page.keyboard.press('z'); await page.keyboard.up('Meta');
  assert.deepEqual(await page.evaluate(() => ({
    commits: window.__harness.messages.filter(m => /^zap:(committed|replaced|removed)$/.test(m.type)).length,
    stored: window.__harness.persistedZaps.size,
    previewStyles: document.querySelectorAll('#open-zap-preview-style').length,
    hidden: getComputedStyle(document.querySelector('#promo-banner')).display === 'none',
  })), { commits: 0, stored: 0, previewStyles: 0, hidden: false });
  await page.keyboard.press('Escape');
  assert.equal(await page.evaluate(() => window.__openZap.isActive()), false);
  assert.equal(await page.evaluate(() => window.__harness.messages.at(-1).payload.reason), 'esc');
  console.log('S1 PASS: select frame/tint, copy labels, Cancel, authenticated selection, no commit/hide/store/undo, Escape');
  await fresh();
  await page.click('#fixture-F1');
  await page.click('#enter-zap');
  await page.evaluate(() => {
    window.__harness.persistedZaps.add('#promo-banner');
    send('zap:list', { ...window.__harness.armed, selectors: ['#promo-banner'], labels: { '#promo-banner': 'Saved promotion' } });
  });
  const [savedChip] = await overlayNodes('.reveal');
  assert.equal(savedChip.text, 'Saved promotion', 'persisted reveal chip uses native store label');
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('#promo-banner')).display), 'none');
  await page.mouse.move(savedChip.x + savedChip.width / 2, savedChip.y + savedChip.height / 2);
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display !== 'none');
  await page.mouse.move(1100, 70);
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display === 'none');
  await clickOverlay('.reveal');
  await page.waitForFunction(() => getComputedStyle(document.querySelector('#promo-banner')).display !== 'none');
  assert.equal(await page.evaluate(() => window.__harness.persistedZaps.size), 0);
  assert.equal(await page.evaluate(() => window.__harness.messages.filter(m => m.type === 'zap:committed').length), 0);
  console.log('R2 PASS: persisted label, hover preview/re-hide, and reveal without a new commit');
  assert.deepEqual(errors, []);
  console.log('boosts: 6/6 passed');
} finally {
  await browser.close();
}
