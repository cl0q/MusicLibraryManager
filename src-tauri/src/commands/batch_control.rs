//! Cancellation + batch sizing for long-running enhancement operations.
//!
//! Shared between `fingerprint_library_cmd`, `fetch_artwork_cmd`,
//! `analyze_replaygain_cmd`, `analyze_loudness_all`, and `deep_scan_cmd`.
//!
//! The UI can ask any in-flight op to stop via `stop_analysis_cmd(prefix)`,
//! where `prefix` is the event-namespace the op emits under (e.g.
//! `"loudness"`, `"fingerprint"`, `"replaygain"`, `"artwork"`, `"deepscan"`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

static FLAGS: LazyLock<Mutex<HashMap<String, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Get (or create) the cancel flag for a given op prefix.
pub fn cancel_flag(prefix: &str) -> Arc<AtomicBool> {
    let mut guard = FLAGS.lock().expect("cancel flag registry poisoned");
    guard
        .entry(prefix.to_string())
        .or_insert_with(|| Arc::new(AtomicBool::new(false)))
        .clone()
}

/// Clear the flag so a fresh run isn't immediately cancelled by a stale signal.
pub fn reset_cancel(prefix: &str) {
    cancel_flag(prefix).store(false, Ordering::Relaxed);
}

/// Check whether the op for this prefix has been asked to stop.
pub fn is_cancelled(prefix: &str) -> bool {
    cancel_flag(prefix).load(Ordering::Relaxed)
}

/// Batch size for parallel enhancement loops.
///
/// Hand-tuned for M-series Macs: large enough that per-batch overhead is
/// amortised, small enough that cancellation feels responsive.
pub const BATCH_SIZE: usize = 75;

/// Effective worker count for CPU-bound analysis (ffmpeg, fpcalc).
///
/// Prefers the OS-reported logical parallelism and caps at 12 so we don't
/// oversubscribe on large Pro/Max chips where each ffmpeg subprocess is
/// itself multi-threaded.
pub fn worker_count() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .clamp(2, 12)
}

/// UI-facing command: raise the cancel flag for a given op.
///
/// Safe to call when no op is running — the next run resets it at start.
/// Returns `true` so the frontend can confirm receipt and swap state.
#[tauri::command]
pub async fn stop_analysis_cmd(prefix: String) -> Result<bool, String> {
    cancel_flag(&prefix).store(true, Ordering::Relaxed);
    log::info!("stop_analysis requested for '{}'", prefix);
    Ok(true)
}
