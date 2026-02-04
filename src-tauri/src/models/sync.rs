//! Sync profile data models for Tauri IPC.
//!
//! Contains DTOs for device sync profiles:
//! - `SyncProfileDto` - Complete profile with computed statistics
//! - `FilterRuleDto` - Filter rule for query-based track selection

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::sync::profile::{FilterRule, SyncProfile};

/// Sync profile DTO with computed statistics.
///
/// Includes track counts and metadata for UI display.
/// All counts are computed at DTO creation time.
#[derive(Debug, Serialize, Deserialize)]
pub struct SyncProfileDto {
    pub id: i64,
    pub name: String,
    pub output_folder: String,
    pub track_count: usize,         // Total unique tracks (union of all sources)
    pub manual_track_count: usize,  // Manually added tracks
    pub playlist_count: usize,      // Number of playlists included
    pub rule_count: usize,          // Number of filter rules
    pub date_created: String,
    pub date_modified: String,
}

impl SyncProfileDto {
    /// Create DTO from SyncProfile with computed counts.
    ///
    /// # Arguments
    /// * `profile` - SyncProfile to convert
    /// * `conn` - Database connection for computing counts
    ///
    /// # Returns
    /// * `Ok(SyncProfileDto)` with all counts populated
    /// * `Err` if database queries fail
    pub fn from_profile(profile: SyncProfile, conn: &Connection) -> crate::database::connection::Result<Self> {
        // Get total unique track count
        let track_ids = profile.get_all_track_ids(conn)?;
        let track_count = track_ids.len();

        // Get manual track count
        let manual_track_count: usize = conn.query_row(
            "SELECT COUNT(*) FROM sync_profile_tracks WHERE profile_id = ?1",
            [profile.id],
            |row| row.get(0),
        )?;

        // Get playlist count
        let playlist_count: usize = conn.query_row(
            "SELECT COUNT(*) FROM sync_profile_playlists WHERE profile_id = ?1",
            [profile.id],
            |row| row.get(0),
        )?;

        // Get rule count
        let rule_count: usize = conn.query_row(
            "SELECT COUNT(*) FROM sync_profile_rules WHERE profile_id = ?1",
            [profile.id],
            |row| row.get(0),
        )?;

        Ok(SyncProfileDto {
            id: profile.id,
            name: profile.name,
            output_folder: profile.output_folder.to_string_lossy().to_string(),
            track_count,
            manual_track_count,
            playlist_count,
            rule_count,
            date_created: profile.date_created,
            date_modified: profile.date_modified,
        })
    }
}

/// Filter rule DTO for Tauri IPC.
///
/// Simplified version of FilterRule for frontend communication.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FilterRuleDto {
    pub id: Option<i64>,
    pub field: String,    // "genre" | "source" | "date_added" | "artist" | "bitrate" | "tag"
    pub operator: String, // "eq" | "ne" | "gt" | "lt" | "contains" | "in"
    pub value: String,    // Filter value
}

impl From<FilterRuleDto> for FilterRule {
    fn from(dto: FilterRuleDto) -> Self {
        FilterRule {
            id: dto.id,
            field: dto.field,
            operator: dto.operator,
            value: dto.value,
        }
    }
}

impl From<FilterRule> for FilterRuleDto {
    fn from(rule: FilterRule) -> Self {
        FilterRuleDto {
            id: rule.id,
            field: rule.field,
            operator: rule.operator,
            value: rule.value,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{connection::get_memory_connection, schema::initialize_schema};
    use crate::sync::profile::create_sync_profile;
    use std::path::PathBuf;

    #[test]
    fn test_sync_profile_dto_from_profile() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Create a profile
        let profile_id = create_sync_profile(
            &conn,
            "Test Profile".to_string(),
            PathBuf::from("/tmp/test"),
        )
        .unwrap();

        // Get profile and convert to DTO
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();
        let dto = SyncProfileDto::from_profile(profile, &conn).unwrap();

        assert_eq!(dto.name, "Test Profile");
        assert_eq!(dto.output_folder, "/tmp/test");
        assert_eq!(dto.track_count, 0);
        assert_eq!(dto.manual_track_count, 0);
        assert_eq!(dto.playlist_count, 0);
        assert_eq!(dto.rule_count, 0);
    }

    #[test]
    fn test_filter_rule_dto_conversion() {
        let dto = FilterRuleDto {
            id: Some(1),
            field: "genre".to_string(),
            operator: "eq".to_string(),
            value: "Rock".to_string(),
        };

        let rule: FilterRule = dto.clone().into();
        assert_eq!(rule.id, Some(1));
        assert_eq!(rule.field, "genre");
        assert_eq!(rule.operator, "eq");
        assert_eq!(rule.value, "Rock");

        let dto_back: FilterRuleDto = rule.into();
        assert_eq!(dto_back.id, Some(1));
        assert_eq!(dto_back.field, "genre");
    }
}
