//! Folder explorer Tauri commands.
//!
//! Read-only commands for the disk-folder explorer surface (Phase 30).
//! Serves folder tree and folder track list from `tracks.organized_path`.

use crate::database::connection::get_connection;
use crate::database::folders;
use crate::database::folders::FolderNode;
use crate::models::track::Track;

/// List folder children for the folder tree.
///
/// - `prefix = None` → top-level artist folders
/// - `prefix = Some("yeat")` → yeat's sub-folders
/// - `hide_dot_prefixed` hides dot-prefixed entries (default: true)
///
/// # Example (TypeScript)
/// ```typescript
/// const roots = await invoke("list_folder_children", { prefix: null, hideDotPrefixed: true });
/// const children = await invoke("list_folder_children", { prefix: "yeat", hideDotPrefixed: true });
/// ```
#[tauri::command]
pub async fn list_folder_children(
    prefix: Option<String>,
    hide_dot_prefixed: Option<bool>,
) -> Result<Vec<FolderNode>, String> {
    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    folders::list_folder_children(
        &conn,
        prefix.as_deref(),
        hide_dot_prefixed.unwrap_or(true),
    )
    .map_err(|e| format!("Query error: {}", e))
}

/// Get tracks under a folder prefix for the right-pane track list.
///
/// Returns full Track objects for all tracks recursively under the folder.
///
/// # Example (TypeScript)
/// ```typescript
/// const tracks = await invoke("get_folder_tracks", { prefix: "yeat/lyfëstyle v2" });
/// ```
#[tauri::command]
pub async fn get_folder_tracks(prefix: String) -> Result<Vec<Track>, String> {
    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    folders::get_folder_tracks(&conn, &prefix).map_err(|e| format!("Query error: {}", e))
}
