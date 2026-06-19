-- ════════════════════════════════════════════════════════════════════════
-- Places (photo map): partial index for fast bounding-box scans over the
-- caller's geotagged photos. Plain B-tree on (longitude, latitude); no
-- PostGIS required. The partial predicate keeps the index small — only rows
-- that actually carry GPS coordinates are indexed.
-- ════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_file_metadata_geo
    ON storage.file_metadata (longitude, latitude)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
