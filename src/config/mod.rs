//! Configuration module for library settings.
//!
//! Provides configuration management for library paths and settings.

pub mod library;

pub use library::{LibraryConfig, MarkerFile, create_marker_file, verify_marker_file};
