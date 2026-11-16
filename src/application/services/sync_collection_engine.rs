//! Shared engine behind every `sync-collection` service — WebDAV folders,
//! CalDAV calendars and CardDAV address books resolve their change log
//! into `SyncDelta<M>` with identical control flow: authz gate → expiry
//! check → changes_since → drop stale tombstones → one batch lookup of the
//! still-live members → tombstone whatever the lookup no longer finds.
//!
//! Authz here assumes a grant-only engine — see
//! `application::ports::change_log_port`'s module doc for the reasoning
//! and why deny rules would need this revisited.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use uuid::Uuid;

use crate::application::ports::authorization_ports::AuthorizationEngine;
use crate::application::ports::change_log_port::{SyncChange, SyncDelta};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::repositories::sync_change_log_repository::{
    SyncChangeKind, SyncChangeLogRepository, SyncChangeRow,
};
use crate::domain::services::authorization::{Permission, Resource, Subject};
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

/// Per-domain hook resolving the `Created`/`Updated` rows of one delta to
/// their current DTOs, in one batch.
///
/// Returns the members that still exist, keyed by `member_id`. A row whose
/// id is missing from the map is **gone** (hard-deleted, purged or trashed
/// after it was logged) and the engine emits a tombstone for it. Any lookup
/// failure must be `Err`: a read failure is never proof of absence, and a
/// wrongly emitted tombstone makes the client delete data that still exists.
///
/// One call per REPORT, never one per row: a delta can hold up to the
/// per-collection row cap (default 20k), and a per-row lookup would turn
/// that into as many database round trips.
pub trait SyncMemberResolver: Send + Sync + 'static {
    type Member;
    async fn resolve_batch(
        &self,
        collection_id: Uuid,
        rows: &[&SyncChangeRow],
    ) -> Result<HashMap<Uuid, Self::Member>, DomainError>;
}

pub struct SyncCollectionEngine<L, R, A = PgAclEngine>
where
    L: SyncChangeLogRepository,
    R: SyncMemberResolver,
    A: AuthorizationEngine,
{
    change_log: Arc<L>,
    resolver: R,
    authz: Arc<A>,
    /// `Resource::Folder` / `Resource::Calendar` / `Resource::AddressBook`
    /// are themselves valid `fn(Uuid) -> Resource` values (tuple-variant
    /// constructors) — no closure needed.
    resource_of: fn(Uuid) -> Resource,
    /// Turns a row's `label` into the `href_hint` a `Deleted` entry
    /// carries (the bare name for WebDAV, `"{label}.vcf"` for CardDAV).
    label_to_href_hint: fn(&str) -> String,
    /// `entity_type` passed to `DomainError::sync_token_expired`.
    error_tag: &'static str,
}

impl<L, R, A> SyncCollectionEngine<L, R, A>
where
    L: SyncChangeLogRepository,
    R: SyncMemberResolver,
    A: AuthorizationEngine,
{
    pub fn new(
        change_log: Arc<L>,
        resolver: R,
        authz: Arc<A>,
        resource_of: fn(Uuid) -> Resource,
        label_to_href_hint: fn(&str) -> String,
        error_tag: &'static str,
    ) -> Self {
        Self {
            change_log,
            resolver,
            authz,
            resource_of,
            label_to_href_hint,
            error_tag,
        }
    }

    async fn require_read(&self, collection_id: Uuid, caller_id: Uuid) -> Result<(), DomainError> {
        self.authz
            .require(
                Subject::User(caller_id),
                Permission::Read,
                (self.resource_of)(collection_id),
            )
            .await
    }

    /// Mints the token an **initial** sync response should hand back
    /// (empty/absent client `sync-token`). Cheaper than routing through
    /// `list_changes_with_perms`, which would also walk the collection's
    /// full change history only to discard it.
    pub async fn mint_initial_token(
        &self,
        collection_id: Uuid,
        caller_id: Uuid,
    ) -> Result<SyncToken, DomainError> {
        self.require_read(collection_id, caller_id).await?;
        let seq = self.change_log.current_seq(collection_id).await?;
        Ok(SyncToken::mint(collection_id, seq))
    }

    /// Resolves the delta for `collection_id` since `since_token`.
    ///
    /// Returns `Err(ErrorKind::SyncTokenExpired)` (→ HTTP 507) when
    /// `since_token` predates the retention watermark — the caller must
    /// discard local state and restart with a fresh initial sync.
    pub async fn list_changes_with_perms(
        &self,
        collection_id: Uuid,
        since_token: Option<SyncToken>,
        caller_id: Uuid,
    ) -> Result<SyncDelta<R::Member>, DomainError> {
        self.require_read(collection_id, caller_id).await?;

        if let Some(token) = since_token
            && self
                .change_log
                .is_seq_expired(collection_id, token.seq())
                .await?
        {
            return Err(DomainError::sync_token_expired(
                self.error_tag,
                format!(
                    "sync-token seq {} for collection {} predates the retention window",
                    token.seq(),
                    collection_id
                ),
            ));
        }

        let since_seq = since_token.map(|t| t.seq());
        let (rows, new_seq) = self
            .change_log
            .changes_since(collection_id, since_seq)
            .await?;

        // A `label` (→ href) can appear on more than one row in this
        // batch: a delete followed by a fresh create of the same name
        // within one poll window mints a brand-new `member_id` (CalDAV /
        // CardDAV "update" is delete+recreate too), so it yields a
        // tombstone for the old id and a creation for the new one. The
        // response renders upserts and deletions as separate buckets,
        // which can't express "this happened before that", so a stale
        // tombstone sharing a href with a live row in the SAME batch is
        // dropped here — the href demonstrably still exists.
        let live: Vec<&SyncChangeRow> = rows
            .iter()
            .filter(|r| r.kind != SyncChangeKind::Deleted)
            .collect();
        let live_labels: HashSet<&str> = live.iter().map(|r| r.label.as_str()).collect();

        let mut resolved = if live.is_empty() {
            HashMap::new()
        } else {
            self.resolver.resolve_batch(collection_id, &live).await?
        };

        let mut changes = Vec::with_capacity(rows.len());
        for row in &rows {
            let member = match row.kind {
                SyncChangeKind::Deleted if live_labels.contains(row.label.as_str()) => continue,
                SyncChangeKind::Deleted => None,
                SyncChangeKind::Created | SyncChangeKind::Updated => {
                    resolved.remove(&row.member_id)
                }
            };
            changes.push(match member {
                Some(member) => SyncChange::Upserted(member),
                None => SyncChange::Deleted {
                    member_id: row.member_id,
                    href_hint: (self.label_to_href_hint)(&row.label),
                    is_collection: row.is_collection,
                },
            });
        }

        Ok(SyncDelta {
            changes,
            new_token: SyncToken::mint(collection_id, new_seq),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::ports::authorization_ports::test_support::FakeEngine;
    use crate::domain::errors::ErrorKind;
    use chrono::{DateTime, Utc};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Change log that returns a fixed batch, never expired.
    struct FixedLog(Vec<SyncChangeRow>);

    impl SyncChangeLogRepository for FixedLog {
        async fn changes_since(
            &self,
            _: Uuid,
            _: Option<u64>,
        ) -> Result<(Vec<SyncChangeRow>, u64), DomainError> {
            Ok((self.0.clone(), 9))
        }
        async fn is_seq_expired(&self, _: Uuid, _: u64) -> Result<bool, DomainError> {
            Ok(false)
        }
        async fn current_seq(&self, _: Uuid) -> Result<u64, DomainError> {
            Ok(9)
        }
        async fn delete_expired_before(&self, _: DateTime<Utc>) -> Result<u64, DomainError> {
            unimplemented!()
        }
        async fn enforce_row_cap(&self, _: u32) -> Result<u64, DomainError> {
            unimplemented!()
        }
    }

    /// What the resolver answers for every row.
    enum Answer {
        Live,
        Gone,
        Fails,
    }

    struct StubResolver {
        answer: Answer,
        calls: Arc<AtomicUsize>,
    }

    impl SyncMemberResolver for StubResolver {
        type Member = String;
        async fn resolve_batch(
            &self,
            _: Uuid,
            rows: &[&SyncChangeRow],
        ) -> Result<HashMap<Uuid, String>, DomainError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            match self.answer {
                Answer::Live => Ok(rows
                    .iter()
                    .map(|r| (r.member_id, r.label.clone()))
                    .collect()),
                Answer::Gone => Ok(HashMap::new()),
                Answer::Fails => Err(DomainError::new(
                    ErrorKind::DatabaseError,
                    "Contact",
                    "connection reset",
                )),
            }
        }
    }

    fn row(label: &str, kind: SyncChangeKind) -> SyncChangeRow {
        SyncChangeRow {
            member_id: Uuid::new_v4(),
            label: label.to_owned(),
            kind,
            is_collection: false,
        }
    }

    fn engine(
        rows: Vec<SyncChangeRow>,
        answer: Answer,
        caller: Uuid,
    ) -> SyncCollectionEngine<FixedLog, StubResolver, FakeEngine> {
        engine_counting(rows, answer, caller, Arc::default())
    }

    fn engine_counting(
        rows: Vec<SyncChangeRow>,
        answer: Answer,
        caller: Uuid,
        calls: Arc<AtomicUsize>,
    ) -> SyncCollectionEngine<FixedLog, StubResolver, FakeEngine> {
        SyncCollectionEngine::new(
            Arc::new(FixedLog(rows)),
            StubResolver { answer, calls },
            Arc::new(FakeEngine::granting(vec![Subject::User(caller)])),
            Resource::AddressBook,
            |label| format!("{label}.vcf"),
            "TestSyncChange",
        )
    }

    fn token(collection: Uuid) -> Option<SyncToken> {
        Some(SyncToken::mint(collection, 1))
    }

    /// Regression: the resolvers used `.ok()`, so a failed DB read became
    /// `None` and the engine emitted a 404 tombstone. The client then
    /// deleted a member that still existed. A failed lookup must fail the
    /// REPORT, never turn into a deletion.
    #[tokio::test]
    async fn a_failed_lookup_is_an_error_not_a_tombstone() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let e = engine(
            vec![row("a", SyncChangeKind::Updated)],
            Answer::Fails,
            caller,
        );
        let err = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap_err();
        assert_eq!(err.kind, ErrorKind::DatabaseError);
    }

    /// The legitimate degrade: the member was purged after its row was
    /// logged, so the client is told it is gone.
    #[tokio::test]
    async fn a_vanished_member_becomes_a_tombstone() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let e = engine(
            vec![row("a", SyncChangeKind::Created)],
            Answer::Gone,
            caller,
        );
        let delta = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap();
        let (live, deleted) = delta.split_homogeneous("/b/");
        assert!(live.is_empty());
        assert_eq!(deleted, vec!["/b/a.vcf".to_owned()]);
    }

    /// Delete + recreate of one href in a single poll window: the stale
    /// tombstone must be dropped, or the client deletes the live copy.
    #[tokio::test]
    async fn a_stale_tombstone_for_a_live_href_is_dropped() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let e = engine(
            vec![
                row("a", SyncChangeKind::Deleted),
                row("a", SyncChangeKind::Created),
            ],
            Answer::Live,
            caller,
        );
        let delta = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap();
        let (live, deleted) = delta.split_homogeneous("/b/");
        assert_eq!(live, vec!["a".to_owned()]);
        assert!(deleted.is_empty());
    }

    #[tokio::test]
    async fn a_caller_without_read_is_refused() {
        let (owner, stranger, coll) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let e = engine(vec![row("a", SyncChangeKind::Created)], Answer::Live, owner);
        assert!(
            e.list_changes_with_perms(coll, token(coll), stranger)
                .await
                .is_err()
        );
    }

    /// Regression: WebDAV and CardDAV looked members up one query per
    /// row, so a delta at the 20k row cap cost 20k round trips. The engine
    /// must hand every live row to the resolver in ONE call.
    #[tokio::test]
    async fn live_rows_are_resolved_in_one_batch() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let calls = Arc::new(AtomicUsize::new(0));
        let rows = (0..50)
            .map(|i| row(&format!("m{i}"), SyncChangeKind::Updated))
            .collect();
        let e = engine_counting(rows, Answer::Live, caller, calls.clone());
        let delta = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap();
        assert_eq!(delta.changes.len(), 50);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    /// A delta of pure deletions needs no lookup at all.
    #[tokio::test]
    async fn a_delete_only_delta_skips_the_resolver() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let calls = Arc::new(AtomicUsize::new(0));
        let e = engine_counting(
            vec![row("gone", SyncChangeKind::Deleted)],
            Answer::Fails,
            caller,
            calls.clone(),
        );
        let delta = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap();
        assert_eq!(delta.changes.len(), 1);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    /// A deleted WebDAV subfolder's tombstone keeps its collection flag,
    /// so the handler renders its href with the trailing slash.
    #[tokio::test]
    async fn a_tombstone_keeps_the_collection_flag() {
        let (caller, coll) = (Uuid::new_v4(), Uuid::new_v4());
        let mut folder = row("docs", SyncChangeKind::Deleted);
        folder.is_collection = true;
        let e = engine(vec![folder], Answer::Live, caller);
        let delta = e
            .list_changes_with_perms(coll, token(coll), caller)
            .await
            .unwrap();
        assert!(matches!(
            delta.changes.as_slice(),
            [SyncChange::Deleted {
                is_collection: true,
                ..
            }]
        ));
    }
}
