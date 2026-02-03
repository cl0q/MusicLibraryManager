//! Tantivy index creation and document indexing.
//!
//! Provides full-text indexing for artist, album, and title fields.
//! Index is persisted to disk for fast startup.
//!
//! # Schema
//! - `artist`: TEXT | STORED - Artist name, searchable and stored
//! - `album`: TEXT | STORED - Album name, searchable and stored
//! - `title`: TEXT | STORED - Track title, searchable and stored
//! - `track_id`: u64 STORED - Database ID for result lookup

use std::path::Path;

use tantivy::schema::{Field, Schema, STORED, TEXT};
use tantivy::{Index, IndexWriter, TantivyDocument, TantivyError};

use crate::models::track::Track;

/// Holds the Tantivy index and field references.
///
/// Created via `create_index()` and used for document indexing.
pub struct SearchIndex {
    /// The underlying Tantivy index
    pub index: Index,
    /// Field reference for artist
    pub artist_field: Field,
    /// Field reference for album
    pub album_field: Field,
    /// Field reference for title
    pub title_field: Field,
    /// Field reference for track database ID
    pub id_field: Field,
}

/// Creates a new Tantivy index at the specified path.
///
/// The index schema includes:
/// - `artist`: Searchable and stored text field
/// - `album`: Searchable and stored text field
/// - `title`: Searchable and stored text field
/// - `track_id`: Stored u64 for database lookup
///
/// # Arguments
/// * `index_path` - Directory path for index storage (created if doesn't exist)
///
/// # Returns
/// * `Ok(SearchIndex)` - Index ready for document adding
/// * `Err(TantivyError)` - If index creation failed
///
/// # Example
/// ```ignore
/// use std::path::Path;
/// use music_library_manager::search::indexer::create_index;
///
/// let search_idx = create_index(Path::new("./search_index"))?;
/// ```
pub fn create_index(index_path: &Path) -> Result<SearchIndex, TantivyError> {
    let mut schema_builder = Schema::builder();

    // Add searchable + stored text fields for fuzzy matching
    let artist_field = schema_builder.add_text_field("artist", TEXT | STORED);
    let album_field = schema_builder.add_text_field("album", TEXT | STORED);
    let title_field = schema_builder.add_text_field("title", TEXT | STORED);

    // Add stored-only field for database ID lookup
    let id_field = schema_builder.add_u64_field("track_id", STORED);

    let schema = schema_builder.build();

    // Create directory if it doesn't exist
    std::fs::create_dir_all(index_path).map_err(|e| {
        TantivyError::IoError(std::sync::Arc::new(std::io::Error::new(
            e.kind(),
            format!("Failed to create index directory: {}", e),
        )))
    })?;

    // Create index in specified directory (persistent storage)
    let index = Index::create_in_dir(index_path, schema)?;

    Ok(SearchIndex {
        index,
        artist_field,
        album_field,
        title_field,
        id_field,
    })
}

/// Opens an existing Tantivy index from the specified path.
///
/// # Arguments
/// * `index_path` - Directory path where index is stored
///
/// # Returns
/// * `Ok(SearchIndex)` - Opened index ready for searching
/// * `Err(TantivyError)` - If index doesn't exist or is corrupted
pub fn open_index(index_path: &Path) -> Result<SearchIndex, TantivyError> {
    let index = Index::open_in_dir(index_path)?;
    let schema = index.schema();

    let artist_field = schema
        .get_field("artist")
        .map_err(|_| TantivyError::SchemaError("artist field not found".to_string()))?;
    let album_field = schema
        .get_field("album")
        .map_err(|_| TantivyError::SchemaError("album field not found".to_string()))?;
    let title_field = schema
        .get_field("title")
        .map_err(|_| TantivyError::SchemaError("title field not found".to_string()))?;
    let id_field = schema
        .get_field("track_id")
        .map_err(|_| TantivyError::SchemaError("track_id field not found".to_string()))?;

    Ok(SearchIndex {
        index,
        artist_field,
        album_field,
        title_field,
        id_field,
    })
}

/// Indexes a track document in the Tantivy index.
///
/// Extracts artist, album, title, and ID from the track and adds
/// as a searchable document.
///
/// # Arguments
/// * `writer` - IndexWriter obtained from SearchIndex
/// * `track` - Track to index (must have database ID)
/// * `search_index` - SearchIndex with field references
///
/// # Returns
/// * `Ok(())` - Document added (not yet committed)
/// * `Err(TantivyError)` - If document creation failed
///
/// # Note
/// Call `commit_index()` after adding documents to persist changes.
pub fn index_track(
    writer: &mut IndexWriter,
    track: &Track,
    search_index: &SearchIndex,
) -> Result<(), TantivyError> {
    let mut doc = TantivyDocument::new();

    doc.add_text(search_index.artist_field, &track.metadata.artist);
    doc.add_text(search_index.album_field, &track.metadata.album);
    doc.add_text(search_index.title_field, &track.metadata.title);

    if let Some(id) = track.id {
        doc.add_u64(search_index.id_field, id as u64);
    }

    writer.add_document(doc)?;
    Ok(())
}

/// Commits pending document changes to the index.
///
/// Must be called after `index_track()` to persist changes.
/// Commits are atomic - either all pending documents are written or none.
///
/// # Arguments
/// * `writer` - IndexWriter with pending documents
///
/// # Returns
/// * `Ok(())` - Changes committed successfully
/// * `Err(TantivyError)` - If commit failed
pub fn commit_index(writer: &mut IndexWriter) -> Result<(), TantivyError> {
    writer.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::track::TrackMetadata;
    use tempfile::tempdir;

    fn create_test_track(id: i64, artist: &str, album: &str, title: &str) -> Track {
        let metadata = TrackMetadata::new(
            artist.to_string(),
            artist.to_string(),
            album.to_string(),
            title.to_string(),
            None,
            None,
            None,
            None,
            "mp3".to_string(),
            format!("/path/to/{}.mp3", title),
        );
        Track::with_id(id, metadata, format!("{}/{}/{}.mp3", artist, album, title))
    }

    #[test]
    fn test_create_index() {
        let dir = tempdir().unwrap();
        let index_path = dir.path().join("search_index");

        let search_index = create_index(&index_path).unwrap();

        // Verify index directory was created
        assert!(index_path.exists(), "Index directory should be created");

        // Verify schema has expected fields
        let schema = search_index.index.schema();
        assert!(
            schema.get_field("artist").is_ok(),
            "artist field should exist"
        );
        assert!(
            schema.get_field("album").is_ok(),
            "album field should exist"
        );
        assert!(
            schema.get_field("title").is_ok(),
            "title field should exist"
        );
        assert!(
            schema.get_field("track_id").is_ok(),
            "track_id field should exist"
        );
    }

    #[test]
    fn test_index_track() {
        let dir = tempdir().unwrap();
        let index_path = dir.path().join("search_index");

        let search_index = create_index(&index_path).unwrap();
        let mut writer = search_index.index.writer(50_000_000).unwrap();

        let track = create_test_track(1, "The Beatles", "Abbey Road", "Come Together");

        // Index should succeed
        let result = index_track(&mut writer, &track, &search_index);
        assert!(result.is_ok(), "Indexing track should succeed");

        // Commit should succeed
        let commit_result = commit_index(&mut writer);
        assert!(commit_result.is_ok(), "Commit should succeed");
    }

    #[test]
    fn test_open_existing_index() {
        let dir = tempdir().unwrap();
        let index_path = dir.path().join("search_index");

        // Create and populate index
        {
            let search_index = create_index(&index_path).unwrap();
            let mut writer = search_index.index.writer(50_000_000).unwrap();
            let track = create_test_track(1, "Daft Punk", "Discovery", "One More Time");
            index_track(&mut writer, &track, &search_index).unwrap();
            commit_index(&mut writer).unwrap();
        }

        // Reopen index
        let reopened = open_index(&index_path);
        assert!(reopened.is_ok(), "Should be able to reopen existing index");

        let search_index = reopened.unwrap();
        let reader = search_index.index.reader().unwrap();
        let searcher = reader.searcher();

        // Verify document count
        assert_eq!(
            searcher.num_docs(),
            1,
            "Should have 1 document after reopen"
        );
    }
}
