-- ════════════════════════════════════════════════════════════════════════
-- People / Faces: per-user face detections and identity clusters.
--
-- Embeddings are stored as BYTEA (512 × float32, L2-normalized = 2048 bytes)
-- rather than a pgvector column, so the feature adds NO new PostgreSQL
-- extension dependency. Similarity is computed in-app (brute-force cosine
-- scales comfortably to ~100k faces); pgvector / VectorChord with an HNSW
-- index is the documented upgrade path for larger libraries.
--
-- Biometric data — the feature is OFF by default (OXICLOUD_ENABLE_FACES) and
-- opt-in per user. All rows cascade-delete with their owning user, and face
-- rows cascade-delete with their source file, satisfying the right to erasure.
-- ════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS faces;

-- An identity cluster ("person"). display_name is NULL until the user names it.
CREATE TABLE IF NOT EXISTS faces.persons (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name  TEXT,
    cover_face_id UUID,                       -- representative face (set by the app)
    is_hidden     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_persons_user ON faces.persons (user_id);

-- A single detected face with its embedding and (optional) person assignment.
CREATE TABLE IF NOT EXISTS faces.faces (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id    UUID NOT NULL REFERENCES storage.files(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES auth.users(id)   ON DELETE CASCADE,
    person_id  UUID REFERENCES faces.persons(id) ON DELETE SET NULL,
    bbox       REAL[] NOT NULL,               -- [x, y, w, h], normalized 0..1
    det_score  REAL NOT NULL,                 -- detector confidence
    quality    REAL,                          -- blur/size gate score (nullable)
    embedding  BYTEA NOT NULL,                -- 512 × float32, L2-normalized
    blob_hash  VARCHAR(64),                   -- dedup-aware reuse across identical files
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_faces_user   ON faces.faces (user_id);
CREATE INDEX IF NOT EXISTS idx_faces_person ON faces.faces (person_id);
CREATE INDEX IF NOT EXISTS idx_faces_file   ON faces.faces (file_id);
CREATE INDEX IF NOT EXISTS idx_faces_blob   ON faces.faces (blob_hash);
