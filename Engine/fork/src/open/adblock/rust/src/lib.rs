// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

//! CXX bridge over the vendored Brave `adblock` crate (MPL-2.0), the only
//! Rust Open writes by hand (docs/plans/adblock-fork.md §5). C++ sees one
//! opaque engine, three flat structs, strings and string vectors.
//!
//! Chromium builds Rust with `-Cpanic=abort`, so a panic here ends the
//! browser process: nothing in this file may panic. Every crate call used
//! returns a `Result` or an empty value on bad input.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;

#[cxx::bridge(namespace = "open_adblock")]
mod ffi {
    /// The result of one network check.
    struct OpenBlockerResult {
        /// A blocking rule matched (after exceptions).
        matched: bool,
        /// An `$important` rule matched (the crate already applied precedence).
        important: bool,
        /// A `$redirect` rule matched.
        has_redirect: bool,
        /// The `data:` URL to load instead; set only for scripts. Empty for
        /// other types: C++ blocks them instead.
        redirect_data_url: String,
        /// The URL after `$removeparam`, or empty.
        rewritten_url: String,
        /// CSP directives to add (document and subdocument only), or empty.
        csp_directives: String,
    }

    /// The cosmetic filters for one page.
    struct OpenCosmeticResources {
        /// `<sel>,<sel> { display: none !important; }`, or empty.
        hide_css: String,
        /// `<sel> { <decl>; }` blocks joined by newlines, or empty.
        style_css: String,
        /// The procedural-filter data line (if any) and the scriptlets.
        injected_script: String,
        /// Generic `#@#` exceptions; the renderer echoes them back with its
        /// class and ID reports.
        exceptions: Vec<String>,
        /// `$generichide`: the renderer must not report class and ID tokens.
        generichide: bool,
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

        fn open_adblock_create_empty() -> Box<OpenAdblockEngine>;
        fn open_adblock_build(list_texts: &[String], resources_json: &str)
            -> Box<OpenAdblockEngine>;
        fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8>;
        fn open_adblock_deserialize(engine: &mut OpenAdblockEngine, dat: &[u8]) -> bool;
        fn open_adblock_check(
            engine: &OpenAdblockEngine,
            url: &str,
            source_url: &str,
            request_type: &str,
        ) -> OpenBlockerResult;
        fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources;
        fn open_adblock_hidden_selectors(
            engine: &OpenAdblockEngine,
            classes: &[String],
            ids: &[String],
            exceptions: &[String],
        ) -> Vec<String>;
        fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo;
    }
}

use ffi::{OpenBlockerResult, OpenCosmeticResources, OpenEngineInfo};

/// One Profile's engine. Shared by every throttle of the Profile under a
/// read lock on the C++ side, so it must be `Send + Sync` (R-1).
pub struct OpenAdblockEngine {
    inner: Engine,
    list_count: u32,
    serialized_size: AtomicU64,
}

impl OpenAdblockEngine {
    fn new(inner: Engine, list_count: u32) -> Box<Self> {
        Box::new(Self { inner, list_count, serialized_size: AtomicU64::new(0) })
    }
}

pub fn open_adblock_create_empty() -> Box<OpenAdblockEngine> {
    OpenAdblockEngine::new(Engine::new(true), 0)
}

/// Builds an engine from the enabled lists (in the caller's order) and the
/// scriptlet and redirect resources. CPU-heavy: C++ calls it on a background
/// task runner only.
///
/// `resources_json` is the crate's own serialized `Vec<Resource>` (empty: no
/// resources). The crate's assembler would read uBlock Origin's files from
/// paths, and it panics on malformed input (`resource_assembler.rs`), so
/// adblock-fork Step 7 produces this JSON form instead (R-2).
pub fn open_adblock_build(list_texts: &[String], resources_json: &str) -> Box<OpenAdblockEngine> {
    let mut set = FilterSet::new(false);
    for text in list_texts {
        set.add_filter_list(text, ParseOptions::default());
    }
    let mut engine = Engine::from_filter_set(set, true);
    if !resources_json.is_empty() {
        match serde_json::from_str::<Vec<Resource>>(resources_json) {
            Ok(resources) if !resources.is_empty() => engine.use_resources(resources),
            Ok(_) => eprintln!("open_adblock: resources file has no resources"),
            Err(error) => eprintln!("open_adblock: resources not loaded: {error}"),
        }
    }
    OpenAdblockEngine::new(engine, u32::try_from(list_texts.len()).unwrap_or(u32::MAX))
}

pub fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8> {
    match engine.inner.serialize_raw() {
        Ok(bytes) => {
            engine.serialized_size.store(bytes.len() as u64, Ordering::Relaxed);
            bytes
        }
        Err(_) => {
            eprintln!("open_adblock: serialization failed");
            Vec::new()
        }
    }
}

/// Loads a serialized engine into an empty one. False on any error (version
/// skew, truncation); C++ then builds from text.
pub fn open_adblock_deserialize(engine: &mut OpenAdblockEngine, dat: &[u8]) -> bool {
    match engine.inner.deserialize(dat) {
        Ok(()) => {
            engine.serialized_size.store(dat.len() as u64, Ordering::Relaxed);
            true
        }
        Err(_) => {
            // A failed load may leave partial state: start from empty again.
            engine.inner = Engine::new(true);
            false
        }
    }
}

/// One network check (R-4 to R-6). A URL the crate cannot parse is allowed.
pub fn open_adblock_check(
    engine: &OpenAdblockEngine,
    url: &str,
    source_url: &str,
    request_type: &str,
) -> OpenBlockerResult {
    let mut result = OpenBlockerResult {
        matched: false,
        important: false,
        has_redirect: false,
        redirect_data_url: String::new(),
        rewritten_url: String::new(),
        csp_directives: String::new(),
    };
    let Ok(request) = Request::new(url, source_url, request_type) else {
        return result;
    };
    let blocker = engine.inner.check_network_request(&request);
    result.matched = blocker.matched;
    result.important = blocker.important;
    if let Some(redirect) = blocker.redirect {
        result.has_redirect = true;
        // 0.8.11 returns a complete `data:` URL. Only scripts are redirected
        // in v1 (adblock-fork §7.4); C++ blocks any other type.
        if request_type == "script" && redirect.starts_with("data:") {
            result.redirect_data_url = redirect;
        }
    }
    result.rewritten_url = blocker.rewritten_url.unwrap_or_default();
    if request_type == "document" || request_type == "subdocument" {
        result.csp_directives = engine.inner.get_csp_directives(&request).unwrap_or_default();
    }
    result
}

/// The page's cosmetic filters, rendered as CSS and script text (R-7, R-8).
/// A URL the crate cannot parse gives empty resources.
pub fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources {
    let resources = engine.inner.url_cosmetic_resources(url);

    let hide: BTreeSet<&String> = resources.hide_selectors.iter().collect();
    let hide_css = if hide.is_empty() {
        String::new()
    } else {
        let selectors: Vec<&str> = hide.iter().map(|s| s.as_str()).collect();
        format!("{} {{ display: none !important; }}", selectors.join(","))
    };

    let styles: BTreeMap<&String, &Vec<String>> = resources.style_selectors.iter().collect();
    let style_css = styles
        .iter()
        .map(|(selector, declarations)| {
            let body: String = declarations.iter().map(|d| format!("{d}; ")).collect();
            format!("{selector} {{ {body}}}")
        })
        .collect::<Vec<_>>()
        .join("\n");

    // Removals have no CSS form: they reach the renderer agent as data
    // (adblock-fork §8.3), ahead of the scriptlets.
    let mut injected_script = String::new();
    if !resources.remove_selectors.is_empty()
        || !resources.remove_attrs.is_empty()
        || !resources.remove_classes.is_empty()
    {
        let remove: BTreeSet<&String> = resources
            .remove_selectors
            .iter()
            .filter(|s| !resources.style_selectors.contains_key(*s))
            .collect();
        let attrs: BTreeMap<&String, &Vec<String>> = resources.remove_attrs.iter().collect();
        let classes: BTreeMap<&String, &Vec<String>> = resources.remove_classes.iter().collect();
        let data = serde_json::json!({
            "remove": remove,
            "removeAttrs": attrs,
            "removeClasses": classes,
        });
        injected_script.push_str("window.__openAdBlockProcedural=");
        injected_script.push_str(&data.to_string());
        injected_script.push_str(";\n");
    }
    injected_script.push_str(&resources.injected_script);

    let mut exceptions: Vec<String> = resources.exceptions.into_iter().collect();
    exceptions.sort();

    OpenCosmeticResources {
        hide_css,
        style_css,
        injected_script,
        exceptions,
        generichide: resources.generichide,
    }
}

/// Generic hide selectors for the class and ID tokens a page reported.
pub fn open_adblock_hidden_selectors(
    engine: &OpenAdblockEngine,
    classes: &[String],
    ids: &[String],
    exceptions: &[String],
) -> Vec<String> {
    let exceptions: HashSet<String> = exceptions.iter().cloned().collect();
    let mut selectors = engine.inner.hidden_class_id_selectors(classes, ids, &exceptions);
    selectors.sort();
    selectors
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
