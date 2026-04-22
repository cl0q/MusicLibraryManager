//! Database module for music library storage.
//!
//! Provides SQLite database access with:
//! - Schema management (tracks table with metadata fields)
//! - Connection management with foreign key enforcement
//! - Transaction wrappers for atomic operations
//!
//! # Example
//! ```ignore
//! use std::path::Path;
//! use music_library_manager::database::{get_connection, with_transaction};
//!
//! // Open or create database
//! let conn = get_connection(Path::new("library.db"))?;
//!
//! // Perform atomic operations
//! with_transaction(&conn, |tx| {
//!     tx.execute("INSERT INTO tracks ...", [])?;
//!     Ok(())
//! })?;
//! ```

pub mod connection;
pub mod playlist;
pub mod schema;
pub mod track_analysis;
pub mod tracks;

// Re-export commonly used items
pub use connection::{db_path, get_connection, get_memory_connection, init_db_path, with_transaction, DatabaseError, Result};
pub use schema::initialize_schema;
