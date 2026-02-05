pub mod audio;
pub mod auth;
pub mod commands;
pub mod database;
pub mod dedup;
pub mod download;
pub mod duplicate;
pub mod fingerprint;
pub mod import;
pub mod metadata;
pub mod models;
pub mod search;
pub mod sources;
pub mod startup;
pub mod sync;
pub mod transcode;

use commands::sources::OAuthState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Load .env file if present (non-fatal if missing)
    let _ = dotenvy::dotenv();

    tauri::Builder::default()
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
