//! Application-layer orchestration for CalDAV `sync-collection` REPORT —
//! wraps `SyncCollectionEngine` over `CalendarSyncChangePgRepository`.
//!
//! Kept as its own dedicated service (mirroring `CarddavSyncCollectionService`
//! and `WebdavSyncCollectionService`) rather than the inline methods
//! `CalendarService` used to carry — moved out so all three protocols
//! share the same "dedicated sync-collection service" shape, with CalDAV
//! and CardDAV additionally sharing one generic engine underneath.
//!
//! Unlike CardDAV, the change log here is per ROW but a resource is a UID
//! bundle: a recurring master and its RECURRENCE-ID overrides share one
//! `{uid}.ics` href, and both VEVENT (`caldav.calendar_events`) and VTODO
//! (`caldav.calendar_todos`, #754) rows feed the same log. So the engine
//! resolves every row to its UID only, and this service hydrates each
//! touched UID as a whole, from both object tables, in one batch per kind.

use std::collections::HashSet;
use std::sync::Arc;

use uuid::Uuid;

use crate::application::dtos::calendar_dto::{CalendarEventDto, CalendarTodoDto};
use crate::application::ports::calendar_ports::CalendarStoragePort;
use crate::application::ports::change_log_port::SyncChange;
use crate::application::services::sync_collection_engine::{
    SyncCollectionEngine, SyncMemberResolver,
};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::services::authorization::Resource;
use crate::infrastructure::adapters::calendar_storage_adapter::CalendarStorageAdapter;
use crate::infrastructure::repositories::pg::calendar_sync_change_pg_repository::CalendarSyncChangePgRepository;
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

/// Resolves a change-log row to its iCalendar UID without touching the
/// object tables — the row may be an event or a task, and either way the
/// resource it belongs to is the whole UID bundle, hydrated in
/// `list_changes_with_perms` below.
struct CalendarUidResolver;

impl SyncMemberResolver for CalendarUidResolver {
    type Member = String;

    async fn resolve(&self, _member_id: Uuid, label: &str) -> Option<String> {
        Some(label.to_owned())
    }
}

/// A calendar's delta since a sync-token, hydrated per UID bundle.
pub struct CalendarSyncDelta {
    /// Every row (master + overrides) of each touched UID still stored
    /// as a VEVENT.
    pub events: Vec<CalendarEventDto>,
    /// Same for VTODO.
    pub todos: Vec<CalendarTodoDto>,
    /// Touched UIDs with no row left in either table — rendered as
    /// RFC 6578 §3.7 404 sub-responses at `{base_href}{uid}.ics`.
    pub deleted_uids: Vec<String>,
    pub new_token: SyncToken,
}

pub struct CaldavSyncCollectionService {
    engine: SyncCollectionEngine<CalendarSyncChangePgRepository, CalendarUidResolver>,
    calendar_storage: Arc<CalendarStorageAdapter>,
}

impl CaldavSyncCollectionService {
    pub fn new(
        change_log: Arc<CalendarSyncChangePgRepository>,
        calendar_storage: Arc<CalendarStorageAdapter>,
        authz: Arc<PgAclEngine>,
    ) -> Self {
        Self {
            engine: SyncCollectionEngine::new(
                change_log,
                CalendarUidResolver,
                authz,
                Resource::Calendar,
                // The "href hint" stays the bare UID: this service, not
                // the handler, turns it into a resource (see above).
                |label| label.to_owned(),
                "CalendarSyncChange",
            ),
            calendar_storage,
        }
    }

    pub async fn mint_initial_token(
        &self,
        collection_calendar_id: Uuid,
        caller_id: Uuid,
    ) -> Result<SyncToken, DomainError> {
        self.engine
            .mint_initial_token(collection_calendar_id, caller_id)
            .await
    }

    /// Resolves the delta for `collection_calendar_id` since
    /// `since_token`. Authz and token expiry are the engine's (see
    /// `SyncCollectionEngine::list_changes_with_perms`).
    ///
    /// A touched UID becomes a tombstone only when NEITHER object table
    /// still holds a row for it: a deleted override whose master survives,
    /// or a delete+recreate within one poll window, re-sends the full
    /// bundle instead. A failed lookup is an error, never a tombstone —
    /// telling a client to delete what may still exist is data loss.
    pub async fn list_changes_with_perms(
        &self,
        collection_calendar_id: Uuid,
        since_token: Option<SyncToken>,
        caller_id: Uuid,
    ) -> Result<CalendarSyncDelta, DomainError> {
        let delta = self
            .engine
            .list_changes_with_perms(collection_calendar_id, since_token, caller_id)
            .await?;

        let mut seen = HashSet::with_capacity(delta.changes.len());
        let mut touched = Vec::with_capacity(delta.changes.len());
        for change in delta.changes {
            let uid = match change {
                SyncChange::Upserted(uid) => uid,
                SyncChange::Deleted { href_hint, .. } => href_hint,
            };
            if seen.insert(uid.clone()) {
                touched.push(uid);
            }
        }

        if touched.is_empty() {
            return Ok(CalendarSyncDelta {
                events: Vec::new(),
                todos: Vec::new(),
                deleted_uids: Vec::new(),
                new_token: delta.new_token,
            });
        }

        let calendar_id = collection_calendar_id.to_string();
        let events = self
            .calendar_storage
            .find_events_by_ical_uids(&calendar_id, &touched)
            .await?;
        let todos = self
            .calendar_storage
            .find_todos_by_ical_uids(&calendar_id, &touched)
            .await?;

        let live: HashSet<&str> = events
            .iter()
            .map(|e| e.ical_uid.as_str())
            .chain(todos.iter().map(|t| t.ical_uid.as_str()))
            .collect();
        let deleted_uids = touched
            .iter()
            .filter(|uid| !live.contains(uid.as_str()))
            .cloned()
            .collect();

        Ok(CalendarSyncDelta {
            events,
            todos,
            deleted_uids,
            new_token: delta.new_token,
        })
    }
}
