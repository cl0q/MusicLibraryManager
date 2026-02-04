//! Sync profile management and content resolution.
//!
//! Provides sync profile CRUD operations and content resolution logic.
//! Profiles define which tracks to sync to a device via three mechanisms:
//! - Manual tracks: Individually added tracks
//! - Playlists: All tracks from selected playlists
//! - Rules: Query-based dynamic track selection
//!
//! The `get_all_track_ids` method returns the union of all three sources.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::PathBuf;

use crate::database::connection::Result;

/// Filter rule for query-based track selection.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterRule {
    pub id: Option<i64>,
    pub field: String,    // "genre" | "source" | "date_added" | "artist" | "bitrate" | "tag"
    pub operator: String, // "eq" | "ne" | "gt" | "lt" | "contains" | "in"
    pub value: String,    // Filter value
}

/// Sync profile with metadata.
#[derive(Debug, Clone)]
pub struct SyncProfile {
    pub id: i64,
    pub name: String,
    pub output_folder: PathBuf,
    pub date_created: String,
    pub date_modified: String,
}

impl SyncProfile {
    /// Get all track IDs in this profile (union of manual, playlists, rules).
    ///
    /// Combines tracks from three sources:
    /// 1. Manual tracks from sync_profile_tracks
    /// 2. Playlist tracks from sync_profile_playlists JOIN playlist_tracks
    /// 3. Rule-based tracks from sync_profile_rules applied to tracks table
    ///
    /// # Arguments
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(HashSet<i64>)` - Set of unique track IDs
    /// * `Err` if database query fails
    pub fn get_all_track_ids(&self, conn: &Connection) -> Result<HashSet<i64>> {
        let mut track_ids = HashSet::new();

        // 1. Manual tracks
        let mut stmt = conn.prepare(
            "SELECT track_id FROM sync_profile_tracks WHERE profile_id = ?1",
        )?;
        let manual_tracks: Vec<i64> = stmt
            .query_map([self.id], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<i64>>>()?;
        track_ids.extend(manual_tracks);

        // 2. Playlist tracks (join through playlists)
        let mut stmt = conn.prepare(
            "SELECT DISTINCT pt.track_id
             FROM sync_profile_playlists spp
             JOIN playlist_tracks pt ON spp.playlist_id = pt.playlist_id
             WHERE spp.profile_id = ?1",
        )?;
        let playlist_tracks: Vec<i64> = stmt
            .query_map([self.id], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<i64>>>()?;
        track_ids.extend(playlist_tracks);

        // 3. Rule-based tracks
        let mut stmt = conn.prepare(
            "SELECT id, field, operator, value FROM sync_profile_rules WHERE profile_id = ?1",
        )?;
        let rules: Vec<FilterRule> = stmt
            .query_map([self.id], |row| {
                Ok(FilterRule {
                    id: Some(row.get(0)?),
                    field: row.get(1)?,
                    operator: row.get(2)?,
                    value: row.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<FilterRule>>>()?;

        // Apply each rule and collect matching tracks
        for rule in rules {
            let rule_tracks = apply_filter_rule(conn, &rule)?;
            track_ids.extend(rule_tracks);
        }

        Ok(track_ids)
    }
}

/// Apply a filter rule to the tracks table and return matching track IDs.
fn apply_filter_rule(conn: &Connection, rule: &FilterRule) -> Result<Vec<i64>> {
    // Build SQL query based on field and operator
    let (sql, params): (String, Vec<String>) = match rule.field.as_str() {
        "genre" => match rule.operator.as_str() {
            "eq" => (
                "SELECT id FROM tracks WHERE genre = ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "ne" => (
                "SELECT id FROM tracks WHERE genre != ?1 OR genre IS NULL".to_string(),
                vec![rule.value.clone()],
            ),
            "contains" => (
                "SELECT id FROM tracks WHERE genre LIKE ?1".to_string(),
                vec![format!("%{}%", rule.value)],
            ),
            _ => return Ok(vec![]),
        },
        "artist" => match rule.operator.as_str() {
            "eq" => (
                "SELECT id FROM tracks WHERE artist = ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "ne" => (
                "SELECT id FROM tracks WHERE artist != ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "contains" => (
                "SELECT id FROM tracks WHERE artist LIKE ?1".to_string(),
                vec![format!("%{}%", rule.value)],
            ),
            _ => return Ok(vec![]),
        },
        "bitrate" => match rule.operator.as_str() {
            "gt" => (
                "SELECT id FROM tracks WHERE bitrate > ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "lt" => (
                "SELECT id FROM tracks WHERE bitrate < ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "eq" => (
                "SELECT id FROM tracks WHERE bitrate = ?1".to_string(),
                vec![rule.value.clone()],
            ),
            _ => return Ok(vec![]),
        },
        "date_added" => match rule.operator.as_str() {
            "gt" => (
                "SELECT id FROM tracks WHERE date_added > ?1".to_string(),
                vec![rule.value.clone()],
            ),
            "lt" => (
                "SELECT id FROM tracks WHERE date_added < ?1".to_string(),
                vec![rule.value.clone()],
            ),
            _ => return Ok(vec![]),
        },
        "source" => {
            // Source filter requires join to track_sources and sources tables
            match rule.operator.as_str() {
                "eq" => (
                    "SELECT DISTINCT ts.track_id FROM track_sources ts
                     JOIN sources s ON ts.source_id = s.id
                     WHERE s.name = ?1"
                        .to_string(),
                    vec![rule.value.clone()],
                ),
                "ne" => (
                    "SELECT DISTINCT t.id FROM tracks t
                     WHERE t.id NOT IN (
                         SELECT ts.track_id FROM track_sources ts
                         JOIN sources s ON ts.source_id = s.id
                         WHERE s.name = ?1
                     )"
                    .to_string(),
                    vec![rule.value.clone()],
                ),
                _ => return Ok(vec![]),
            }
        }
        "tag" => {
            // Tag filter requires join to playlist_tracks and playlist_tags
            match rule.operator.as_str() {
                "eq" => (
                    "SELECT DISTINCT pt.track_id FROM playlist_tracks pt
                     JOIN playlist_tags ptag ON pt.playlist_id = ptag.playlist_id
                     WHERE ptag.tag = ?1"
                        .to_string(),
                    vec![rule.value.clone()],
                ),
                _ => return Ok(vec![]),
            }
        }
        _ => return Ok(vec![]),
    };

    // Execute query and collect track IDs
    let mut stmt = conn.prepare(&sql)?;
    let track_ids: Vec<i64> = stmt
        .query_map(rusqlite::params_from_iter(&params), |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<i64>>>()?;

    Ok(track_ids)
}

/// Create a new sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `name` - Profile name (must be unique)
/// * `output_folder` - Local staging folder path
///
/// # Returns
/// * `Ok(profile_id)` - ID of created profile
/// * `Err` if name already exists or database operation fails
pub fn create_sync_profile(
    conn: &Connection,
    name: String,
    output_folder: PathBuf,
) -> Result<i64> {
    conn.execute(
        "INSERT INTO sync_profiles (name, output_folder) VALUES (?1, ?2)",
        rusqlite::params![name, output_folder.to_string_lossy().to_string()],
    )?;

    Ok(conn.last_insert_rowid())
}

/// Get a sync profile by ID.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile to retrieve
///
/// # Returns
/// * `Ok(SyncProfile)` if profile exists
/// * `Err` if profile not found or database operation fails
pub fn get_sync_profile(conn: &Connection, profile_id: i64) -> Result<SyncProfile> {
    let profile = conn.query_row(
        "SELECT id, name, output_folder, date_created, date_modified
         FROM sync_profiles WHERE id = ?1",
        [profile_id],
        |row| {
            Ok(SyncProfile {
                id: row.get(0)?,
                name: row.get(1)?,
                output_folder: PathBuf::from(row.get::<_, String>(2)?),
                date_created: row.get(3)?,
                date_modified: row.get(4)?,
            })
        },
    )?;

    Ok(profile)
}

/// List all sync profiles.
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(Vec<SyncProfile>)` - All profiles ordered by name
/// * `Err` if database operation fails
pub fn list_sync_profiles(conn: &Connection) -> Result<Vec<SyncProfile>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, output_folder, date_created, date_modified
         FROM sync_profiles ORDER BY name",
    )?;

    let profiles = stmt
        .query_map([], |row| {
            Ok(SyncProfile {
                id: row.get(0)?,
                name: row.get(1)?,
                output_folder: PathBuf::from(row.get::<_, String>(2)?),
                date_created: row.get(3)?,
                date_modified: row.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<SyncProfile>>>()?;

    Ok(profiles)
}

/// Delete a sync profile and all associated data.
///
/// CASCADE deletes: profile tracks, playlists, rules, and sync state.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile to delete
///
/// # Returns
/// * `Ok(())` if profile deleted successfully
/// * `Err` if database operation fails
pub fn delete_sync_profile(conn: &Connection, profile_id: i64) -> Result<()> {
    conn.execute("DELETE FROM sync_profiles WHERE id = ?1", [profile_id])?;
    Ok(())
}

/// Add a manual track to a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
/// * `track_id` - ID of track to add
///
/// # Returns
/// * `Ok(())` if track added successfully
/// * `Err` if track already in profile or database operation fails
pub fn add_manual_track(conn: &Connection, profile_id: i64, track_id: i64) -> Result<()> {
    conn.execute(
        "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (?1, ?2)",
        rusqlite::params![profile_id, track_id],
    )?;
    Ok(())
}

/// Remove a manual track from a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
/// * `track_id` - ID of track to remove
///
/// # Returns
/// * `Ok(())` if track removed successfully
/// * `Err` if database operation fails
pub fn remove_manual_track(conn: &Connection, profile_id: i64, track_id: i64) -> Result<()> {
    conn.execute(
        "DELETE FROM sync_profile_tracks WHERE profile_id = ?1 AND track_id = ?2",
        rusqlite::params![profile_id, track_id],
    )?;
    Ok(())
}

/// Add a playlist to a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
/// * `playlist_id` - ID of playlist to add
///
/// # Returns
/// * `Ok(())` if playlist added successfully
/// * `Err` if playlist already in profile or database operation fails
pub fn add_playlist(conn: &Connection, profile_id: i64, playlist_id: i64) -> Result<()> {
    conn.execute(
        "INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (?1, ?2)",
        rusqlite::params![profile_id, playlist_id],
    )?;
    Ok(())
}

/// Remove a playlist from a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
/// * `playlist_id` - ID of playlist to remove
///
/// # Returns
/// * `Ok(())` if playlist removed successfully
/// * `Err` if database operation fails
pub fn remove_playlist(conn: &Connection, profile_id: i64, playlist_id: i64) -> Result<()> {
    conn.execute(
        "DELETE FROM sync_profile_playlists WHERE profile_id = ?1 AND playlist_id = ?2",
        rusqlite::params![profile_id, playlist_id],
    )?;
    Ok(())
}

/// Add a filter rule to a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
/// * `rule` - Filter rule to add
///
/// # Returns
/// * `Ok(rule_id)` - ID of created rule
/// * `Err` if database operation fails
pub fn add_rule(conn: &Connection, profile_id: i64, rule: FilterRule) -> Result<i64> {
    conn.execute(
        "INSERT INTO sync_profile_rules (profile_id, field, operator, value) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![profile_id, rule.field, rule.operator, rule.value],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Remove a filter rule from a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `rule_id` - ID of rule to remove
///
/// # Returns
/// * `Ok(())` if rule removed successfully
/// * `Err` if database operation fails
pub fn remove_rule(conn: &Connection, rule_id: i64) -> Result<()> {
    conn.execute("DELETE FROM sync_profile_rules WHERE id = ?1", [rule_id])?;
    Ok(())
}

/// Get all filter rules for a sync profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of profile
///
/// # Returns
/// * `Ok(Vec<FilterRule>)` - All rules for the profile
/// * `Err` if database operation fails
pub fn get_profile_rules(conn: &Connection, profile_id: i64) -> Result<Vec<FilterRule>> {
    let mut stmt = conn.prepare(
        "SELECT id, field, operator, value FROM sync_profile_rules WHERE profile_id = ?1",
    )?;

    let rules = stmt
        .query_map([profile_id], |row| {
            Ok(FilterRule {
                id: Some(row.get(0)?),
                field: row.get(1)?,
                operator: row.get(2)?,
                value: row.get(3)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<FilterRule>>>()?;

    Ok(rules)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{connection::get_memory_connection, schema::initialize_schema};

    #[test]
    fn test_create_sync_profile() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        let profile_id =
            create_sync_profile(&conn, "iPod Classic".to_string(), PathBuf::from("/mnt/ipod"))
                .unwrap();

        assert!(profile_id > 0);

        // Verify profile exists
        let profile = get_sync_profile(&conn, profile_id).unwrap();
        assert_eq!(profile.name, "iPod Classic");
        assert_eq!(profile.output_folder, PathBuf::from("/mnt/ipod"));
    }

    #[test]
    fn test_list_sync_profiles() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        create_sync_profile(&conn, "iPod".to_string(), PathBuf::from("/mnt/ipod")).unwrap();
        create_sync_profile(&conn, "iPhone".to_string(), PathBuf::from("/mnt/iphone")).unwrap();

        let profiles = list_sync_profiles(&conn).unwrap();
        assert_eq!(profiles.len(), 2);
        // Sorted by name (ORDER BY name): iPhone < iPod
        assert_eq!(profiles[0].name, "iPhone");
        assert_eq!(profiles[1].name, "iPod");
    }

    #[test]
    fn test_delete_sync_profile() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        let profile_id =
            create_sync_profile(&conn, "Test".to_string(), PathBuf::from("/tmp/test")).unwrap();

        delete_sync_profile(&conn, profile_id).unwrap();

        let profiles = list_sync_profiles(&conn).unwrap();
        assert_eq!(profiles.len(), 0);
    }

    #[test]
    fn test_add_manual_track() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Create profile
        let profile_id =
            create_sync_profile(&conn, "Test".to_string(), PathBuf::from("/tmp/test")).unwrap();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "mp3", "/path/to/track.mp3"],
        )
        .unwrap();
        let track_id = conn.last_insert_rowid();

        // Add track to profile
        add_manual_track(&conn, profile_id, track_id).unwrap();

        // Verify track in profile
        let profile = get_sync_profile(&conn, profile_id).unwrap();
        let track_ids = profile.get_all_track_ids(&conn).unwrap();
        assert!(track_ids.contains(&track_id));
    }

    #[test]
    fn test_add_playlist_to_profile() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Create profile
        let profile_id =
            create_sync_profile(&conn, "Test".to_string(), PathBuf::from("/tmp/test")).unwrap();

        // Create playlist
        conn.execute(
            "INSERT INTO playlists (name, category) VALUES (?1, ?2)",
            rusqlite::params!["Test Playlist", "regular"],
        )
        .unwrap();
        let playlist_id = conn.last_insert_rowid();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "mp3", "/path/to/track.mp3"],
        )
        .unwrap();
        let track_id = conn.last_insert_rowid();

        // Add track to playlist
        conn.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?1, ?2, ?3)",
            rusqlite::params![playlist_id, track_id, "a0"],
        )
        .unwrap();

        // Add playlist to profile
        add_playlist(&conn, profile_id, playlist_id).unwrap();

        // Verify playlist tracks in profile
        let profile = get_sync_profile(&conn, profile_id).unwrap();
        let track_ids = profile.get_all_track_ids(&conn).unwrap();
        assert!(track_ids.contains(&track_id));
    }

    #[test]
    fn test_add_rule() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Create profile
        let profile_id =
            create_sync_profile(&conn, "Test".to_string(), PathBuf::from("/tmp/test")).unwrap();

        // Add rule
        let rule = FilterRule {
            id: None,
            field: "genre".to_string(),
            operator: "eq".to_string(),
            value: "Rock".to_string(),
        };
        let rule_id = add_rule(&conn, profile_id, rule).unwrap();
        assert!(rule_id > 0);

        // Verify rule exists
        let rules = get_profile_rules(&conn, profile_id).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].field, "genre");
        assert_eq!(rules[0].operator, "eq");
        assert_eq!(rules[0].value, "Rock");
    }

    #[test]
    fn test_get_all_track_ids_union() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Create profile
        let profile_id =
            create_sync_profile(&conn, "Test".to_string(), PathBuf::from("/tmp/test")).unwrap();

        // Insert three test tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, genre)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                "Artist",
                "Artist",
                "Album",
                "Track1",
                "mp3",
                "/path/to/track1.mp3",
                "Rock"
            ],
        )
        .unwrap();
        let track1_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, genre)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                "Artist",
                "Artist",
                "Album",
                "Track2",
                "mp3",
                "/path/to/track2.mp3",
                "Jazz"
            ],
        )
        .unwrap();
        let track2_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, genre)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                "Artist",
                "Artist",
                "Album",
                "Track3",
                "mp3",
                "/path/to/track3.mp3",
                "Rock"
            ],
        )
        .unwrap();
        let track3_id = conn.last_insert_rowid();

        // 1. Add track1 manually
        add_manual_track(&conn, profile_id, track1_id).unwrap();

        // 2. Create playlist with track2 and add to profile
        conn.execute(
            "INSERT INTO playlists (name, category) VALUES (?1, ?2)",
            rusqlite::params!["Test Playlist", "regular"],
        )
        .unwrap();
        let playlist_id = conn.last_insert_rowid();
        conn.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?1, ?2, ?3)",
            rusqlite::params![playlist_id, track2_id, "a0"],
        )
        .unwrap();
        add_playlist(&conn, profile_id, playlist_id).unwrap();

        // 3. Add rule for genre=Rock (should match track1 and track3)
        let rule = FilterRule {
            id: None,
            field: "genre".to_string(),
            operator: "eq".to_string(),
            value: "Rock".to_string(),
        };
        add_rule(&conn, profile_id, rule).unwrap();

        // Get all track IDs (should be union of all three sources)
        let profile = get_sync_profile(&conn, profile_id).unwrap();
        let track_ids = profile.get_all_track_ids(&conn).unwrap();

        // Should contain all three tracks (track1 from manual, track2 from playlist, track3 from rule)
        assert_eq!(track_ids.len(), 3);
        assert!(track_ids.contains(&track1_id));
        assert!(track_ids.contains(&track2_id));
        assert!(track_ids.contains(&track3_id));
    }
}
