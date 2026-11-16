//! WebDAV sync-collection change log — a `SyncChangeLogSchema` instance
//! over `storage.folder_sync_changes` (see `sync_change_log_pg_repository.rs`
//! for the shared implementation; populated by triggers defined in
//! `migrations/20261115000000_folder_sync_changes.sql`).

use crate::infrastructure::repositories::pg::sync_change_log_pg_repository::{
    SyncChangeLogPgRepository, SyncChangeLogSchema,
};

pub struct FolderSyncChangeSchema;

impl SyncChangeLogSchema for FolderSyncChangeSchema {
    const TABLE: &'static str = "storage.folder_sync_changes";
    const WATERMARK_TABLE: &'static str = "storage.folder_sync_watermark";
    const COLLECTION_ID_COLUMN: &'static str = "collection_folder_id";
    const LABEL_COLUMN: &'static str = "member_href_name";
    const IS_COLLECTION_EXPR: &'static str = "member_type = 'folder'";
    const LOG_NAME: &'static str = "folder_sync_changes";
}

/// Type alias, not a newtype — `FolderSyncChangePgRepository::new(pool)`
/// keeps compiling unchanged at every existing DI/call site.
pub type FolderSyncChangePgRepository = SyncChangeLogPgRepository<FolderSyncChangeSchema>;
