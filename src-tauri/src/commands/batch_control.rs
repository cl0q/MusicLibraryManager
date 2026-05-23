//! Cancellation + batch sizing for long-running enhancement operations.
//!
//! Shared between `fingerprint_library_cmd`, `fetch_artwork_cmd`,
//! `analyze_replaygain_cmd`, `analyze_loudness_all`, and `deep_scan_cmd`.
//!
//! The UI can ask any in-flight op to stop via `stop_analysis_cmd(prefix)`,
//! where `prefix` is the event-namespace the op emits under (e.g.
//! `"loudness"`, `"fingerprint"`, `"replaygain"`, `"artwork"`, `"deepscan"`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

static FLAGS: LazyLock<Mutex<HashMap<String, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static TURBO_MODE: LazyLock<AtomicUsize> = LazyLock::new(|| AtomicUsize::new(0));

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
///
/// Turbo mode uses 80% of available cores for maximum throughput.
pub fn worker_count(turbo_mode: bool) -> usize {
    let base_count = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    
    if turbo_mode {
        // Use 80% of available cores for turbo mode
        (base_count as f64 * 0.8).round().clamp(4, 16) as usize
    } else {
        base_count.clamp(2, 12)
    }
}

/// Batch size for parallel enhancement loops in turbo mode.
/// Larger batches reduce overhead but make cancellation slightly less responsive.
pub const TURBO_BATCH_SIZE: usize = 150;

/// UI-facing command: raise the cancel flag for a given op.
///
/// Safe to call when no op is running — the next run resets it at start.
/// Returns `true` so the frontend can confirm receipt and swap state.
#[tauri::command]
pub async fn stop_analysis_cmd(prefix: String) -> Result<bool, String> {
    cancel_flag(prefix).store(true, Ordering::Relaxed);
    log::info!("stop_analysis requested for '{}'", prefix);
    Ok(true)
}

/// Enable or disable turbo mode for enhancement operations.
/// Turbo mode uses 80% of available cores for maximum throughput.
#[tauri::command]
pub async fn set_turbo_mode(enabled: bool) -> Result<(), String> {
    TURBO_MODE.store(if enabled { 1 } else { 0 }, Ordering::Relaxed);
    log::info!("Turbo mode {}", if enabled { "enabled" } else { "disabled" });
    Ok(())
}

/// Check if turbo mode is enabled (Tauri command version).
#[tauri::command]
pub async fn get_turbo_mode() -> Result<bool, String> {
    Ok(is_turbo_mode())
}

/// Check if turbo mode is enabled.
pub fn is_turbo_mode() -> bool {
    TURBO_MODE.load(Ordering::Relaxed) == 1
}
