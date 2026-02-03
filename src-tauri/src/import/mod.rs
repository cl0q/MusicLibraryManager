//! Import module for adding music files to the library.
//!
//! Provides:
//! - Directory scanning for audio files
//! - Batch import with atomic transactions
//! - Continue-on-error metadata extraction
//!
//! # Example
//! ```ignore
//! use std::path::Path;
//! use music_library_manager::import::{scan_directory, import_batch};
//! use music_library_manager::database::get_connection;
//!
//! // Scan directory for audio files
//! let files = scan_directory(Path::new("/music"))?;
//!
//! // Import to database
//! let mut conn = get_connection(Path::new("library.db"))?;
//! let result = import_batch(&mut conn, files)?;
//! println!("Imported {} files", result.succeeded);
//! ```

pub mod importer;
pub mod scanner;

// Re-export commonly used items
pub use importer::{import_batch, ImportResult};
pub use scanner::{scan_directory, ScanError};
