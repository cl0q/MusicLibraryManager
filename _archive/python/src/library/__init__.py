# Library module - database, metadata, indexing, import, duplicate detection

from src.library.database import (
    init_database,
    save_file_record,
    get_file_by_path,
    get_file_by_id,
    get_all_files,
    find_potential_duplicates,
    mark_as_duplicate,
    get_duplicates,
)

from src.library.metadata import (
    extract_metadata,
    MetadataExtractionError,
)

from src.library.sanitizer import (
    sanitize_filename,
    sanitize_path,
)

from src.library.importer import (
    import_directory,
    scan_directory,
    display_import_summary,
)
