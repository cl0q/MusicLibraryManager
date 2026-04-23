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
pub mod yeat;

use tauri::Manager;

use commands::download::DownloadState;
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
        .manage(DownloadState {
            queue_path: std::sync::Mutex::new(None),
        })
        .setup(|app| {
            // Initialize database path using Tauri's app data directory
            let app_data_dir = app.path().app_data_dir().expect("Failed to get app data dir");
            database::init_db_path(app_data_dir.clone());

            // Initialize token storage path
            auth::token_storage::init_token_dir(app_data_dir.clone());

            // Migrate: if db doesn't exist in app data dir but exists in CWD, copy it
            let db_dest = app_data_dir.join("music_library.db");
            if !db_dest.exists() {
                let cwd_db = std::path::PathBuf::from("music_library.db");
                if cwd_db.exists() {
                    log::info!("Migrating database from {:?} to {:?}", cwd_db, db_dest);
                    if let Err(e) = std::fs::copy(&cwd_db, &db_dest) {
                        log::error!("Failed to migrate database: {}", e);
                    }
                }
            }

            // Migrate: if tokens exist in old CWD .tokens/ but not in app data dir, copy them
            let token_dest = app_data_dir.join("tokens");
            let old_tokens = std::path::PathBuf::from(".tokens");
            if old_tokens.exists() && (!token_dest.exists() || token_dest.read_dir().map_or(true, |mut d| d.next().is_none())) {
                log::info!("Migrating tokens from {:?} to {:?}", old_tokens, token_dest);
                std::fs::create_dir_all(&token_dest).ok();
                if let Ok(entries) = std::fs::read_dir(&old_tokens) {
                    for entry in entries.flatten() {
                        let dest_file = token_dest.join(entry.file_name());
                        if let Err(e) = std::fs::copy(entry.path(), &dest_file) {
                            log::error!("Failed to migrate token {:?}: {}", entry.file_name(), e);
                        }
                    }
                }
            }

            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .level_for("lofty", log::LevelFilter::Error)
                        .level_for("symphonia_core", log::LevelFilter::Error)
                        .level_for("symphonia_bundle_mp3", log::LevelFilter::Error)
                        .targets([
                            tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
                            tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Webview),
                        ])
                        .format(|out, message, record| {
                            // Solarized true-color ANSI palette
                            const RESET: &str = "\x1b[0m";
                            const BOLD: &str = "\x1b[1m";
                            const DIM: &str = "\x1b[2m";
                            // Solarized colors (true color)
                            const RED: &str = "\x1b[38;2;220;50;47m";
                            const YELLOW: &str = "\x1b[38;2;181;137;0m";
                            const BLUE: &str = "\x1b[38;2;38;139;210m";
                            const CYAN: &str = "\x1b[38;2;42;161;152m";
                            const VIOLET: &str = "\x1b[38;2;108;113;196m";
                            const GREEN: &str = "\x1b[38;2;133;153;0m";
                            const ORANGE: &str = "\x1b[38;2;203;75;22m";
                            const BASE01: &str = "\x1b[38;2;88;110;117m";

                            let level_color = match record.level() {
                                log::Level::Error => RED,
                                log::Level::Warn => ORANGE,
                                log::Level::Info => BLUE,
                                log::Level::Debug => CYAN,
                                log::Level::Trace => VIOLET,
                            };

                            let level_icon = match record.level() {
                                log::Level::Error => "✖",
                                log::Level::Warn => "▲",
                                log::Level::Info => "●",
                                log::Level::Debug => "◆",
                                log::Level::Trace => "…",
                            };

                            let now = chrono::Local::now().format("%H:%M:%S");

                            // Shorten target: "music_library_manager::download::orchestrator" → "download::orchestrator"
                            let target = record.target();
                            let short_target = target
                                .strip_prefix("music_library_manager::")
                                .unwrap_or(target);

                            out.finish(format_args!(
                                "{DIM}{BASE01}{now}{RESET} {BOLD}{level_color}{level_icon} {:<5}{RESET} {GREEN}{short_target}{RESET} {YELLOW}▸{RESET} {message}",
                                record.level()
                            ))
                        })
                        .build(),
                )?;
            }

            // Setup mount detection (synchronous, stores MountDetector in managed state)
            // Mount detection runs in background thread, doesn't block startup
            if let Err(e) = startup::setup_mount_detection(app.handle().clone()) {
                log::error!("Mount detection setup failed: {}", e);
                // Continue startup even if mount detection fails
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
            commands::analysis::get_track_analysis,
            commands::analysis::get_track_artwork,
            commands::analysis::generate_track_fingerprint,
            commands::analysis::generate_track_waveform,
            commands::analysis::generate_track_spectrogram,
            commands::import::import_directory,
            commands::import::import_playlist_command,
            commands::search::search_library,
            commands::search::get_library_storage_size,
            commands::search::get_library_tracks,
            commands::search::get_library_tracks_only,
            commands::search::get_remote_tracks_only,
            commands::search::get_remote_track_count,
            commands::duplicate::detect_duplicates,
            commands::download::download_tracks,
            commands::download::retry_failed_downloads,
            commands::download::get_retry_queue_status,
            commands::download::get_recent_downloads,
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
            commands::sources::apple_music_get_dev_token,
            commands::sources::apple_music_store_user_token,
            commands::sources::apple_music_check_connected,
            commands::sources::sync_apple_music,
            commands::sources::disconnect_apple_music,
            commands::sources::dab_login,
            commands::sources::check_dab_connected,
            commands::playlist::create_playlist_command,
            commands::playlist::get_playlists_command,
            commands::playlist::get_playlist_tracks_command,
            commands::playlist::search_playlist_tracks_command,
            commands::playlist::add_track_to_playlist_command,
            commands::playlist::remove_track_from_playlist_command,
            commands::playlist::reorder_playlist_track_command,
            commands::playlist::sync_source_likes_playlist,
            commands::sync::create_sync_profile,
            commands::sync::list_sync_profiles,
            commands::sync::get_sync_profile,
            commands::sync::delete_sync_profile,
            commands::sync::add_track_to_profile,
            commands::sync::add_playlist_to_profile,
            commands::sync::add_rule_to_profile,
            commands::sync::remove_playlist_from_profile,
            commands::sync::remove_track_from_profile,
            commands::sync::get_profile_playlists,
            commands::sync::update_sync_profile_settings,
            commands::sync::detect_rockbox_devices_cmd,
            commands::sync::preview_sync_cmd,
            commands::sync::execute_sync_cmd,
            commands::sync::clean_sync_cmd,
            commands::sync::get_last_sync_time,
            commands::sync::get_cached_track_ids,
            commands::enhancements::fingerprint_library_cmd,
            commands::enhancements::fetch_artwork_cmd,
            commands::enhancements::analyze_replaygain_cmd,
            commands::enhancements::analyze_loudness_all,
            commands::enhancements::deep_scan_cmd,
            commands::enhancements::get_review_queue_cmd,
            commands::enhancements::resolve_review_item_cmd,
            commands::enhancements::get_review_queue_count_cmd,
            commands::files::copy_to_clipboard,
            commands::library_config::select_library_folder,
            commands::library_config::get_subfolders,
            commands::library_config::configure_library,
            commands::library_config::get_library_config,
            commands::library_config::check_library_connection,
            commands::library_config::get_library_mount_state,
            commands::library_config::reveal_in_file_manager,
            commands::library_config::get_app_setting,
            commands::library_config::set_app_setting,
            commands::library_config::set_library_size_limit,
            commands::library_config::get_library_size_limit,
            commands::library_config::check_library_size_limit,
            commands::maintenance::reindex_search,
            commands::maintenance::rescan_metadata,
            commands::maintenance::find_orphaned_tracks,
            commands::maintenance::purge_orphaned_tracks,
            commands::maintenance::remove_tracks_from_library,
            commands::maintenance::delete_tracks_from_disk,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
