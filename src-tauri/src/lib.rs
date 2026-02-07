pub mod artwork;
pub mod audio;
pub mod auth;
pub mod commands;
pub mod config;
pub mod database;
pub mod dedup;
pub mod download;
pub mod duplicate;
pub mod fingerprint;
pub mod import;
pub mod metadata;
pub mod models;
pub mod mount;
pub mod replaygain;
pub mod search;
pub mod sources;
pub mod startup;
pub mod sync;
pub mod transcode;

use tauri::Manager;

use commands::sources::OAuthState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Load .env file if present (non-fatal if missing)
    let _ = dotenvy::dotenv();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            // When a second instance tries to launch (e.g., from deep link),
            // this callback runs in the existing instance with the args
            log::info!("Single instance callback triggered with args: {:?}", args);

            // Focus the main window
            if let Some(window) = app.get_webview_window("main") {
                let _: Result<(), tauri::Error> = window.set_focus();
            }
        }))
        .manage(OAuthState::default())
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // Run startup tasks in background (auto-sync on app open)
            // Uses spawn_blocking to handle rusqlite !Send Connection
            tauri::async_runtime::spawn(async {
                // Run startup sync in a blocking thread since the sync methods
                // hold rusqlite::Connection (which is !Send) across await points
                let handle = tokio::runtime::Handle::current();
                let _ = tokio::task::spawn_blocking(move || {
                    handle.block_on(startup::run_startup_tasks());
                })
                .await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::import::import_directory,
            commands::search::search_library,
            commands::search::get_library_storage_size,
            commands::search::get_library_tracks,
            commands::duplicate::detect_duplicates,
            commands::download::download_tracks,
            commands::download::retry_failed_downloads,
            commands::download::get_retry_queue_status,
            commands::sources::spotify_auth_url,
            commands::sources::spotify_exchange_code,
            commands::sources::sync_spotify,
            commands::sources::soundcloud_auth_url,
            commands::sources::soundcloud_exchange_code,
            commands::sources::sync_soundcloud,
            commands::sources::check_duplicates,
            commands::sources::check_source_connected,
            commands::sources::disconnect_source,
            commands::sources::connect_spotify_with_server,
            commands::sources::connect_soundcloud_with_server,
            commands::playlist::create_playlist_command,
            commands::playlist::get_playlists_command,
            commands::playlist::get_playlist_tracks_command,
            commands::playlist::search_playlist_tracks_command,
            commands::playlist::add_track_to_playlist_command,
            commands::playlist::remove_track_from_playlist_command,
            commands::playlist::reorder_playlist_track_command,
            commands::sync::create_sync_profile,
            commands::sync::list_sync_profiles,
            commands::sync::get_sync_profile,
            commands::sync::delete_sync_profile,
            commands::sync::add_track_to_profile,
            commands::sync::add_playlist_to_profile,
            commands::sync::add_rule_to_profile,
            commands::sync::detect_rockbox_devices_cmd,
            commands::sync::preview_sync_cmd,
            commands::sync::execute_sync_cmd,
            commands::sync::get_last_sync_time,
            commands::enhancements::fingerprint_library_cmd,
            commands::enhancements::fetch_artwork_cmd,
            commands::enhancements::analyze_replaygain_cmd,
            commands::enhancements::deep_scan_cmd,
            commands::enhancements::get_review_queue_cmd,
            commands::enhancements::resolve_review_item_cmd,
            commands::enhancements::get_review_queue_count_cmd,
            commands::library_config::select_library_folder,
            commands::library_config::get_subfolders,
            commands::library_config::configure_library,
            commands::library_config::get_library_config,
            commands::library_config::check_library_connection,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
