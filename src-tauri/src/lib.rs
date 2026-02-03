pub mod commands;
pub mod database;
pub mod import;
pub mod metadata;
pub mod models;
pub mod search;

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
            commands::search::search_library
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
