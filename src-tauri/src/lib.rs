pub mod auth;
pub mod commands;
pub mod database;
pub mod download;
pub mod duplicate;
pub mod import;
pub mod metadata;
pub mod models;
pub mod search;
pub mod transcode;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::import::import_directory,
            commands::search::search_library,
            commands::duplicate::detect_duplicates,
            commands::download::download_tracks,
            commands::download::retry_failed_downloads,
            commands::download::get_retry_queue_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
