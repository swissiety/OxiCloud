-- Garbage-collection safety for orphaned blobs.
--
-- The dedup GC deletes a blob row (committed) and then unlinks the backing
-- file. A concurrent uploader of identical content can re-reference a chunk in
-- that window. Two mechanisms make the sweep safe:
--   (a) garbage_collect() never collects a blob still referenced by a manifest
--       (chunk) or a file (legacy whole-file blob) — cross-checks backed by
--       idx_chunk_manifests_chunk_hashes_gin and idx_files_blob_hash. A stale
--       ref_count = 0 on live content can then only delay collection, never
--       delete it.
--   (b) garbage_collect() never collects a blob that became unreferenced only
--       moments ago — the grace period below, mirroring git's gc.pruneExpire,
--       so a writer about to pin a just-orphaned chunk cannot race the sweep.
--
-- `orphaned_at` records when ref_count last reached 0. NULL means the row is
-- referenced (ref_count > 0) or predates this column.

ALTER TABLE storage.blobs ADD COLUMN IF NOT EXISTS orphaned_at TIMESTAMPTZ;

-- Existing orphans start their grace window now, so applying this migration
-- never triggers an immediate sweep of content a writer might still be racing.
UPDATE storage.blobs
   SET orphaned_at = now()
 WHERE ref_count <= 0 AND orphaned_at IS NULL;

-- GC scan index: orphan rows ordered by when they became collectible. Replaces
-- the old ref_count-only partial index (the GC now also filters on orphaned_at).
DROP INDEX IF EXISTS storage.idx_blobs_orphaned;
CREATE INDEX IF NOT EXISTS idx_blobs_gc_eligible
    ON storage.blobs (orphaned_at) WHERE ref_count = 0;

-- Stamp orphaned_at when a file delete drops a blob's ref_count to 0, so the
-- grace window starts at the moment of orphaning. No-op for multi-chunk files
-- whose file_hash is not itself a storage.blobs row.
CREATE OR REPLACE FUNCTION storage.decrement_blob_ref()
RETURNS trigger AS $$
BEGIN
    UPDATE storage.blobs
       SET ref_count   = GREATEST(ref_count - 1, 0),
           orphaned_at = CASE WHEN GREATEST(ref_count - 1, 0) = 0 THEN now() ELSE orphaned_at END
     WHERE hash = OLD.blob_hash;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

COMMENT ON COLUMN storage.blobs.orphaned_at IS
    'When ref_count last reached 0; GC waits a grace period past this before deleting (NULL = referenced or pre-migration)';
