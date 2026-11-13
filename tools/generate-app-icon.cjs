#!/usr/bin/env node
// Regenerate committed resources on macOS. Install @resvg/resvg-js@2.6.2 in a
// temporary prefix and set NODE_PATH to its node_modules (see assets/README.md).
const { Resvg } = require('@resvg/resvg-js');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const catalog = path.join(root, 'App/Resources/Assets.xcassets');
const appicon = path.join(catalog, 'AppIcon.appiconset');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'open-icon-'));
const iconset = path.join(temp, 'Open.iconset');
try {
  fs.mkdirSync(appicon, { recursive: true });
  fs.mkdirSync(iconset);
  const svg = fs.readFileSync(path.join(root, 'assets/icon.svg'));
  const images = [];
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const filename = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
      const png = new Resvg(svg, { fitTo: { mode: 'width', value: size * scale } }).render().asPng();
      fs.writeFileSync(path.join(appicon, filename), png);
      fs.writeFileSync(path.join(iconset, filename), png);
      images.push({ idiom: 'mac', size: `${size}x${size}`, scale: `${scale}x`, filename });
    }
  }
  const info = { author: 'xcode', version: 1 };
  fs.writeFileSync(path.join(catalog, 'Contents.json'), JSON.stringify({ info }, null, 2) + '\n');
  fs.writeFileSync(path.join(appicon, 'Contents.json'), JSON.stringify({ images, info }, null, 2) + '\n');
  execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.join(root, 'App/Resources/Open.icns')], { stdio: 'inherit' });
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
