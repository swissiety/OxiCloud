//! Domain persistence port for the RFC 6578 `sync-collection` change logs:
//! WebDAV folders (`storage.folder_sync_changes`), CalDAV calendars
//! (`caldav.calendar_sync_changes`) and CardDAV address books
//! (`carddav.contact_sync_changes`), each with a per-collection
//! `*_sync_watermark` table.
//!
//! The logs are populated entirely by DB triggers (see the
//! `migrations/*_sync_changes.sql` files). This port is read-only plus the
//! retention sweep's cleanup calls: no repository method writes a change
//! row, and the application layer must never duplicate that bookkeeping.
//!
//! One trait for all three. A WebDAV collection mixes folders and files,
//! which shows up here only as [`SyncChangeRow::is_collection`]; the
//! sequencing, collapsing, expiry and retention rules are identical.

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::common::errors::DomainError;

/// What happened to the member, as recorded at trigger time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncChangeKind {
    Created,
    Updated,
    Deleted,
}

/// One raw change-log row, before the application layer resolves
/// `Created`/`Updated` members to their current DTO.
#[derive(Debug, Clone)]
pub struct SyncChangeRow {
    pub member_id: Uuid,
    /// The member's last-known href segment, captured when the row was
    /// logged: the leaf name for WebDAV, the iCalendar / vCard UID for
    /// CalDAV / CardDAV. A `Deleted` row needs nothing else to render its
    /// 404 sub-response, so the member row may already be gone.
    pub label: String,
    pub kind: SyncChangeKind,
    /// The member is itself a collection (a WebDAV subfolder), so its href
    /// takes a trailing slash. Always `false` for calendars and address
    /// books, whose members are never containers.
    pub is_collection: bool,
}

pub trait SyncChangeLogRepository: Send + Sync + 'static {
    /// Every change recorded for `collection_id` with `seq > since_seq`
    /// (`None` = since the beginning), collapsed to at most one row per
    /// `member_id`, the latest `seq` winning. Collapsing nets churn such as
    /// trash-then-restore within one poll window down to its single real
    /// outcome instead of contradictory duplicates.
    ///
    /// Returns the rows plus the collection's max `seq` (0 if it has no
    /// change-log activity). The caller mints the response's sync-token from
    /// that value; the delta query is bounded by it, so the rows and the
    /// token describe the same snapshot.
    async fn changes_since(
        &self,
        collection_id: Uuid,
        since_seq: Option<u64>,
    ) -> Result<(Vec<SyncChangeRow>, u64), DomainError>;

    /// Whether `seq` predates `collection_id`'s retention watermark: the
    /// rows that would answer `changes_since(collection_id, Some(seq))` are
    /// already purged, so the client must discard local state and restart
    /// with a full sync (RFC 6578 §3.6, HTTP 507).
    ///
    /// Per collection, not global: `seq` is one `IDENTITY` sequence shared
    /// by every collection of a log, so a global watermark would let a busy
    /// collection's purged rows falsely expire a quiet sibling's still-valid
    /// token. A collection with no watermark row has never had rows purged,
    /// so it is never expired.
    async fn is_seq_expired(&self, collection_id: Uuid, seq: u64) -> Result<bool, DomainError>;

    /// The collection's current max `seq` (0 if none), for the token an
    /// initial sync hands back. Cheaper than `changes_since(.., None)`,
    /// which would walk and discard the full history to read the same
    /// number.
    async fn current_seq(&self, collection_id: Uuid) -> Result<u64, DomainError>;

    /// Retention sweep: deletes every row with `changed_at < cutoff` and
    /// raises each affected collection's watermark to the highest `seq`
    /// deleted for it (never lowering it), in one statement, so a crash
    /// mid-sweep cannot advance a watermark past rows that still exist and
    /// wrongly expire a valid token. Returns the number of rows deleted.
    async fn delete_expired_before(&self, cutoff: DateTime<Utc>) -> Result<u64, DomainError>;

    /// Row-count cap, independent of the time-based cutoff: for every
    /// collection with more than `max_rows` rows, deletes the oldest excess
    /// rows and advances that collection's watermark the same way. Guards
    /// against one very busy collection ballooning the table within the
    /// retention window. Returns the number of rows deleted.
    async fn enforce_row_cap(&self, max_rows: u32) -> Result<u64, DomainError>;
}
