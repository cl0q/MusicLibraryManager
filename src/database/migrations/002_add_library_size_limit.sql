-- Migration 002: Ensure library_size_limit support in app_config
--
-- Records the migration system activation version in app_config.
-- The library_size_limit_gb key is managed dynamically via Settings UI
-- (inserted/deleted by set_library_size_limit command), so we only
-- document its existence here rather than inserting a default.

INSERT OR IGNORE INTO app_config (key, value, updated_at)
VALUES ('_migration_system_version', '2', CURRENT_TIMESTAMP);
