//! Read-only folder query module for the disk-folder explorer.
//!
//! Derives folder hierarchy from `tracks.organized_path` without filesystem access.
//! No writes to any table — purely read-only queries.

use rusqlite::Connection;

use crate::database::connection::Result;

/// A node in the folder tree derived from organized_path segments.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FolderNode {
    /// Segment name (e.g. "yeat", "lyfëstyle v2")
    pub name: String,
    /// Full prefix path (e.g. "yeat/lyfëstyle v2")
    pub full_path: String,
    /// Recursive count of tracks under this prefix
    pub track_count: i64,
    /// Whether sub-folders exist below this node
    pub has_children: bool,
}

/// List folder children for the tree view.
///
/// - `prefix = None` → top-level artist/root folders
/// - `prefix = Some("yeat")` → yeat's sub-folders
/// - `hide_dot_prefixed` filters out dot-prefixed top-level entries (e.g. `.mlm_staging`)
///
/// Returns folders sorted case-insensitively by name.
pub fn list_folder_children(
    conn: &Connection,
    prefix: Option<&str>,
    hide_dot_prefixed: bool,
) -> Result<Vec<FolderNode>> {
    let mut nodes: Vec<FolderNode> = match prefix {
        None => {
            // Top-level: distinct first path segments
            let sql = if hide_dot_prefixed {
                "SELECT
                    substr(organized_path, 1, instr(organized_path, '/') - 1) AS segment,
                    COUNT(*) AS track_count
                FROM tracks
                WHERE organized_path IS NOT NULL
                    AND instr(organized_path, '/') > 0
                    AND organized_path NOT LIKE '.%'
                GROUP BY segment
                HAVING segment != ''
                ORDER BY LOWER(segment)"
            } else {
                "SELECT
                    substr(organized_path, 1, instr(organized_path, '/') - 1) AS segment,
                    COUNT(*) AS track_count
                FROM tracks
                WHERE organized_path IS NOT NULL
                    AND instr(organized_path, '/') > 0
                GROUP BY segment
                HAVING segment != ''
                ORDER BY LOWER(segment)"
            };

            let mut stmt = conn.prepare(sql)?;
            let rows = stmt
                .query_map([], |row| {
                    let name: String = row.get(0)?;
                    let track_count: i64 = row.get(1)?;
                    Ok((name, track_count))
                })?
                .filter_map(|r| r.ok())
                .collect::<Vec<_>>();

            rows.into_iter()
                .map(|(name, track_count)| FolderNode {
                    full_path: name.clone(),
                    name,
                    track_count,
                    has_children: false, // computed below
                })
                .collect()
        }
        Some(p) => {
            // Sub-folder: distinct next-level segments under prefix
            let like_pattern = format!("{}/%", p);
            let prefix_len = (p.len() + 1) as i64; // prefix + '/'

            let sql = "SELECT
                substr(organized_path, ?2 + 1,
                    CASE
                        WHEN instr(substr(organized_path, ?2 + 1), '/') > 0
                            THEN instr(substr(organized_path, ?2 + 1), '/') - 1
                        ELSE length(substr(organized_path, ?2 + 1))
                    END
                ) AS segment,
                COUNT(*) AS track_count
            FROM tracks
            WHERE organized_path LIKE ?1
                AND length(organized_path) > ?2
            GROUP BY segment
            HAVING segment != ''
            ORDER BY LOWER(segment)";

            let mut stmt = conn.prepare(sql)?;
            let rows = stmt
                .query_map(rusqlite::params![like_pattern, prefix_len], |row| {
                    let name: String = row.get(0)?;
                    let track_count: i64 = row.get(1)?;
                    Ok((name, track_count))
                })?
                .filter_map(|r| r.ok())
                .collect::<Vec<_>>();

            rows.into_iter()
                .map(|(name, track_count)| FolderNode {
                    full_path: format!("{}/{}", p, name),
                    name,
                    track_count,
                    has_children: false, // computed below
                })
                .collect()
        }
    };

    // Batch compute has_children for all returned nodes
    if !nodes.is_empty() {
        // For each node, check if any track exists with an additional path segment
        // i.e. organized_path LIKE 'full_path/%/%' (has at least two more segments)
        for node in &mut nodes {
            let deep_pattern = format!("{}/%/%", node.full_path);
            let has_children: bool = conn
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM tracks WHERE organized_path LIKE ?1)",
                    [&deep_pattern],
                    |row| row.get(0),
                )
                .unwrap_or(false);
            node.has_children = has_children;
        }
    }

    Ok(nodes)
}

/// Get track IDs for all tracks recursively under a folder prefix.
///
/// Returns IDs sorted case-insensitively by organized_path.
pub fn get_folder_track_ids(conn: &Connection, prefix: &str) -> Result<Vec<i64>> {
    let like_pattern = format!("{}/%", prefix);

    let mut stmt = conn.prepare(
        "SELECT id FROM tracks
         WHERE organized_path LIKE ?1
         ORDER BY LOWER(organized_path)",
    )?;

    let ids = stmt
        .query_map([&like_pattern], |row| row.get(0))?
        .filter_map(|r| r.ok())
        .collect();

    Ok(ids)
}

/// Get full Track objects for all tracks recursively under a folder prefix.
///
/// More efficient than get_folder_track_ids + individual lookups —
/// fetches all columns in a single query.
pub fn get_folder_tracks(
    conn: &Connection,
    prefix: &str,
) -> Result<Vec<crate::models::track::Track>> {
    use crate::models::track::{Track, TrackMetadata};

    let like_pattern = format!("{}/%", prefix);

    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration, format,
                original_path, organized_path, is_duplicate, date_added,
                lufs_i, lufs_range, true_peak, energy_bucket
         FROM tracks
         WHERE organized_path LIKE ?1
         ORDER BY LOWER(organized_path)",
    )?;

    let tracks = stmt
        .query_map([&like_pattern], |row| {
            Ok(Track {
                id: Some(row.get(0)?),
                metadata: TrackMetadata {
                    artist: row.get(1)?,
                    album_artist: row.get(2)?,
                    album: row.get(3)?,
                    title: row.get(4)?,
                    genre: row.get(5)?,
                    year: row.get(6)?,
                    bitrate: row.get(7)?,
                    duration: row.get(8)?,
                    format: row.get(9)?,
                    original_path: row.get(10)?,
                },
                organized_path: row.get(11)?,
                is_duplicate: row.get::<_, i32>(12)? != 0,
                date_added: row.get(13)?,
                lufs_i: row.get(14)?,
                lufs_range: row.get(15)?,
                true_peak: row.get(16)?,
                energy_bucket: row.get(17)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    Ok(tracks)
}
