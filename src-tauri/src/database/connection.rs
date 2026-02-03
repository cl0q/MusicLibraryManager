//! Database connection management with foreign key enforcement.
//!
//! Provides connection creation and transaction wrappers that ensure
//! PRAGMA foreign_keys = ON is always enabled.

use std::path::Path;

use rusqlite::{Connection, Transaction};
use thiserror::Error;

/// Database error types.
#[derive(Debug, Error)]
pub enum DatabaseError {
    /// SQLite operation failed
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// Connection setup failed
    #[error("Connection failed: {0}")]
    Connection(String),
}

/// Result type for database operations.
pub type Result<T> = std::result::Result<T, DatabaseError>;

/// Opens or creates a SQLite database with foreign key enforcement.
///
/// CRITICAL: SQLite has `PRAGMA foreign_keys = OFF` by default.
/// This function enables foreign keys immediately after opening.
///
/// # Arguments
/// * `db_path` - Path to the database file (created if doesn't exist)
///
/// # Returns
/// * `Ok(Connection)` with foreign keys enabled and schema initialized
/// * `Err(DatabaseError)` if connection or initialization failed
///
/// # Example
/// ```ignore
/// use std::path::Path;
/// use music_library_manager::database::get_connection;
///
/// let conn = get_connection(Path::new("library.db"))?;
/// // Foreign keys are now enforced
/// ```
pub fn get_connection(db_path: &Path) -> Result<Connection> {
    let conn = Connection::open(db_path)?;

    // CRITICAL: Enable foreign keys (default is OFF in SQLite)
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    // Initialize schema (idempotent - safe to call every time)
    crate::database::schema::initialize_schema(&conn)?;

    Ok(conn)
}

/// Opens an in-memory database for testing.
///
/// Creates a temporary database with foreign keys enabled and schema initialized.
/// Data is lost when connection is dropped.
///
/// # Returns
/// * `Ok(Connection)` with foreign keys enabled and schema initialized
/// * `Err(DatabaseError)` if initialization failed
pub fn get_memory_connection() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;

    // Enable foreign keys
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    // Initialize schema
    crate::database::schema::initialize_schema(&conn)?;

    Ok(conn)
}

/// Executes a closure within a transaction.
///
/// Provides atomic operation semantics:
/// - Creates a transaction before calling the closure
/// - Commits on `Ok` return
/// - Rolls back on `Err` return or panic
///
/// # Arguments
/// * `conn` - Database connection
/// * `f` - Closure that performs database operations
///
/// # Returns
/// * `Ok(T)` with the closure's return value if committed successfully
/// * `Err(DatabaseError)` if the closure failed or commit failed
///
/// # Example
/// ```ignore
/// use music_library_manager::database::{get_memory_connection, with_transaction};
///
/// let mut conn = get_memory_connection()?;
/// let result = with_transaction(&mut conn, |tx| {
///     tx.execute("INSERT INTO tracks (...) VALUES (...)", [])?;
///     Ok(42)
/// })?;
/// assert_eq!(result, 42);
/// ```
pub fn with_transaction<F, T>(conn: &mut Connection, f: F) -> Result<T>
where
    F: FnOnce(&Transaction) -> Result<T>,
{
    let tx = conn.transaction()?;
    let result = f(&tx)?;
    tx.commit()?; // Explicit commit required (implicit rollback on drop)
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_foreign_keys_enabled() {
        let conn = get_memory_connection().unwrap();

        // Verify PRAGMA foreign_keys is ON
        let fk_status: i32 = conn
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
            .unwrap();
        assert_eq!(fk_status, 1, "Foreign keys should be enabled");
    }

    #[test]
    fn test_schema_initialized() {
        let conn = get_memory_connection().unwrap();

        // Verify tracks table exists
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tracks'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "tracks table should exist");
    }

    #[test]
    fn test_file_connection_creates_db() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("test.db");

        let conn = get_connection(&db_path).unwrap();

        // Verify file was created
        assert!(db_path.exists(), "Database file should be created");

        // Verify foreign keys enabled
        let fk_status: i32 = conn
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
            .unwrap();
        assert_eq!(fk_status, 1, "Foreign keys should be enabled");

        drop(conn);
        fs::remove_file(&db_path).ok();
    }

    #[test]
    fn test_transaction_commits_on_success() {
        let mut conn = get_memory_connection().unwrap();

        let result = with_transaction(&mut conn, |tx| {
            tx.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES ('Test Artist', 'Test Artist', 'Test Album', 'Test Song', 'mp3', '/path/to/song.mp3')",
                [],
            )?;
            Ok(42)
        });

        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);

        // Verify data was committed
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "Track should be inserted");
    }

    #[test]
    fn test_transaction_rollback_on_error() {
        let mut conn = get_memory_connection().unwrap();

        // Insert a track first
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song', 'mp3', '/path/song.mp3')",
            [],
        )
        .unwrap();

        // Try to insert duplicate (should fail due to UNIQUE constraint on original_path)
        let result = with_transaction(&mut conn, |tx| {
            tx.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES ('Artist 2', 'Artist 2', 'Album 2', 'Song 2', 'mp3', '/path/song.mp3')",
                [],
            )?;
            Ok(())
        });

        assert!(result.is_err(), "Should fail due to UNIQUE constraint");

        // Verify only original track exists (transaction rolled back)
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "Only original track should exist");
    }
}
