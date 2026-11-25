#!/usr/bin/env node
// Generates Chromium GRIT resource definition (dist/open_webui_resources.grd)
// for bundling all built open:// WebUI pages and assets into open_webui_resources.pak.

import { readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, posix, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = fileURLToPath(new URL('..', import.meta.url));
const distDir = join(rootDir, 'dist');
const grdFile = 'open_webui_resources.grd';
const grdPath = join(distDir, grdFile);

/** @param {string} dir @returns {string[]} */
function walk(dir) {
  const results = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      results.push(...walk(full));
    } else {
      const rel = relative(distDir, full).split(sep).join(posix.sep);
      if (rel !== grdFile) {
        results.push(rel);
      }
    }
  }
  return results.sort();
}

/** @param {string} relPath @returns {string} */
function toResourceId(relPath) {
  const normalized = relPath
    .replace(/[^a-zA-Z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toUpperCase();
  return `IDR_OPEN_WEBUI_${normalized}`;
}

/** @param {string} str @returns {string} */
function xmlEscape(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

const files = walk(distDir);
const usedIds = new Set();
const includeLines = files.map((relPath) => {
  let id = toResourceId(relPath);
  let suffix = 2;
  while (usedIds.has(id)) {
    id = `${toResourceId(relPath)}_${suffix++}`;
  }
  usedIds.add(id);
  const esc = xmlEscape(relPath);
  return `      <include name="${id}" file="${esc}" resource_path="${esc}" use_base_dir="true" type="BINDATA" />`;
});

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<grit latest_public_release="0" current_release="1">
  <outputs>
    <output filename="grit/open_webui_resources.h" type="rc_header">
      <emit emit_type='prepend'></emit>
    </output>
    <output filename="grit/open_webui_resources_map.cc" type="resource_file_map_source" />
    <output filename="grit/open_webui_resources_map.h" type="resource_map_header" />
    <output filename="open_webui_resources.pak" type="data_package" />
  </outputs>
  <release seq="1">
    <includes>
${includeLines.join('\n')}
    </includes>
  </release>
</grit>
`;

writeFileSync(grdPath, xml, 'utf8');
console.log(`Generated ${grdPath} with ${files.length} resource entries.`);
