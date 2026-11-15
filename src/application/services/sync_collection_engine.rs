//! Shared engine behind CalDAV's and CardDAV's `sync-collection` services
//! — both resolve a homogeneous change log into `SyncDelta<M>` with
//! identical control flow (authz gate → expiry check → changes_since →
//! per-row resolve-or-degrade). WebDAV's service stays hand-rolled
//! (`WebdavSyncCollectionService`, heterogeneous folder/file members,
//! drive/path resolution) — not a fit here, per that service's doc comment.
//!
//! Authz here assumes a grant-only engine — see
//! `application::ports::change_log_port`'s module doc for the reasoning
//! and why deny rules would need this revisited.

use std::sync::Arc;

use uuid::Uuid;

use crate::application::ports::authorization_ports::AuthorizationEngine;
use crate::application::ports::change_log_port::{SyncChange, SyncDelta};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::repositories::sync_change_log_repository::{
    SyncChangeKind, SyncChangeLogRepository,
};
use crate::domain::services::authorization::{Permission, Resource, Subject};
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

/// Per-domain hook resolving a `Created`/`Updated` row's member id back to
/// its current DTO.
///
/// `Ok(None)` means the member is **gone** (hard-deleted or purged after
/// the row was logged); the engine turns that into a `Deleted` entry.
/// Any other failure must be `Err`: a read failure is never proof of
/// absence, and a wrongly emitted tombstone makes the client delete data
/// that still exists. Use `NotFoundAsNone` to map a lookup's `NotFound`.
///
/// `label` is the row's logged label (iCalendar / vCard UID). A domain
/// whose resource is addressed by label rather than by row — CalDAV, where
/// a master and its RECURRENCE-ID overrides share one href — resolves to
/// the label alone and hydrates the touched resources in one batch itself.
pub trait SyncMemberResolver: Send + Sync + 'static {
    type Member;
    async fn resolve(
        &self,
        member_id: Uuid,
        label: &str,
    ) -> Result<Option<Self::Member>, DomainError>;
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
    /// `Resource::Calendar` / `Resource::AddressBook` are themselves valid
    /// `fn(Uuid) -> Resource` values (tuple-variant constructors) — no
    /// closure needed.
    resource_of: fn(Uuid) -> Resource,
    /// Turns a row's `label` into the `href_hint` a `Deleted` entry
    /// carries (`"{label}.ics"` / `"{label}.vcf"`).
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

    /// Mints the token an **initial** sync response should hand back
    /// (empty/absent client `sync-token`). Cheaper than routing through
    /// `list_changes_with_perms`, which would also walk the collection's
    /// full change history only to discard it.
    pub async fn mint_initial_token(
        &self,
        collection_id: Uuid,
        caller_id: Uuid,
    ) -> Result<SyncToken, DomainError> {
        self.authz
            .require(
                Subject::User(caller_id),
                Permission::Read,
                (self.resource_of)(collection_id),
            )
            .await?;

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
        self.authz
            .require(
                Subject::User(caller_id),
                Permission::Read,
                (self.resource_of)(collection_id),
            )
            .await?;

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
        // batch: CalDAV/CardDAV "update" is delete+recreate at the DB
        // layer (a brand-new `member_id`, never a SQL UPDATE of the old
        // row — see the migration header), so deleting then recreating
        // the same href within one poll window produces two genuinely
        // different rows — a tombstone for the old member_id and a
        // creation for the new one. The handler renders upserts and
        // deletions as separate buckets (`split_homogeneous`), which
        // can't express "this happened before that", so a stale
        // tombstone sharing a href with a live upsert in the SAME batch
        // must be dropped here — the href demonstrably still exists,
        // and a client has no order-based way to reach that conclusion
        // itself from the rendered response.
        let live_labels: std::collections::HashSet<String> = rows
            .iter()
            .filter(|r| !matches!(r.kind, SyncChangeKind::Deleted))
            .map(|r| r.label.clone())
            .collect();

        let mut changes = Vec::with_capacity(rows.len());
        for row in rows {
            match row.kind {
                SyncChangeKind::Deleted => {
                    if live_labels.contains(row.label.as_str()) {
                        continue;
                    }
                    changes.push(SyncChange::Deleted {
                        member_id: row.member_id,
                        href_hint: (self.label_to_href_hint)(&row.label),
                        is_collection: false,
                    });
                }
                SyncChangeKind::Created | SyncChangeKind::Updated => {
                    match self.resolver.resolve(row.member_id, &row.label).await? {
                        Some(member) => changes.push(SyncChange::Upserted(member)),
                        None => changes.push(SyncChange::Deleted {
                            member_id: row.member_id,
                            href_hint: (self.label_to_href_hint)(&row.label),
                            is_collection: false,
                        }),
                    }
                }
            }
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
    use crate::domain::repositories::sync_change_log_repository::SyncChangeRow;
    use chrono::{DateTime, Utc};

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

    struct StubResolver(Answer);

    impl SyncMemberResolver for StubResolver {
        type Member = String;
        async fn resolve(&self, _: Uuid, label: &str) -> Result<Option<String>, DomainError> {
            match self.0 {
                Answer::Live => Ok(Some(label.to_owned())),
                Answer::Gone => Ok(None),
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
        }
    }

    fn engine(
        rows: Vec<SyncChangeRow>,
        answer: Answer,
        caller: Uuid,
    ) -> SyncCollectionEngine<FixedLog, StubResolver, FakeEngine> {
        SyncCollectionEngine::new(
            Arc::new(FixedLog(rows)),
            StubResolver(answer),
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
}
