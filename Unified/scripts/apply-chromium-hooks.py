#!/usr/bin/env python3
# Copyright 2026 The Open Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Applies Open Unified's hooks to a Chromium 156.0.8078.48 checkout.

Every hook is anchored on code context (a function signature, a statement,
a GN list), never on line numbers, and every inserted block is wrapped in

    // open_unified hook <id> begin
    ...
    // open_unified hook <id> end

so a second run finds the block and replaces it in place: the tool is
idempotent and also updates hooks whose text changed. Unmodified upstream
patches (Engine/fork/patches/chromium/*.patch that are pure Chromium) are
applied with `git apply` after a reverse check.

Usage:
  apply-chromium-hooks.py --src ~/open-unified-chromium/src           # apply
  apply-chromium-hooks.py --src ... --check                           # dry run
  apply-chromium-hooks.py --src ... --only 0003,0005                  # subset
  apply-chromium-hooks.py --src ... --export-patches Unified/patches/chromium
  apply-chromium-hooks.py --pristine-root DIR --export-patches OUT    # no git

--export-patches writes one clean unified diff per logical patch
(0001-...patch .. 0009-...patch) computed in memory from the pristine files
(`git show HEAD:<path>` in --src, or --pristine-root), plus `series`. The
series applies in order with `git apply` on an unmodified checkout.

Exit status: 0 on success, 1 when an anchor is missing or a patch does not
apply (nothing is written for a file whose hook failed), 2 on usage errors.
"""

import argparse
import difflib
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))
ENGINE_PATCHES = os.path.join(REPO_ROOT, 'Engine', 'fork', 'patches', 'chromium')
HOOKS_HEADER = 'open_unified/browser/open_chromium_hooks.h'
CHROMIUM_VERSION = '156.0.8078.48'


class HookError(Exception):
  pass


# ---------------------------------------------------------------------------
# Source scanning helpers
# ---------------------------------------------------------------------------

def comment_prefix(path: str) -> str:
  if path.endswith(('.gn', '.gni', '.spec', '.py')) or os.path.basename(
      path) in ('DEPS',):
    return '#'
  return '//'


def marker_lines(path: str, hook_id: str, indent: str):
  prefix = comment_prefix(path)
  return (f'{indent}{prefix} open_unified hook {hook_id} begin',
          f'{indent}{prefix} open_unified hook {hook_id} end')


def block_regex(path: str, hook_id: str):
  prefix = re.escape(comment_prefix(path))
  hid = re.escape(hook_id)
  return re.compile(
      rf'^[ \t]*{prefix} open_unified hook {hid} begin\n.*?'
      rf'^[ \t]*{prefix} open_unified hook {hid} end\n', re.S | re.M)


def code_mask(text: str) -> str:
  """Returns |text| with comments and string/char literals blanked out
  (same length), so brace and paren matching ignores them."""
  out = list(text)
  i, n = 0, len(text)
  while i < n:
    c = text[i]
    if text.startswith('//', i):
      j = text.find('\n', i)
      j = n if j < 0 else j
      for k in range(i, j):
        out[k] = ' '
      i = j
    elif text.startswith('/*', i):
      j = text.find('*/', i + 2)
      j = n if j < 0 else j + 2
      for k in range(i, j):
        if out[k] != '\n':
          out[k] = ' '
      i = j
    elif text.startswith('R"', i):
      m = re.match(r'R"([^(\s]{0,16})\(', text[i:])
      if not m:
        i += 1
        continue
      end = ')' + m.group(1) + '"'
      j = text.find(end, i + m.end())
      j = n if j < 0 else j + len(end)
      for k in range(i, j):
        if out[k] != '\n':
          out[k] = ' '
      i = j
    elif c in '"\'':
      j = i + 1
      while j < n and text[j] != c and text[j] != '\n':
        j += 2 if text[j] == '\\' else 1
      for k in range(i, min(j + 1, n)):
        out[k] = ' '
      i = j + 1
    else:
      i += 1
  return ''.join(out)


def match_close(masked: str, open_index: int, open_ch: str, close_ch: str):
  depth = 0
  for i in range(open_index, len(masked)):
    ch = masked[i]
    if ch == open_ch:
      depth += 1
    elif ch == close_ch:
      depth -= 1
      if depth == 0:
        return i
  raise HookError(f'unbalanced {open_ch}{close_ch}')


def line_start(text: str, index: int) -> int:
  return text.rfind('\n', 0, index) + 1


def line_end(text: str, index: int) -> int:
  j = text.find('\n', index)
  return len(text) if j < 0 else j + 1


def find_regex(text: str, pattern: str, start: int = 0, what: str = ''):
  m = re.compile(pattern, re.M).search(text, start)
  if not m:
    raise HookError(f'anchor not found: {what or pattern}')
  return m


def function_span(text: str, signature: str):
  """(params_text, body_open_index, body_close_index) of the function whose
  definition starts at regex |signature|."""
  m = find_regex(text, signature, what=signature)
  masked = code_mask(text)
  paren = masked.find('(', m.start())
  if paren < 0:
    raise HookError(f'no parameter list after {signature}')
  paren_close = match_close(masked, paren, '(', ')')
  brace = masked.find('{', paren_close)
  semicolon = masked.find(';', paren_close)
  if brace < 0 or (0 <= semicolon < brace):
    raise HookError(f'{signature} is a declaration, not a definition')
  brace_close = match_close(masked, brace, '{', '}')
  return text[paren + 1:paren_close], brace, brace_close


def resolve_params(template: str, params: Dict[str, str], params_text: str):
  """Replaces ${name} with the parameter name whose declaration matches the
  regex params[name] (one capture group: the name)."""
  values = {}
  for name, pattern in params.items():
    m = re.search(pattern, params_text)
    if not m:
      raise HookError(f'parameter {name} ({pattern}) not in signature')
    values[name] = m.group(1)

  def sub(m):
    key = m.group(1)
    if key not in values:
      raise HookError(f'unresolved placeholder ${{{key}}}')
    return values[key]

  return re.sub(r'\$\{(\w+)\}', sub, template)


def ensure_newline(text: str) -> str:
  return text if text.endswith('\n') else text + '\n'


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

@dataclass
class Op:
  """One edit of one file. |apply| returns the new text."""
  path: str
  hook_id: str
  describe: str
  fn: Callable[[str, 'Op'], str]
  # For patch-file ops: absolute patch path (fn unused).
  patch_file: Optional[str] = None
  create: bool = False

  def apply(self, text: str) -> str:
    return self.fn(text, self)


def _insert_block(text: str, op: Op, index: int, code: str, indent: str):
  """Inserts a marked block at |index| (a line start), replacing an
  existing block with the same id anywhere in the file."""
  if indent is None:
    first = next((l for l in code.split('\n') if l.strip()), '')
    indent = first[:len(first) - len(first.lstrip())]
  begin, end = marker_lines(op.path, op.hook_id, indent)
  block = f'{begin}\n{ensure_newline(code)}{end}\n'
  existing = block_regex(op.path, op.hook_id).search(text)
  if existing:
    return text[:existing.start()] + block + text[existing.end():]
  return text[:index] + block + text[index:]


def _strip_existing(text: str, op: Op) -> str:
  """Text with this op's block removed (anchors are searched without it)."""
  return block_regex(op.path, op.hook_id).sub('', text)


def op_include(path, hook_id, header, nogncheck=True, condition=None):
  """#include "header" after the last top-level #include."""

  def fn(text, op):
    if re.search(rf'^#include "{re.escape(header)}"', text, re.M) and \
        not block_regex(op.path, op.hook_id).search(text):
      return text  # Already included by upstream code.
    base = _strip_existing(text, op)
    depth, best, best_depth = 0, None, None
    lines = base.split('\n')
    offset = 0
    positions = []
    for line in lines:
      stripped = line.strip()
      if re.match(r'#\s*if', stripped):
        depth += 1
      elif re.match(r'#\s*endif', stripped):
        depth -= 1
      elif stripped.startswith('#include'):
        positions.append((offset + len(line) + 1, depth))
      offset += len(line) + 1
    if not positions:
      raise HookError('no #include in file')
    min_depth = min(d for _, d in positions)
    candidates = [(p, d) for p, d in positions if d == min_depth]
    best = candidates[-1][0]
    # base/win/windows_h_disallowed.h must stay the last include.
    last_line = base[line_start(base, best - 1):best]
    if 'windows_h_disallowed.h' in last_line:
      best = line_start(base, best - 1)
    line = f'#include "{header}"' + ('  // nogncheck' if nogncheck else '')
    if condition:
      line = f'#if {condition}\n{line}\n#endif'
    if block_regex(op.path, op.hook_id).search(text):
      return _insert_block(text, op, 0, line, '')
    return _insert_block(base, op, min(best, len(base)), line, '')

  return Op(path, hook_id, f'include {header}', fn)


def op_function_start(path, hook_id, signature, code, params=None,
                      indent=None):
  """Code at the start of a function body."""

  def fn(text, op):
    base = _strip_existing(text, op)
    params_text, brace, _ = function_span(base, signature)
    body = resolve_params(code, params or {}, params_text)
    index = line_end(base, brace)
    return _insert_block(base, op, index, body, indent)

  return Op(path, hook_id, f'start of {signature}', fn)


def op_function_end(path, hook_id, signature, code, params=None,
                    indent=None):
  """Code before the closing brace of a function body."""

  def fn(text, op):
    base = _strip_existing(text, op)
    params_text, _, brace_close = function_span(base, signature)
    body = resolve_params(code, params or {}, params_text)
    index = line_start(base, brace_close)
    return _insert_block(base, op, index, body, indent)

  return Op(path, hook_id, f'end of {signature}', fn)


def op_after_line(path, hook_id, anchor, code, within=None, indent=None):
  """Code after the first line matching |anchor| (after |within| if set)."""

  def fn(text, op):
    base = _strip_existing(text, op)
    start = find_regex(base, within, what=within).end() if within else 0
    m = find_regex(base, anchor, start, what=anchor)
    return _insert_block(base, op, line_end(base, m.end() - 1), code, indent)

  return Op(path, hook_id, f'after {anchor}', fn)


def op_before_line(path, hook_id, anchor, code, within=None, indent=None):
  """Code before the first line matching |anchor| (after |within|)."""

  def fn(text, op):
    base = _strip_existing(text, op)
    start = find_regex(base, within, what=within).end() if within else 0
    m = find_regex(base, anchor, start, what=anchor)
    return _insert_block(base, op, line_start(base, m.start()), code, indent)

  return Op(path, hook_id, f'before {anchor}', fn)


def op_after_block(path, hook_id, anchor, code, open_ch='{', close_ch='}',
                   within=None, indent=None):
  """Code after the block ({...} or [...]) that opens on the line matching
  |anchor| (C++ statements, GN lists)."""

  def fn(text, op):
    base = _strip_existing(text, op)
    start = find_regex(base, within, what=within).end() if within else 0
    m = find_regex(base, anchor, start, what=anchor)
    masked = code_mask(base) if comment_prefix(path) == '//' else \
        re.sub(r'#[^\n]*', lambda x: ' ' * len(x.group(0)), base)
    opening = masked.find(open_ch, m.start())
    if opening < 0:
      raise HookError(f'no {open_ch} after {anchor}')
    closing = match_close(masked, opening, open_ch, close_ch)
    return _insert_block(base, op, line_end(base, closing), code, indent)

  return Op(path, hook_id, f'after block {anchor}', fn)


def op_replace(path, hook_id, old, new):
  """Literal replacement (for code that cannot carry markers, e.g. enum
  values or BRANDING). Idempotent: done when |new| is present and |old| is
  not."""

  def fn(text, op):
    if new in text and (old not in text or old in new):
      return text
    if old not in text:
      raise HookError(f'text not found: {old[:60]!r}')
    return text.replace(old, new, 1)

  return Op(path, hook_id, f'replace {old.splitlines()[0][:50]!r}', fn)


def op_create(path, hook_id, content):
  """A new file owned by Open (fully rewritten on every run)."""

  def fn(text, op):
    return ensure_newline(content)

  return Op(path, hook_id, f'create {path}', fn, create=True)


def op_patch_file(name, hook_id):
  """An unmodified Engine patch that is pure Chromium."""
  path = os.path.join(ENGINE_PATCHES, name)
  return Op(path='', hook_id=hook_id, describe=f'git apply {name}',
            fn=lambda t, o: t, patch_file=path)


# ---------------------------------------------------------------------------
# The nine logical patches (Unified/patches/chromium/series)
# ---------------------------------------------------------------------------

CCBC = 'chrome/browser/chrome_content_browser_client.cc'
OPEN_PRODUCT_LINUX = 'open'
OPEN_PRODUCT_WIN = 'Open'
# macOS keeps a separate directory until the unified app replaces the
# AppKit/CEF Open (its data root is ~/Library/Application Support/Open).
OPEN_PRODUCT_MAC = 'Open Unified'


@dataclass
class Patch:
  number: str
  name: str
  summary: str
  ops: List[Op] = field(default_factory=list)

  @property
  def file_name(self):
    return f'{self.number}-{self.name}.patch'


def build_patches() -> List[Patch]:
  p = []

  # 0001 ------------------------------------------------------------------
  p.append(Patch('0001', 'open-unified-build-integration',
                 'Link //open_unified into //chrome:dependencies, pack the '
                 'open:// WebUI pak, reserve its GRIT resource ids', [
      op_after_line('chrome/BUILD.gn', '0001-gni',
                    r'^import\("//v8/gni/v8\.gni"\)\n',
                    'import("//open_unified/open_unified.gni")'),
      op_after_block('chrome/BUILD.gn', '0001-dependencies',
                     r'^  public_deps = \[', within=r'^group\("dependencies"\) \{',
                     open_ch='[', close_ch=']', code=(
          '  if (open_unified_browser) {\n'
          '    public_deps += [ "//open_unified" ]\n'
          '  }')),
      op_after_line('chrome/chrome_paks.gni', '0001-gni',
                    r'^import\("//chrome/common/features\.gni"\)\n',
                    'import("//open_unified/open_unified.gni")'),
      op_before_line('chrome/chrome_paks.gni', '0001-paks',
                     r'^    if \(defined\(invoker\.deps\)\) \{',
                     within=r'^template\("chrome_extra_paks"\)', code=(
          '    if (open_unified_browser) {\n'
          '      sources +=\n'
          '          [ "$root_gen_dir/open_unified/open_webui_resources.pak" ]\n'
          '      deps += [ "//open_unified:open_unified_resources" ]\n'
          '    }')),
      op_before_line('tools/gritsettings/resource_ids.spec',
                     '0001-resource-ids',
                     r'^  # END "everything else" section\.', code=(
          '  "open_unified/ui/webui/resources/open_webui_resources.grd": {\n'
          '    "META": {"sizes": {"includes": [1000]}},\n'
          '    "includes": [12820],\n'
          '  },\n')),
  ]))

  # 0002 ------------------------------------------------------------------
  bv = 'chrome/browser/ui/views/frame/browser_view.cc'
  bw = 'chrome/browser/ui/views/frame/browser_widget.cc'
  bvl = 'chrome/browser/ui/views/frame/layout/browser_view_layout_impl.cc'
  p.append(Patch('0002', 'open-browser-view-hook',
                 'OpenBrowserView in BrowserView/BrowserWidget: install, '
                 'uninstall, frameless rounded widget', [
      op_include(bv, '0002-include', HOOKS_HEADER),
      op_function_end(bv, '0002-added-to-widget',
                      r'^void BrowserView::AddedToWidget\(\) \{',
                      '  open_unified::hooks::OnBrowserViewAddedToWidget(this);'),
      op_function_start(bv, '0002-destroying', r'^BrowserView::~BrowserView\(\)',
                        '  open_unified::hooks::OnBrowserViewDestroying(this);'),
      op_include(bw, '0002-include', HOOKS_HEADER),
      op_after_line(bw, '0002-widget-params',
                    r'^  params\.delegate = browser_view_;\n',
                    within=r'^void BrowserWidget::InitBrowserWidget\(\) \{',
                    code='  open_unified::hooks::AdjustBrowserWidgetParams('
                         'browser_view_, &params);'),
      op_include(bvl, '0002-include', HOOKS_HEADER),
      op_function_start(
          bvl, '0002-layout',
          r'^void BrowserViewLayoutImpl::Layout\(views::View\* host\)',
          '  // OpenBrowserView covers the whole client area when installed.\n'
          '  if (open_unified::hooks::LayoutOpenBrowserView(${host})) {\n'
          '    return;\n'
          '  }',
          params={'host': r'views::View\*\s+(\w+)'}),
  ]))

  # 0003 ------------------------------------------------------------------
  rb = 'chrome/browser/chrome_content_browser_client_receiver_bindings.cc'
  rc = 'chrome/renderer/chrome_content_renderer_client.cc'
  p.append(Patch('0003', 'open-adblock-hooks',
                 '//open/adblock: URLLoaderFactory proxy, WebSocket and '
                 'WebTransport checks, cosmetics interface, renderer agent '
                 '(world 7), context-scoped renderer cache clear', [
      op_include(CCBC, '0003-include', HOOKS_HEADER),
      op_function_start(
          CCBC, '0003-url-loader-factory',
          r'^void ChromeContentBrowserClient::WillCreateURLLoaderFactory\(',
          '  open_unified::hooks::MaybeProxyURLLoaderFactoryForAdBlock(\n'
          '      ${context}, ${frame}, ${process}, ${type}, ${initiator},\n'
          '      ${isolation}, ${builder});',
          params={
              'context': r'content::BrowserContext\*\s+(\w+)',
              'frame': r'content::RenderFrameHost\*\s+(\w+)',
              'process': r'int\s+(\w+)',
              'type': r'URLLoaderFactoryType\s+(\w+)',
              'initiator': r'const url::Origin&\s+(\w+)',
              'isolation': r'const net::IsolationInfo&\s+(\w+)',
              'builder': r'network::URLLoaderFactoryBuilder&\s+(\w+)',
          }),
      op_function_start(
          CCBC, '0003-intercept-websocket',
          r'^bool ChromeContentBrowserClient::WillInterceptWebSocket\(',
          '  if (open_unified::hooks::WillInterceptWebSocket(${frame})) {\n'
          '    return true;\n'
          '  }',
          params={'frame': r'content::RenderFrameHost\*\s+(\w+)'}),
      op_function_start(
          CCBC, '0003-create-websocket',
          r'^void ChromeContentBrowserClient::CreateWebSocket\(',
          '  if (open_unified::hooks::InterceptCreateWebSocket(\n'
          '          this, ${frame}, ${factory}, ${url}, ${site}, ${ua},\n'
          '          ${client}, ${options})) {\n'
          '    return;\n'
          '  }',
          params={
              'frame': r'content::RenderFrameHost\*\s+(\w+)',
              'factory': r'WebSocketFactory\s+(\w+)',
              'url': r'const GURL&\s+(\w+)',
              'site': r'const net::SiteForCookies&\s+(\w+)',
              'ua': r'const std::optional<std::string>&\s+(\w+)',
              'client': r'WebSocketHandshakeClient>\s+(\w+)',
              'options': r'WebSocketOptions\s+(\w+)\s*$',
          }),
      op_function_start(
          CCBC, '0003-web-transport',
          r'^void ChromeContentBrowserClient::WillCreateWebTransport\(',
          '  if (open_unified::hooks::InterceptWillCreateWebTransport(\n'
          '          this, ${process}, ${routing}, ${url}, ${initiator},\n'
          '          ${client}, ${callback})) {\n'
          '    return;\n'
          '  }',
          params={
              'process': r'int\s+(\w+),',
              'routing': r'int\s+\w+,\s*int\s+(\w+)',
              'url': r'const GURL&\s+(\w+)',
              'initiator': r'const url::Origin&\s+(\w+)',
              'client': r'WebTransportHandshakeClient>\s+(\w+)',
              'callback': r'WillCreateWebTransportCallback\s+(\w+)',
          }),
      op_include(rb, '0003-include', HOOKS_HEADER),
      op_function_start(
          rb, '0003-expose-interfaces',
          r'^void ChromeContentBrowserClient::ExposeInterfacesToRenderer\(',
          '  open_unified::hooks::ExposeInterfacesToRenderer(${registry}, '
          '${host});',
          params={
              'registry': r'service_manager::BinderRegistry\*\s+(\w+)',
              'host': r'content::RenderProcessHost\*\s+(\w+)',
          }),
      op_include(rc, '0003-include',
                 'open/adblock/renderer/open_adblock_renderer_agent.h'),
      op_function_start(
          rc, '0003-renderer-agent',
          r'^void ChromeContentRendererClient::RenderFrameCreated\(',
          '  // Deletes itself with the frame (content::RenderFrameObserver).\n'
          '  new open_engine::OpenAdBlockRendererAgent(${frame});',
          params={'frame': r'content::RenderFrame\*\s+(\w+)'}),
      op_patch_file('0903-open-adblock-context-cache.patch', '0003-cache'),
  ]))

  # 0004 ------------------------------------------------------------------
  worlds = 'chrome/common/chrome_isolated_world_ids.h'
  p.append(Patch('0004', 'open-isolated-worlds',
                 'Open world 6 (Boosts, Zap) and ad-block cosmetics world 7 '
                 'on every platform; extensions start at 8', [
      op_replace(worlds, '0004-worlds',
                 '  ISOLATED_WORLD_ID_EXTENSIONS\n};',
                 '  // Open Unified: Boosts/Zap world and the private ad-block\n'
                 '  // cosmetics world, below the extension range on every\n'
                 '  // platform (//open/adblock asserts 7).\n'
                 '  ISOLATED_WORLD_ID_OPEN = 6,\n'
                 '  ISOLATED_WORLD_ID_OPEN_ADBLOCK_RESERVED = 7,\n'
                 '  ISOLATED_WORLD_ID_EXTENSIONS = 8\n};'),
      op_after_line(worlds, '0004-assert',
                    r'^// LINT\.ThenChange\(//chrome/android/java/src/org/'
                    r'chromium/chrome/browser/common/ChromeIsolatedWorldIds'
                    r'\.java\)\n',
                    code=('static_assert(ISOLATED_WORLD_ID_CHROME_INTERNAL <\n'
                          '                  ISOLATED_WORLD_ID_OPEN,\n'
                          '              "Chrome worlds overlap Open\'s");')),
  ]))

  # 0005 ------------------------------------------------------------------
  configs = 'chrome/browser/ui/webui/chrome_web_ui_configs.cc'
  client = 'chrome/common/chrome_content_client.cc'
  p.append(Patch('0005', 'open-webui-scheme',
                 'open:// as a standard secure scheme, rewritten to '
                 'chrome://open-<host> WebUI; register the seven hosts', [
      op_include(configs, '0005-include', HOOKS_HEADER),
      op_after_line(configs, '0005-configs',
                    r'^  auto& map = content::WebUIConfigMap::GetInstance\(\);'
                    r'\n', within=r'^void RegisterChromeWebUIConfigs\(\) \{',
                    code='  open_unified::hooks::RegisterOpenWebUIConfigs();'),
      op_function_start(
          CCBC, '0005-url-handler',
          r'^void ChromeContentBrowserClient::BrowserURLHandlerCreated\(',
          '  open_unified::hooks::AddOpenURLHandlers(${handler});',
          params={'handler': r'BrowserURLHandler\*\s+(\w+)'}),
      op_function_start(
          client, '0005-scheme',
          r'^void ChromeContentClient::AddAdditionalSchemes\(',
          '  // open://settings and friends (shown as open://, served as\n'
          '  // chrome://open-<host> WebUI by //open_unified).\n'
          '  ${schemes}->standard_schemes.push_back("open");\n'
          '  ${schemes}->secure_schemes.push_back("open");',
          params={'schemes': r'Schemes\*\s+(\w+)'}),
  ]))

  # 0006 ------------------------------------------------------------------
  tlu = 'chrome/browser/resource_coordinator/tab_lifecycle_unit.cc'
  p.append(Patch('0006', 'open-tab-lifecycle',
                 "Chromium's discards (Memory Saver, memory pressure, "
                 "chrome.tabs.discard) ask Open's sleep policy first", [
      op_include(tlu, '0006-include', HOOKS_HEADER),
      op_after_block(tlu, '0006-may-discard',
                     r'^  if \(IsDiscardBlockedByFeature\(reason\)\) \{',
                     within=r'^bool TabLifecycleUnitSource::TabLifecycleUnit::'
                     r'Discard\(',
                     code=('  if (!open_unified::hooks::MayChromeDiscardTab('
                           'web_contents())) {\n'
                           '    return false;\n'
                           '  }')),
  ]))

  # 0007 ------------------------------------------------------------------
  p.append(Patch('0007', 'open-media-volume-pip',
                 'Per-tab volume multiplier and per-player PiP availability '
                 '(MediaSessionImpl), exposed as a content public API', [
      op_patch_file('0401-open-media-session.patch', '0007-media-session'),
      op_create('content/public/browser/open_media_controls.h',
                '0007-api-header', OPEN_MEDIA_CONTROLS_H),
      op_create('content/browser/media/session/open_media_controls.cc',
                '0007-api-impl', OPEN_MEDIA_CONTROLS_CC),
      op_after_line('content/public/browser/BUILD.gn', '0007-api-gn',
                    r'^    "web_contents\.h",\n',
                    code='    "open_media_controls.h",'),
      op_after_line('content/browser/BUILD.gn', '0007-impl-gn',
                    r'^    "media/session/media_session_impl\.cc",\n',
                    code='    "media/session/open_media_controls.cc",'),
  ]))

  # 0008 ------------------------------------------------------------------
  branding = 'chrome/app/theme/chromium/BRANDING'
  p.append(Patch('0008', 'open-widevine-branding',
                 'Widevine only with --open-enable-widevine; Open product '
                 'names and user-data directories', [
      op_patch_file('0012-open-widevine-opt-in.patch', '0008-widevine'),
      op_replace(branding, '0008-branding',
                 'COMPANY_FULLNAME=The Chromium Authors\n'
                 'COMPANY_SHORTNAME=The Chromium Authors\n'
                 'PRODUCT_FULLNAME=Chromium\n'
                 'PRODUCT_SHORTNAME=Chromium\n'
                 'PRODUCT_INSTALLER_FULLNAME=Chromium Installer\n'
                 'PRODUCT_INSTALLER_SHORTNAME=Chromium Installer\n'
                 'COPYRIGHT=Copyright @LASTCHANGE_YEAR@ The Chromium Authors. '
                 'All rights reserved.\n'
                 'MAC_BUNDLE_ID=org.chromium.Chromium\n',
                 'COMPANY_FULLNAME=The Open Authors\n'
                 'COMPANY_SHORTNAME=Open\n'
                 'PRODUCT_FULLNAME=Open\n'
                 'PRODUCT_SHORTNAME=Open\n'
                 'PRODUCT_INSTALLER_FULLNAME=Open Installer\n'
                 'PRODUCT_INSTALLER_SHORTNAME=Open Installer\n'
                 'COPYRIGHT=Copyright @LASTCHANGE_YEAR@ The Open Authors. '
                 'All rights reserved. Portions copyright The Chromium '
                 'Authors.\n'
                 'MAC_BUNDLE_ID=org.openbrowser.unified\n'),
      op_replace('chrome/common/chrome_paths_linux.cc', '0008-linux-dir',
                 '  std::string data_dir_basename = "chromium";',
                 f'  std::string data_dir_basename = "{OPEN_PRODUCT_LINUX}";'),
      op_replace('chrome/common/chrome_paths_mac.mm', '0008-mac-dir',
                 '      product_dir_name = "Chromium";',
                 f'      product_dir_name = "{OPEN_PRODUCT_MAC}";'),
      op_replace('chrome/install_static/chromium_install_modes.h',
                 '0008-win-dir',
                 'inline constexpr wchar_t kProductPathName[] = L"Chromium";',
                 'inline constexpr wchar_t kProductPathName[] = '
                 f'L"{OPEN_PRODUCT_WIN}";'),
  ]))

  # 0009 ------------------------------------------------------------------
  main = 'chrome/browser/chrome_browser_main.cc'
  p.append(Patch('0009', 'open-browser-service-startup',
                 'OpenBrowserMainExtraParts: OpenBrowserService (state, '
                 'windows, sleep) and OpenAutomationServer start with the '
                 'browser', [
      op_include(main, '0009-include', HOOKS_HEADER),
      op_before_line(main, '0009-extra-parts', r'^  return main_parts;\n',
                     within=r'ChromeBrowserMainExtraPartsSegmentationPlatform',
                     code=('  open_unified::hooks::AddBrowserMainExtraParts('
                           'main_parts.get());')),
  ]))
  return p


OPEN_MEDIA_CONTROLS_H = '''\
// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Generated by Unified/scripts/apply-chromium-hooks.py (hook 0007).

#ifndef CONTENT_PUBLIC_BROWSER_OPEN_MEDIA_CONTROLS_H_
#define CONTENT_PUBLIC_BROWSER_OPEN_MEDIA_CONTROLS_H_

#include "content/common/content_export.h"

namespace content {

class WebContents;

// Scales the audio of every player in |web_contents| (0..1; 1 = unchanged).
// Open's Site Control volume and tab mute-on-sleep use it.
CONTENT_EXPORT void SetOpenTabVolumeMultiplier(WebContents* web_contents,
                                               double multiplier);
CONTENT_EXPORT double GetOpenTabVolumeMultiplier(WebContents* web_contents);

}  // namespace content

#endif  // CONTENT_PUBLIC_BROWSER_OPEN_MEDIA_CONTROLS_H_
'''

OPEN_MEDIA_CONTROLS_CC = '''\
// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Generated by Unified/scripts/apply-chromium-hooks.py (hook 0007).

#include "content/public/browser/open_media_controls.h"

#include <algorithm>
#include <cmath>

#include "content/browser/media/session/media_session_impl.h"
#include "content/public/browser/web_contents.h"

namespace content {

void SetOpenTabVolumeMultiplier(WebContents* web_contents, double multiplier) {
  if (!web_contents || !std::isfinite(multiplier)) {
    return;
  }
  MediaSessionImpl::Get(web_contents)
      ->SetOpenVolumeMultiplier(std::clamp(multiplier, 0.0, 1.0));
}

double GetOpenTabVolumeMultiplier(WebContents* web_contents) {
  return web_contents
             ? MediaSessionImpl::Get(web_contents)->open_volume_multiplier()
             : 1.0;
}

}  // namespace content
'''


# ---------------------------------------------------------------------------
# File access
# ---------------------------------------------------------------------------

class Tree:
  """Reads current files from --src; pristine ones from --pristine-root or
  `git show HEAD:<path>`."""

  def __init__(self, src: Optional[str], pristine_root: Optional[str]):
    self.src = src
    self.pristine_root = pristine_root

  def read(self, path: str) -> Optional[str]:
    full = os.path.join(self.src, path)
    if not os.path.exists(full):
      return None
    with open(full, encoding='utf-8', newline='') as f:
      return f.read()

  def write(self, path: str, text: str):
    full = os.path.join(self.src, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w', encoding='utf-8', newline='') as f:
      f.write(text)

  def read_pristine(self, path: str) -> Optional[str]:
    if self.pristine_root:
      full = os.path.join(self.pristine_root, path)
      if not os.path.exists(full):
        return None
      with open(full, encoding='utf-8', newline='') as f:
        return f.read()
    try:
      return subprocess.run(['git', '-C', self.src, 'show', f'HEAD:{path}'],
                            check=True, capture_output=True,
                            text=True).stdout
    except subprocess.CalledProcessError:
      return None

  def is_git(self) -> bool:
    return bool(self.src) and subprocess.run(
        ['git', '-C', self.src, 'rev-parse', '--git-dir'],
        capture_output=True).returncode == 0


def patch_state(tree: Tree, patch_file: str) -> str:
  """'applied', 'applicable' or 'conflict' for an Engine patch in --src."""
  if tree.is_git():
    def git(*args):
      return subprocess.run(['git', '-C', tree.src, 'apply', *args,
                             patch_file], capture_output=True).returncode
    if git('--check', '--reverse') == 0:
      return 'applied'
    return 'applicable' if git('--check') == 0 else 'conflict'

  def patch(*args):
    return subprocess.run(['patch', '-p1', '--dry-run', '-s', '-f', *args,
                           '-d', tree.src, '-i', patch_file],
                          capture_output=True).returncode
  if patch('-R') == 0:
    return 'applied'
  return 'applicable' if patch('-N') == 0 else 'conflict'


def apply_patch_file(tree: Tree, patch_file: str):
  if tree.is_git():
    subprocess.run(['git', '-C', tree.src, 'apply', patch_file], check=True)
  else:
    subprocess.run(['patch', '-p1', '-s', '-N', '-d', tree.src, '-i',
                    patch_file], check=True)


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

def run_apply(patches: List[Patch], tree: Tree, check: bool) -> int:
  failures = 0
  for patch in patches:
    print(f'== {patch.file_name}: {patch.summary}')
    pending: Dict[str, str] = {}
    patch_failed = False
    for op in patch.ops:
      if op.patch_file:
        state = patch_state(tree, op.patch_file)
        if state == 'conflict':
          print(f'   FAIL  {op.hook_id}: {op.describe} does not apply')
          patch_failed = True
          continue
        if state == 'applicable' and not check:
          apply_patch_file(tree, op.patch_file)
          state = 'applied now'
        print(f'   ok    {op.hook_id}: {op.describe} ({state})')
        continue
      current = pending.get(op.path)
      if current is None:
        current = tree.read(op.path)
      if current is None and not op.create:
        print(f'   FAIL  {op.hook_id}: {op.path} does not exist')
        patch_failed = True
        continue
      try:
        updated = op.apply(current or '')
      except HookError as e:
        print(f'   FAIL  {op.hook_id}: {op.path}: {e}')
        patch_failed = True
        continue
      status = 'unchanged' if updated == current else (
          'would change' if check else 'to write')
      print(f'   ok    {op.hook_id}: {op.path}: {op.describe} [{status}]')
      pending[op.path] = updated
    if patch_failed:
      failures += 1
      print(f'   {patch.file_name}: not written (fix the anchors above)')
      continue
    if not check:
      written = 0
      for path, text in pending.items():
        if tree.read(path) != text:
          tree.write(path, text)
          written += 1
      print(f'   {patch.file_name}: {written} file(s) written')
  return 1 if failures else 0


def unified_diff(path: str, before: Optional[str], after: str) -> str:
  a = (before or '').splitlines(keepends=True)
  b = after.splitlines(keepends=True)
  if a == b:
    return ''
  header = [f'diff --git a/{path} b/{path}\n']
  if before is None:
    header.append('new file mode 100644\n')
  lines = list(difflib.unified_diff(
      a, b, fromfile='/dev/null' if before is None else f'a/{path}',
      tofile=f'b/{path}', n=3))
  out = []
  for line in lines:
    out.append(line)
    if not line.endswith('\n'):
      out.append('\n\\ No newline at end of file\n')
  return ''.join(header + out)


def run_export(patches: List[Patch], tree: Tree, out_dir: str) -> int:
  os.makedirs(out_dir, exist_ok=True)
  state: Dict[str, Optional[str]] = {}
  patched_by_file: Dict[str, str] = {}
  series = [
      f'# Open Unified hooks for Chromium {CHROMIUM_VERSION}. Apply order.',
      '# Generated by Unified/scripts/apply-chromium-hooks.py '
      '--export-patches; edit the hook table there, not these files.',
  ]
  for patch in patches:
    chunks = []
    start_of_patch: Dict[str, Optional[str]] = {}
    for op in patch.ops:
      if op.patch_file:
        with open(op.patch_file, encoding='utf-8') as f:
          text = f.read()
        for path in re.findall(r'^\+\+\+ b/(\S+)', text, re.M):
          patched_by_file[path] = op.patch_file
        chunks.append(text if text.endswith('\n') else text + '\n')
        continue
      if op.path in patched_by_file:
        print(f'FAIL {op.hook_id}: {op.path} is also changed by '
              f'{os.path.basename(patched_by_file[op.path])}')
        return 1
      if op.path not in state:
        state[op.path] = tree.read_pristine(op.path)
        if state[op.path] is None and not op.create:
          print(f'FAIL {op.hook_id}: no pristine {op.path}')
          return 1
      start_of_patch.setdefault(op.path, state[op.path])
      try:
        state[op.path] = op.apply(state[op.path] or '')
      except HookError as e:
        print(f'FAIL {op.hook_id}: {op.path}: {e}')
        return 1
    for path, start in start_of_patch.items():
      chunks.append(unified_diff(path, start, state[path]))
    body = ''.join(c for c in chunks if c)
    with open(os.path.join(out_dir, patch.file_name), 'w',
              encoding='utf-8') as f:
      f.write(f'From: Open Unified <noreply@open.invalid>\n'
              f'Subject: [PATCH {patch.number}] {patch.summary}\n\n'
              f'Generated by Unified/scripts/apply-chromium-hooks.py for '
              f'Chromium {CHROMIUM_VERSION}.\n---\n{body}')
    series.append(f'{patch.file_name}  # {patch.summary}')
    print(f'wrote {patch.file_name} ({body.count(chr(10))} lines)')
  with open(os.path.join(out_dir, 'series'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(series) + '\n')
  return 0


def main(argv) -> int:
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--src', help='Chromium src directory')
  parser.add_argument('--check', action='store_true',
                      help='report what would change; write nothing')
  parser.add_argument('--only', help='comma-separated patch numbers')
  parser.add_argument('--export-patches', metavar='DIR',
                      help='write the clean patch series to DIR')
  parser.add_argument('--pristine-root', metavar='DIR',
                      help='unmodified Chromium files (instead of git HEAD)')
  parser.add_argument('--list', action='store_true', help='list the hooks')
  args = parser.parse_args(argv)

  patches = build_patches()
  if args.only:
    wanted = {n.strip().zfill(4) for n in args.only.split(',')}
    patches = [p for p in patches if p.number in wanted]
  if args.list:
    for patch in patches:
      print(f'{patch.file_name}: {patch.summary}')
      for op in patch.ops:
        print(f'    {op.hook_id:28} {op.path or "-":60} {op.describe}')
    return 0
  if args.export_patches:
    if not (args.src or args.pristine_root):
      parser.error('--export-patches needs --src or --pristine-root')
    return run_export(patches, Tree(args.src, args.pristine_root),
                      args.export_patches)
  if not args.src:
    parser.error('--src is required')
  if not os.path.isdir(args.src):
    parser.error(f'{args.src} is not a directory')
  return run_apply(patches, Tree(args.src, args.pristine_root), args.check)


if __name__ == '__main__':
  sys.exit(main(sys.argv[1:]))
