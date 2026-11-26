//! Application-layer orchestration for CardDAV `sync-collection` REPORT —
//! wraps `SyncCollectionEngine` over `ContactSyncChangePgRepository`.
//! Mirrors `CaldavSyncCollectionService`; the two share the same generic
//! engine, differing only in the resolver and the `.vcf`/`Resource`
//! parameterization.

use std::collections::HashMap;
use std::sync::Arc;

use uuid::Uuid;

use crate::application::dtos::contact_dto::ContactDto;
use crate::application::ports::change_log_port::SyncDelta;
use crate::application::services::sync_collection_engine::{
    SyncCollectionEngine, SyncMemberResolver,
};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::repositories::contact_repository::ContactRepository;
use crate::domain::repositories::sync_change_log_repository::SyncChangeRow;
use crate::domain::services::authorization::Resource;
use crate::infrastructure::repositories::pg::ContactPgRepository;
use crate::infrastructure::repositories::pg::contact_sync_change_pg_repository::ContactSyncChangePgRepository;
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

struct ContactMemberResolver {
    contact_storage: Arc<ContactPgRepository>,
}

impl SyncMemberResolver for ContactMemberResolver {
    type Member = ContactDto;

    /// One indexed `uid = ANY(..)` query for the whole delta, re-keyed by
    /// contact id. A row whose contact was deleted, or replaced by a
    /// recreate under a new id, is simply absent and becomes a tombstone;
    /// a failed query fails the REPORT.
    async fn resolve_batch(
        &self,
        collection_id: Uuid,
        rows: &[&SyncChangeRow],
    ) -> Result<HashMap<Uuid, ContactDto>, DomainError> {
        let uids: Vec<String> = rows.iter().map(|r| r.label.clone()).collect();
        let contacts = self
            .contact_storage
            .get_contacts_by_uids(&collection_id, &uids)
            .await?;
        Ok(contacts
            .into_iter()
            .map(|c| (*c.id(), ContactDto::from(c)))
            .collect())
    }
}

pub struct CarddavSyncCollectionService {
    engine: SyncCollectionEngine<ContactSyncChangePgRepository, ContactMemberResolver>,
}

impl CarddavSyncCollectionService {
    pub fn new(
        change_log: Arc<ContactSyncChangePgRepository>,
        contact_storage: Arc<ContactPgRepository>,
        authz: Arc<PgAclEngine>,
    ) -> Self {
        Self {
            engine: SyncCollectionEngine::new(
                change_log,
                ContactMemberResolver { contact_storage },
                authz,
                Resource::AddressBook,
                |label| format!("{label}.vcf"),
                "ContactSyncChange",
            ),
        }
    }

    pub async fn mint_initial_token(
        &self,
        collection_address_book_id: Uuid,
        caller_id: Uuid,
    ) -> Result<SyncToken, DomainError> {
        self.engine
            .mint_initial_token(collection_address_book_id, caller_id)
            .await
    }

    pub async fn list_changes_with_perms(
        &self,
        collection_address_book_id: Uuid,
        since_token: Option<SyncToken>,
        caller_id: Uuid,
    ) -> Result<SyncDelta<ContactDto>, DomainError> {
        self.engine
            .list_changes_with_perms(collection_address_book_id, since_token, caller_id)
            .await
    }
}
