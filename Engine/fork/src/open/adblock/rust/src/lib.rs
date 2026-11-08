// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

//! CXX bridge over the vendored Brave `adblock` crate (MPL-2.0), the only
//! Rust Open writes by hand (docs/plans/adblock-fork.md §5). C++ sees one
//! opaque engine, flat structs, one enum, strings and string vectors.
//!
//! Chromium builds Rust with `-Cpanic=abort`, so a panic here ends the
//! browser process, and `catch_unwind` cannot help; neither can it catch an
//! allocation failure. Crate calls that return a `Result` can still panic or
//! allocate without bound on hostile input: guard every known case before
//! the call (the DAT walk below, reviews 98-3 and R2-1) and fuzz the rest
//! (docs/followups.md). This file indexes nothing it has not checked.
//!
//! Nothing here builds CSS text (§8.3): cosmetic results are sanitized hide
//! selectors, and the renderer makes one rule per selector. The crate's
//! `:style()`, `:remove*()` and scriptlet output never crosses the bridge in
//! v1; the shim discards it and counts it (lead ruling 6, review R2-2).

use std::collections::{BTreeSet, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;

/// Bumped on any change to `ParseOptions`, permissions, crate or regex
/// features, or bridge semantics: a cached DAT from another format is never
/// loaded (§5.5, review 100-1(a)).
const SHIM_VERSION: u32 = 3;
/// The adblock crate's features (third_party/rust/adblock/v0_8/BUILD.gn).
const CRATE_FEATURES: &str = "embedded-domain-resolver,full-regex-handling,resource-assembler";
/// The regex crate's features (the adblock-v0_8 crate patch, review 97-1).
const REGEX_FEATURES: &str =
    "perf-backtrack,perf-cache,perf-dfa,perf-inline,perf-onepass,std,unicode";

/// §8.3: the longest selector that crosses the bridge.
const MAX_SELECTOR: usize = 2048;
/// §8.3: selector text per frame payload.
const PAYLOAD_CAP: usize = 256 * 1024;

/// Review R3-2: the most list lines one build parses (all lists together;
/// today's EasyList + EasyPrivacy have 132,043). At 2^21 lines the largest
/// `Vec<NetworkFilter>` stays at or under 2^22 × 208 B = 872 MB after
/// doubling, under PartitionAlloc's ceiling. A 16 MiB list (the Swift
/// per-source cap) of 5,592,405 two-character rules aborted the browser.
const MAX_LIST_LINES: usize = 1 << 21;
/// Review R3-2: the most bytes of selector copies one build may cost. The
/// crate stores a cosmetic rule's selector once per hostname it names, so a
/// line costs (hostnames × selector bytes); today's EasyList + EasyPrivacy
/// cost 596,174 bytes in all. One 149 KB line with 10,000 hostnames cost
/// 478 MiB.
const MAX_COSMETIC_COPY_BYTES: u64 = 64 << 20;

/// The crate's DAT header: magic, then format version 0
/// (`data_format/mod.rs`). One MessagePack value follows.
const DAT_MAGIC: [u8; 4] = [0xd1, 0xd9, 0x3a, 0xaf];
/// Reviews R2-1 and R3-1: the most MessagePack values a DAT may hold.
/// Today's EasyList + EasyPrivacy DAT has about 2.0 million (2,017,148 in
/// 6,791,246 bytes), so 2^24 is 8.3 times that. This cap is what bounds the
/// decoded collections: one DAT byte can become a 24-byte `String` in a
/// `Vec`, or a 49-byte hash bucket (a `String` key and a `Vec` value), and
/// serde grows a collection by doubling after a 1 MiB preallocation. At 2^24
/// values the largest single requests measured are 536,862,720 B
/// (`Vec<String>`) and 822,083,592 B (`HashMap<String, Vec<String>>`), under
/// PartitionAlloc's ceiling of 2^31 − 2 MiB (2,145,386,496 B; one request
/// over it aborts the browser). At 2^27 a 42.7 MiB DAT made one
/// `Vec<String>` request 2,147,450,880 B and aborted (review R3-1).
const MAX_DAT_VALUES: u64 = 1 << 24;
/// The deepest container nesting a DAT may have (today's is 7).
const MAX_DAT_DEPTH: usize = 32;

#[cxx::bridge(namespace = "open_adblock")]
mod ffi {
    /// The request's resource type, mapped to the crate's vocabulary inside
    /// the shim (no free-form string crosses the bridge; review 98-6).
    enum OpenRequestType {
        Document,
        Subdocument,
        Script,
        Image,
        Stylesheet,
        Font,
        Media,
        Object,
        Xmlhttprequest,
        Ping,
        Websocket,
        CspReport,
        Other,
    }

    /// The result of one network check.
    struct OpenBlockerResult {
        /// A blocking rule matched (after exceptions).
        matched: bool,
        /// An `$important` rule matched (the crate already applied precedence).
        important: bool,
        /// A `$redirect` rule matched.
        has_redirect: bool,
        /// The crate's `data:<mime>;base64,…` resource for a `$redirect`, for
        /// every request type; C++ decides whether to serve it (§7.4).
        redirect_data_url: String,
        /// The URL after `$removeparam`, with the request's fragment, or empty
        /// (always empty when `truncated`).
        rewritten_url: String,
        /// CSP directives to add (subdocument only, R-4), or empty.
        csp_directives: String,
        /// The URL was longer than `max_input_bytes` and only its first part
        /// was matched (§7.7).
        truncated: bool,
    }

    /// The cosmetic filters for one page (§5.2, §8.3): sanitized, sorted
    /// hide selectors and counters for everything v1 does not apply.
    struct OpenCosmeticResources {
        /// Selectors to hide (`display: none !important`), sorted, at most
        /// 256 KiB of selector text.
        hide_selectors: Vec<String>,
        /// Generic `#@#` exceptions, sorted; the renderer echoes them back
        /// with its class and ID reports.
        exceptions: Vec<String>,
        /// `$generichide`: the renderer must not report class and ID tokens.
        generichide: bool,
        /// Selectors dropped for a procedural operator (§8.3 rule 3).
        dropped_procedural: u32,
        /// Selectors dropped as unsafe (§8.3 rules 1, 2, 4).
        dropped_unsafe: u32,
        /// `:style()` rules, discarded (lead ruling 6).
        dropped_style: u32,
        /// `:remove()`, `:remove-attr()` and `:remove-class()` rules,
        /// discarded (lead ruling 6).
        dropped_remove: u32,
        /// Scriptlets the crate resolved for the page, discarded (lead ruling
        /// 6). The crate resolves only scriptlets whose resource is loaded.
        dropped_scriptlet: u32,
        /// Safe selectors past the 256 KiB payload cap, in sorted order.
        dropped_over_cap: u32,
    }

    /// What a text build produced (§5.5).
    struct OpenBuildReport {
        /// A DAT of this build restores the same engine. False when a list
        /// has `$removeparam` or `:remove*()` rules, which a v0 DAT drops.
        lossless: bool,
        /// The dropped kinds found: `removeparam`, `remove`, `remove-attr`,
        /// `remove-class`.
        lossy_kinds: Vec<String>,
        resources_loaded: u32,
        /// Empty, `json` (the resources file did not parse) or `empty` (it
        /// had no resources).
        resources_error: String,
        /// Lists consumed by the text build; 0 after a DAT load (a DAT does
        /// not record it; the service counts the manifest's lists).
        list_count: u32,
        /// Why the build was refused before parsing (review R3-2: too many
        /// list lines, or too many selector copies), or empty. A refused
        /// build has no rules; C++ treats it as a failed load.
        refused: String,
    }

    /// Generic hide selectors for a page's class and ID tokens, sanitized
    /// like the page's own (§8.3), and what the sanitizer dropped (review
    /// R3-4).
    struct OpenHiddenSelectors {
        selectors: Vec<String>,
        dropped_procedural: u32,
        dropped_unsafe: u32,
        dropped_over_cap: u32,
    }

    /// Facts about an engine.
    struct OpenEngineInfo {
        /// Bytes of the last serialization (0 before the first one).
        serialized_size: u64,
        /// Lists consumed by the last text build.
        list_count: u32,
    }

    extern "Rust" {
        type OpenAdblockEngine;

        /// `adblock=…;shim=…;features=…;regex=…;dat=v0`: what a cached DAT
        /// must have been made with (the receipt binds it).
        fn open_adblock_engine_format() -> String;
        fn open_adblock_create_empty() -> Box<OpenAdblockEngine>;
        fn open_adblock_build(list_texts: &[String], resources_json: &str)
            -> Box<OpenAdblockEngine>;
        fn open_adblock_build_report(engine: &OpenAdblockEngine) -> OpenBuildReport;
        fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8>;
        fn open_adblock_deserialize(
            engine: &mut OpenAdblockEngine,
            dat: &[u8],
            resources_json: &str,
        ) -> bool;
        /// The DAT walk's verdict: empty when the crate may read `dat`, else
        /// the first problem. For logs and the self-test.
        fn open_adblock_dat_check(dat: &[u8]) -> String;
        fn open_adblock_check(
            engine: &OpenAdblockEngine,
            url: &str,
            source_url: &str,
            request_type: OpenRequestType,
            max_input_bytes: u32,
        ) -> OpenBlockerResult;
        fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources;
        fn open_adblock_hidden_selectors(
            engine: &OpenAdblockEngine,
            classes: &[String],
            ids: &[String],
            exceptions: &[String],
        ) -> OpenHiddenSelectors;
        fn open_adblock_set_regex_cache_capacity(engine: &OpenAdblockEngine, bytes: u32);
        fn open_adblock_warm_regexes(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_dat_reshared_count(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_complete_regex_count(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_complete_regex_program_bytes(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_regex_program_memory_usage(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_regex_program_limit_fallbacks(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_regex_compile_count(engine: &OpenAdblockEngine) -> u64;
        fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo;
    }
}

use ffi::{
    OpenBlockerResult, OpenBuildReport, OpenCosmeticResources, OpenEngineInfo,
    OpenHiddenSelectors, OpenRequestType,
};

/// One Profile's engine. Shared by every check of the Profile under a read
/// lock on the C++ side, so it must be `Send + Sync` (R-1).
pub struct OpenAdblockEngine {
    inner: Engine,
    list_count: u32,
    serialized_size: AtomicU64,
    dat_reshared: u64,
    report: BuildReport,
}

#[derive(Clone, Default)]
struct BuildReport {
    lossy_kinds: BTreeSet<&'static str>,
    resources_loaded: u32,
    resources_error: &'static str,
    refused: String,
}

impl OpenAdblockEngine {
    fn new(inner: Engine, list_count: u32, report: BuildReport) -> Box<Self> {
        Box::new(Self { inner, list_count, serialized_size: AtomicU64::new(0), dat_reshared: 0, report })
    }
}

pub fn open_adblock_engine_format() -> String {
    format!(
        "adblock=0.8.11;shim={SHIM_VERSION};features={CRATE_FEATURES};regex={REGEX_FEATURES};dat=v0"
    )
}

pub fn open_adblock_create_empty() -> Box<OpenAdblockEngine> {
    OpenAdblockEngine::new(Engine::new(true), 0, BuildReport::default())
}

/// Parses the crate's own serialized `Vec<Resource>` and applies it. The
/// crate's assembler would read uBlock Origin's files from paths, and it
/// panics on malformed input (`resource_assembler.rs`), so adblock-fork Step
/// 7 produces this JSON form instead (R-2).
fn apply_resources(engine: &mut Engine, resources_json: &str, report: &mut BuildReport) {
    if resources_json.is_empty() {
        return;
    }
    match serde_json::from_str::<Vec<Resource>>(resources_json) {
        Ok(resources) if !resources.is_empty() => {
            report.resources_loaded = u32::try_from(resources.len()).unwrap_or(u32::MAX);
            engine.use_resources(resources);
        }
        Ok(_) => report.resources_error = "empty",
        Err(_) => report.resources_error = "json",
    }
}

/// The rule kinds a v0 DAT drops (F-31), found by a conservative scan: a
/// false positive only costs a text build at the next launch.
fn lossy_kinds(list_texts: &[String]) -> BTreeSet<&'static str> {
    let mut kinds = BTreeSet::new();
    for text in list_texts {
        for line in text.lines() {
            let line = line.trim_start();
            if line.starts_with('!') || line.starts_with('[') {
                continue;
            }
            if line.contains("removeparam") {
                kinds.insert("removeparam");
            }
            if line.contains(":remove(") {
                kinds.insert("remove");
            }
            if line.contains(":remove-attr(") {
                kinds.insert("remove-attr");
            }
            if line.contains(":remove-class(") {
                kinds.insert("remove-class");
            }
        }
    }
    kinds
}

/// The bytes of selector copies one list line costs the crate: a cosmetic
/// rule (`##`, `#@#`, `#?#`, `#$#`, `#%#` and their `#@` forms) stores its
/// selector once per hostname before the separator, or once when it names
/// none. Other lines cost nothing here.
fn cosmetic_copy_bytes(line: &str) -> u64 {
    const SEPARATORS: [&str; 8] = ["#@?#", "#@$#", "#@%#", "#@#", "#?#", "#$#", "#%#", "##"];
    let bytes = line.as_bytes();
    let Some(at) = bytes.iter().position(|byte| *byte == b'#') else { return 0 };
    let rest = bytes.get(at..).unwrap_or(&[]);
    let Some(separator) = SEPARATORS.iter().find(|sep| rest.starts_with(sep.as_bytes())) else {
        return 0;
    };
    let hosts = bytes.get(..at).unwrap_or(&[]);
    let hostnames = 1 + hosts.iter().filter(|byte| **byte == b',').count() as u64;
    let selector = rest.len().saturating_sub(separator.len()) as u64;
    hostnames.saturating_mul(selector)
}

/// Review R3-2: refuses a build the crate could not parse within the
/// allocator's ceiling, before it parses anything. Err is the reason.
fn check_build_limits(list_texts: &[String]) -> Result<(), String> {
    let mut lines = 0usize;
    let mut copies = 0u64;
    for text in list_texts {
        for line in text.lines() {
            lines += 1;
            if lines > MAX_LIST_LINES {
                return Err(format!("more than {MAX_LIST_LINES} list lines"));
            }
            let line = line.trim_start();
            if line.starts_with('!') || line.starts_with('[') {
                continue;
            }
            copies = copies.saturating_add(cosmetic_copy_bytes(line));
        }
    }
    if copies > MAX_COSMETIC_COPY_BYTES {
        return Err(format!(
            "cosmetic rules need {copies} bytes of selector copies, more than \
             {MAX_COSMETIC_COPY_BYTES}"
        ));
    }
    Ok(())
}

/// Builds an engine from the enabled lists (in the caller's order) and the
/// scriptlet and redirect resources. CPU-heavy: C++ calls it on a background
/// task runner only. Lists over the R3-2 limits are not parsed: the engine
/// is empty and the build report says why (`refused`).
pub fn open_adblock_build(list_texts: &[String], resources_json: &str) -> Box<OpenAdblockEngine> {
    if let Err(refused) = check_build_limits(list_texts) {
        let report = BuildReport { refused, ..Default::default() };
        return OpenAdblockEngine::new(Engine::new(true), 0, report);
    }
    let mut set = FilterSet::new(false);
    for text in list_texts {
        set.add_filter_list(text, ParseOptions::default());
    }
    let mut engine = Engine::from_filter_set(set, true);
    let mut report = BuildReport { lossy_kinds: lossy_kinds(list_texts), ..Default::default() };
    apply_resources(&mut engine, resources_json, &mut report);
    OpenAdblockEngine::new(engine, u32::try_from(list_texts.len()).unwrap_or(u32::MAX), report)
}

pub fn open_adblock_build_report(engine: &OpenAdblockEngine) -> OpenBuildReport {
    OpenBuildReport {
        lossless: engine.report.lossy_kinds.is_empty(),
        lossy_kinds: engine.report.lossy_kinds.iter().map(|k| (*k).to_string()).collect(),
        resources_loaded: engine.report.resources_loaded,
        resources_error: engine.report.resources_error.to_string(),
        list_count: engine.list_count,
        refused: engine.report.refused.clone(),
    }
}

pub fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8> {
    match engine.inner.serialize_raw() {
        Ok(bytes) => {
            engine.serialized_size.store(bytes.len() as u64, Ordering::Relaxed);
            bytes
        }
        Err(_) => Vec::new(),
    }
}

/// Reads a MessagePack length of `size` big-endian bytes.
fn take_length(rest: &mut &[u8], size: usize) -> Option<u64> {
    let (head, tail) = rest.split_at_checked(size)?;
    *rest = tail;
    Some(head.iter().fold(0u64, |value, byte| (value << 8) | u64::from(*byte)))
}

/// Reviews R2-1 and R3-1: walks the DAT before the crate reads it.
/// `rmp-serde` allocates a string or binary buffer of the length the stream
/// declares before it reads the bytes (`decode.rs:870`), so a 14-byte DAT
/// that claims a 512 MiB string allocated 512 MiB, and an allocation failure
/// aborts the browser. Here every str, bin and ext length must fit in the
/// bytes left, every array and map count too (each value takes at least one
/// byte), the whole value has at most `MAX_DAT_VALUES` values and
/// `MAX_DAT_DEPTH` levels, nothing may follow it (review R3-5), and the
/// header must be the crate's (which also covers the 4-byte DAT of review
/// 98-3). Then a str or bin buffer is no larger than the DAT; a decoded
/// collection is bounded by the value cap (see `MAX_DAT_VALUES`), not by the
/// DAT's size. No allocation and no recursion here: one pass with a
/// fixed-size stack of pending counts. Err names the first problem.
fn check_dat(dat: &[u8]) -> Result<(), &'static str> {
    let body = dat.strip_prefix(&DAT_MAGIC).ok_or("magic")?;
    let (&version, mut rest) = body.split_first().ok_or("short")?;
    if version != 0 {
        return Err("version");
    }
    // Values still to read at each open level; the crate reads one value.
    let mut pending = [0u64; MAX_DAT_DEPTH + 1];
    pending[0] = 1;
    let mut depth = 0usize;
    let mut values = 0u64;
    loop {
        let Some(top) = pending.get_mut(depth) else { return Err("depth") };
        if *top == 0 {
            if depth == 0 {
                return if rest.is_empty() { Ok(()) } else { Err("trailing") };
            }
            depth -= 1;
            continue;
        }
        *top -= 1;
        values += 1;
        if values > MAX_DAT_VALUES {
            return Err("values");
        }
        let (&marker, tail) = rest.split_first().ok_or("short")?;
        rest = tail;
        // (payload bytes, child values)
        let (payload, children) = match marker {
            0x00..=0x7f | 0xe0..=0xff | 0xc0 | 0xc2 | 0xc3 => (0, 0),
            0x80..=0x8f => (0, 2 * u64::from(marker & 0x0f)),
            0x90..=0x9f => (0, u64::from(marker & 0x0f)),
            0xa0..=0xbf => (u64::from(marker & 0x1f), 0),
            0xc4 | 0xd9 => (take_length(&mut rest, 1).ok_or("short")?, 0),
            0xc5 | 0xda => (take_length(&mut rest, 2).ok_or("short")?, 0),
            0xc6 | 0xdb => (take_length(&mut rest, 4).ok_or("short")?, 0),
            // ext: the length, then a type byte and the data.
            0xc7 => (take_length(&mut rest, 1).ok_or("short")? + 1, 0),
            0xc8 => (take_length(&mut rest, 2).ok_or("short")? + 1, 0),
            0xc9 => (take_length(&mut rest, 4).ok_or("short")? + 1, 0),
            0xcc | 0xd0 => (1, 0),
            0xcd | 0xd1 => (2, 0),
            0xca | 0xce | 0xd2 => (4, 0),
            0xcb | 0xcf | 0xd3 => (8, 0),
            0xd4..=0xd8 => (1 + (1u64 << (marker - 0xd4)), 0),
            0xdc => (0, take_length(&mut rest, 2).ok_or("short")?),
            0xdd => (0, take_length(&mut rest, 4).ok_or("short")?),
            0xde => (0, 2 * take_length(&mut rest, 2).ok_or("short")?),
            0xdf => (0, 2 * take_length(&mut rest, 4).ok_or("short")?),
            _ => return Err("marker"),
        };
        let payload = usize::try_from(payload).map_err(|_| "length")?;
        rest = rest.get(payload..).ok_or("length")?;
        if children > 0 {
            if children > rest.len() as u64 {
                return Err("count");
            }
            depth += 1;
            *pending.get_mut(depth).ok_or("depth")? = children;
        }
    }
}

pub fn open_adblock_dat_check(dat: &[u8]) -> String {
    check_dat(dat).err().unwrap_or("").to_string()
}

/// Loads a serialized engine into an empty one, then applies the resources
/// (a DAT never carries them, F-31). False on any error (a DAT that fails
/// the walk above, version skew, truncation); C++ then builds from text.
pub fn open_adblock_deserialize(
    engine: &mut OpenAdblockEngine,
    dat: &[u8],
    resources_json: &str,
) -> bool {
    if check_dat(dat).is_err() {
        return false;
    }
    match engine.inner.deserialize(dat) {
        Ok(()) => {
            engine.dat_reshared = engine.inner.share_deserialized_filters() as u64;
            engine.serialized_size.store(dat.len() as u64, Ordering::Relaxed);
            let mut report = BuildReport::default();
            apply_resources(&mut engine.inner, resources_json, &mut report);
            engine.report = report;
            true
        }
        Err(_) => {
            // A failed load may leave partial state: start from empty again.
            engine.inner = Engine::new(true);
            false
        }
    }
}

fn crate_request_type(request_type: OpenRequestType) -> &'static str {
    match request_type {
        OpenRequestType::Document => "document",
        OpenRequestType::Subdocument => "subdocument",
        OpenRequestType::Script => "script",
        OpenRequestType::Image => "image",
        OpenRequestType::Stylesheet => "stylesheet",
        OpenRequestType::Font => "font",
        OpenRequestType::Media => "media",
        OpenRequestType::Object => "object",
        OpenRequestType::Xmlhttprequest => "xmlhttprequest",
        OpenRequestType::Ping => "ping",
        OpenRequestType::Websocket => "websocket",
        OpenRequestType::CspReport => "csp_report",
        _ => "other",
    }
}

/// §7.7: the URL without its fragment, and the fragment (with its `#`, or
/// empty). A URL over `cap` bytes is cut after the last separator (a byte `^`
/// matches: not `A-Z a-z 0-9 _ - . %`) at or before byte `cap`, at a char
/// boundary; then the bool is true.
fn match_input(url: &str, cap: usize) -> (&str, &str, bool) {
    let (url, fragment) =
        url.split_at_checked(url.find('#').unwrap_or(url.len())).unwrap_or((url, ""));
    if url.len() <= cap {
        return (url, fragment, false);
    }
    let is_separator =
        |byte: u8| !(byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'%'));
    let bytes = url.as_bytes();
    let end = (1..=cap.min(bytes.len()))
        .rev()
        .find(|&end| {
            bytes.get(end - 1).is_some_and(|byte| is_separator(*byte)) && url.is_char_boundary(end)
        })
        .unwrap_or(0);
    (url.get(..end).unwrap_or(""), fragment, true)
}

/// One network check (R-4 to R-6). A URL the crate cannot parse is allowed.
/// `max_input_bytes` is the §7.7 cap: C++ passes `kOpenAdBlockMatchCapBytes`
/// (16 KiB; 8 KiB only if Step 4's measured gates fail at 16 KiB).
pub fn open_adblock_check(
    engine: &OpenAdblockEngine,
    url: &str,
    source_url: &str,
    request_type: OpenRequestType,
    max_input_bytes: u32,
) -> OpenBlockerResult {
    let cap = usize::try_from(max_input_bytes).unwrap_or(usize::MAX);
    let (url, fragment, truncated) = match_input(url, cap);
    let mut result = OpenBlockerResult {
        matched: false,
        important: false,
        has_redirect: false,
        redirect_data_url: String::new(),
        rewritten_url: String::new(),
        csp_directives: String::new(),
        truncated,
    };
    let type_name = crate_request_type(request_type);
    let Ok(request) = Request::new(url, source_url, type_name) else {
        return result;
    };
    let blocker = engine.inner.check_network_request(&request);
    result.matched = blocker.matched;
    result.important = blocker.important;
    if let Some(redirect) = blocker.redirect {
        result.has_redirect = true;
        // 0.8.11 returns a complete `data:` URL (F-32).
        if redirect.starts_with("data:") {
            result.redirect_data_url = redirect;
        }
    }
    if !truncated {
        // The crate saw the URL without its fragment; give the rewrite the
        // request's fragment back (review R2-3).
        if let Some(rewritten) = blocker.rewritten_url {
            result.rewritten_url = rewritten + fragment;
        }
    }
    if request_type == OpenRequestType::Subdocument {
        result.csp_directives = engine.inner.get_csp_directives(&request).unwrap_or_default();
    }
    result
}

/// §8.3: uBO and AdGuard procedural operators. v1 runs none of them.
const PROCEDURAL: &[&str] = &[
    ":has-text(",
    ":-abp-",
    ":xpath(",
    ":upward(",
    ":matches-css",
    ":matches-attr(",
    ":matches-prop(",
    ":matches-media(",
    ":matches-path(",
    ":min-text-length(",
    ":watch-attr(",
    ":others(",
    ":nth-ancestor(",
    ":if(",
    ":if-not(",
    ":contains(",
    ":-ext-",
    ":remove(",
    ":style(",
];

pub(crate) enum Verdict {
    Keep,
    Procedural,
    Unsafe,
}

/// The bytes `check_selector` acts on; a selector without any is kept.
const SPECIAL: [bool; 256] = {
    let mut table = [false; 256];
    let bytes = b"{};<@/*\\\"'[]():\n\r\x0c\x00";
    let mut i = 0;
    while i < bytes.len() {
        table[bytes[i] as usize] = true;
        i += 1;
    }
    table
};

/// True when a procedural operator starts at one of the selector's colons
/// (every operator in `PROCEDURAL` begins with `:`).
fn has_procedural(bytes: &[u8]) -> bool {
    bytes.iter().enumerate().filter(|(_, b)| **b == b':').any(|(at, _)| {
        let rest = bytes.get(at..).unwrap_or(&[]);
        PROCEDURAL.iter().any(|op| {
            rest.get(..op.len()).is_some_and(|head| head.eq_ignore_ascii_case(op.as_bytes()))
        })
    })
}

/// §8.3 selector rules: nothing that can open or close a rule, load a
/// resource or run script, nothing procedural, nothing unbalanced. One pass
/// over the bytes, no allocation: it runs on every selector of every page.
///
/// `{`, `}`, `;`, `<`, `@` and `/*` count outside quoted strings only:
/// inside a CSS string they are text, and only a newline can end the string
/// early, so newlines are refused everywhere. Real list selectors quote `;`
/// in attribute values (`div[style^="z-index: 999999999;"]`). A `\` escapes
/// the next character (Tailwind-style class names need it); inside quotes,
/// brackets do not count.
pub(crate) fn check_selector(selector: &str) -> Verdict {
    let bytes = selector.as_bytes();
    if bytes.is_empty() || bytes.len() > MAX_SELECTOR {
        return Verdict::Unsafe;
    }
    // Most selectors (`.ad-box`, `#ad_300`) have no byte the rules look at.
    if !bytes.iter().any(|b| SPECIAL[usize::from(*b)]) {
        return Verdict::Keep;
    }
    let mut unsafe_text = false;
    let mut colon = false;
    let mut stack = [0u8; 32];
    let mut depth = 0usize;
    let mut quote = 0u8;
    let mut escaped = false;
    let mut previous = 0u8;
    for &byte in bytes {
        if matches!(byte, b'\n' | b'\r' | 0x0c | 0) {
            unsafe_text = true;
        }
        if escaped {
            escaped = false;
            previous = 0;
            continue;
        }
        if byte == b'\\' {
            escaped = true;
            continue;
        }
        if quote != 0 {
            if byte == quote {
                quote = 0;
            }
            previous = 0;
            continue;
        }
        if matches!(byte, b'{' | b'}' | b';' | b'<' | b'@') || (previous == b'/' && byte == b'*') {
            unsafe_text = true;
        }
        previous = byte;
        match byte {
            b'"' | b'\'' => quote = byte,
            b'[' | b'(' => match stack.get_mut(depth) {
                Some(slot) => {
                    *slot = byte;
                    depth += 1;
                }
                None => unsafe_text = true,
            },
            b']' | b')' => {
                let open = if byte == b']' { b'[' } else { b'(' };
                if depth > 0 && stack.get(depth - 1) == Some(&open) {
                    depth -= 1;
                } else {
                    unsafe_text = true;
                }
            }
            b':' => colon = true,
            _ => {}
        }
    }
    if colon && has_procedural(bytes) {
        return Verdict::Procedural;
    }
    if unsafe_text || depth != 0 || quote != 0 || escaped {
        return Verdict::Unsafe;
    }
    Verdict::Keep
}

/// Counts drops and the payload's selector bytes.
#[derive(Default)]
struct Sanitizer {
    procedural: u32,
    unsafe_: u32,
    over_cap: u32,
    bytes: usize,
}

impl Sanitizer {
    fn keep(&mut self, selector: &str) -> bool {
        match check_selector(selector) {
            Verdict::Procedural => {
                self.procedural = self.procedural.saturating_add(1);
                false
            }
            Verdict::Unsafe => {
                self.unsafe_ = self.unsafe_.saturating_add(1);
                false
            }
            Verdict::Keep if self.bytes.saturating_add(selector.len()) > PAYLOAD_CAP => {
                self.over_cap = self.over_cap.saturating_add(1);
                false
            }
            Verdict::Keep => {
                self.bytes = self.bytes.saturating_add(selector.len());
                true
            }
        }
    }
}

fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// The page's cosmetic filters as sanitized, sorted vectors (§5.2, §8.3). A
/// URL the crate cannot parse gives empty resources.
pub fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources {
    // The crate returns owned sets: move the strings, do not copy them.
    let adblock::cosmetic_filter_cache::UrlSpecificResources {
        hide_selectors,
        style_selectors,
        remove_selectors,
        remove_attrs,
        remove_classes,
        exceptions,
        injected_script,
        generichide,
    } = engine.inner.url_cosmetic_resources(url);

    // v1 applies none of these (lead ruling 6): count each rule and drop it.
    let dropped_style: usize = style_selectors.values().map(Vec::len).sum();
    let dropped_remove = remove_selectors.len() + remove_attrs.len() + remove_classes.len();
    // The crate wraps each resolved scriptlet in this trailer
    // (cosmetic_filter_cache.rs, adblock 0.8.11).
    let dropped_scriptlet = injected_script.matches("\n} catch ( e ) { }\n").count();
    drop((style_selectors, remove_selectors, remove_attrs, remove_classes, injected_script));

    // Sorted, so the payload cap drops the same selectors on every load.
    let mut sanitizer = Sanitizer::default();
    let mut hide_selectors: Vec<String> = hide_selectors.into_iter().collect();
    hide_selectors.sort_unstable();
    hide_selectors.retain(|s| sanitizer.keep(s));

    let mut exceptions: Vec<String> = exceptions.into_iter().collect();
    exceptions.sort_unstable();

    OpenCosmeticResources {
        hide_selectors,
        exceptions,
        generichide,
        dropped_procedural: sanitizer.procedural,
        dropped_unsafe: sanitizer.unsafe_,
        dropped_style: count(dropped_style),
        dropped_remove: count(dropped_remove),
        dropped_scriptlet: count(dropped_scriptlet),
        dropped_over_cap: sanitizer.over_cap,
    }
}

/// Generic hide selectors for the class and ID tokens a page reported,
/// sanitized like the page's own (§8.3), with the drop counts (R3-4).
pub fn open_adblock_hidden_selectors(
    engine: &OpenAdblockEngine,
    classes: &[String],
    ids: &[String],
    exceptions: &[String],
) -> OpenHiddenSelectors {
    let exceptions: HashSet<String> = exceptions.iter().cloned().collect();
    let mut selectors = engine.inner.hidden_class_id_selectors(classes, ids, &exceptions);
    selectors.sort_unstable();
    let mut sanitizer = Sanitizer::default();
    selectors.retain(|s| sanitizer.keep(s));
    OpenHiddenSelectors {
        selectors,
        dropped_procedural: sanitizer.procedural,
        dropped_unsafe: sanitizer.unsafe_,
        dropped_over_cap: sanitizer.over_cap,
    }
}

pub fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo {
    OpenEngineInfo {
        serialized_size: engine.serialized_size.load(Ordering::Relaxed),
        list_count: engine.list_count,
    }
}

/// R-1: the engine is shared across threads. If this stops compiling, a
/// crate feature that makes `Engine` thread-unsafe came back (adblock-fork
/// D-3): fix the features, not this assertion.
#[allow(dead_code)]
fn _assert_send_sync() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<OpenAdblockEngine>();
}

/// Called only on the background build runner, before publishing the engine.
pub fn open_adblock_warm_regexes(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.warm_network_regexes() as u64
}

pub fn open_adblock_regex_compile_count(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.compiled_network_regex_count() as u64
}

pub fn open_adblock_regex_program_limit_fallbacks(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.regex_program_limit_fallbacks() as u64
}

pub fn open_adblock_regex_program_memory_usage(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.regex_program_memory_usage() as u64
}

pub fn open_adblock_set_regex_cache_capacity(engine: &OpenAdblockEngine, bytes: u32) {
    engine.inner.set_regex_cache_capacity(bytes as usize);
}

pub fn open_adblock_complete_regex_count(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.complete_regex_stats().0 as u64
}

pub fn open_adblock_complete_regex_program_bytes(engine: &OpenAdblockEngine) -> u64 {
    engine.inner.complete_regex_stats().1 as u64
}

pub fn open_adblock_dat_reshared_count(engine: &OpenAdblockEngine) -> u64 {
    engine.dat_reshared
}
