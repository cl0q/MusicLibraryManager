//! Versioned database migration system.
//!
//! Manages schema evolution through numbered SQL migration files.
//! Tracks applied migrations in a `_migrations` table for reliable
//! version tracking and audit trail.
//!
//! ## Adding a new migration
//!
//! 1. Create `NNN_description.sql` in this directory (zero-padded 3-digit number)
//! 2. Add a `Migration` entry to the `MIGRATIONS` array below
//! 3. The migration runs automatically on next `get_connection()` call
//!
//! ## Backward compatibility
//!
//! Existing databases that used the old `PRAGMA user_version` system (versions 1–13)
//! are detected automatically. Migration 001 is marked as already applied since the
//! full schema is already present.

use rusqlite::Connection;

use crate::database::connection::Result;

/// A numbered database migration.
struct Migration {
    /// Sequential version number (1, 2, 3, ...).
    version: i32,
    /// Human-readable name matching the SQL filename.
    name: &'static str,
    /// SQL statements to execute.
    sql: &'static str,
}

/// All migrations in application order.
///
/// New migrations are appended here with the next sequential version number.
/// The SQL is embedded at compile time via `include_str!`.
const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "001_initial_schema",
        sql: include_str!("001_initial_schema.sql"),
    },
    Migration {
        version: 2,
        name: "002_add_library_size_limit",
        sql: include_str!("002_add_library_size_limit.sql"),
    },
];

/// Create the `_migrations` tracking table if it doesn't exist.
fn ensure_migrations_table(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS _migrations (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );",
    )?;
    Ok(())
}

/// Get the current migration version (highest applied version, or 0 if none).
pub fn get_migration_version(conn: &Connection) -> Result<i32> {
    ensure_migrations_table(conn)?;
    let version: i32 = conn.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM _migrations",
        [],
        |row| row.get(0),
    )?;
    Ok(version)
}

/// Get list of applied migrations as `(version, name, applied_at)` tuples.
pub fn get_applied_migrations(conn: &Connection) -> Result<Vec<(i32, String, String)>> {
    ensure_migrations_table(conn)?;
    let mut stmt =
        conn.prepare("SELECT version, name, applied_at FROM _migrations ORDER BY version")?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, i32>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Run all pending migrations.
///
/// For backward compatibility with existing databases that used `PRAGMA user_version`:
/// - If the database has `user_version >= 13` (the old migration system's latest version)
///   but no entries in `_migrations`, migration 001 is marked as already applied
///   since the full schema is already present.
/// - New databases get all migrations applied from scratch.
///
/// Each migration is logged at INFO level when applied.
pub fn run_pending_migrations(conn: &Connection) -> Result<()> {
    ensure_migrations_table(conn)?;

    // Backward compatibility: detect databases from old PRAGMA user_version system
    let old_version: i32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    let migration_count: i32 =
        conn.query_row("SELECT COUNT(*) FROM _migrations", [], |row| row.get(0))?;

    if old_version >= 13 && migration_count == 0 {
        // Existing database from the old migration system — schema is already at v13.
        // Seed _migrations with v1 so 001_initial_schema is not re-run.
        log::info!(
            "Detected existing database (PRAGMA user_version={}). Seeding _migrations table.",
            old_version
        );
        conn.execute(
            "INSERT INTO _migrations (version, name, applied_at) VALUES (?1, ?2, CURRENT_TIMESTAMP)",
            rusqlite::params![1, "001_initial_schema"],
        )?;
    }

    // Apply each pending migration
    for migration in MIGRATIONS {
        let already_applied: bool = conn.query_row(
            "SELECT COUNT(*) > 0 FROM _migrations WHERE version = ?1",
            [migration.version],
            |row| row.get(0),
        )?;

        if already_applied {
            continue;
        }

        log::info!(
            "Applying migration v{} ({})...",
            migration.version,
            migration.name
        );

        conn.execute_batch(migration.sql)?;

        conn.execute(
            "INSERT INTO _migrations (version, name, applied_at) VALUES (?1, ?2, CURRENT_TIMESTAMP)",
            rusqlite::params![migration.version, migration.name],
        )?;

        log::info!(
            "Migration v{} ({}) applied successfully.",
            migration.version,
            migration.name
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn
    }

    #[test]
    fn test_fresh_database_gets_all_migrations() {
        let conn = setup_conn();
        run_pending_migrations(&conn).unwrap();

        let version = get_migration_version(&conn).unwrap();
        assert_eq!(version, 2);

        let applied = get_applied_migrations(&conn).unwrap();
        assert_eq!(applied.len(), 2);
        assert_eq!(applied[0].0, 1);
        assert_eq!(applied[0].1, "001_initial_schema");
        assert_eq!(applied[1].0, 2);
        assert_eq!(applied[1].1, "002_add_library_size_limit");
    }

    #[test]
    fn test_existing_database_skips_001() {
        let conn = setup_conn();

        // Simulate an existing database at user_version 13
        conn.execute_batch("PRAGMA user_version = 13;").unwrap();
        // Create at least one table so it looks like a real database
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS app_config (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT DEFAULT CURRENT_TIMESTAMP
            );",
        )
        .unwrap();

        run_pending_migrations(&conn).unwrap();

        let applied = get_applied_migrations(&conn).unwrap();
        assert_eq!(applied.len(), 2);
        // 001 was seeded (not executed), 002 was executed
        assert_eq!(applied[0].1, "001_initial_schema");
        assert_eq!(applied[1].1, "002_add_library_size_limit");
    }

    #[test]
    fn test_idempotent_migrations() {
        let conn = setup_conn();

        run_pending_migrations(&conn).unwrap();
        run_pending_migrations(&conn).unwrap();

        let applied = get_applied_migrations(&conn).unwrap();
        assert_eq!(applied.len(), 2);
    }

    #[test]
    fn test_migrations_table_created() {
        let conn = setup_conn();
        ensure_migrations_table(&conn).unwrap();

        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_migrations'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_tables_created_by_001() {
        let conn = setup_conn();
        run_pending_migrations(&conn).unwrap();

        let tables = [
            "tracks",
            "sources",
            "track_sources",
            "last_sync_timestamps",
            "playlists",
            "playlist_tracks",
            "playlist_tags",
            "sync_profiles",
            "sync_profile_tracks",
            "sync_profile_playlists",
            "sync_profile_rules",
            "sync_state",
            "fingerprints",
            "artwork",
            "replaygain",
            "review_queue",
            "app_config",
            "track_analysis",
        ];

        for table in &tables {
            let count: i32 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "Table {} should exist", table);
        }
    }

    #[test]
    fn test_get_migration_version_empty() {
        let conn = setup_conn();
        let version = get_migration_version(&conn).unwrap();
        assert_eq!(version, 0);
    }
}
