//! Application-layer orchestration for CardDAV `sync-collection` REPORT —
//! wraps `SyncCollectionEngine` over `ContactSyncChangePgRepository`.
//! Mirrors `CaldavSyncCollectionService`; the two share the same generic
//! engine, differing only in the resolver and the `.vcf`/`Resource`
//! parameterization.

use std::sync::Arc;

use uuid::Uuid;

use crate::application::dtos::contact_dto::ContactDto;
use crate::application::ports::change_log_port::SyncDelta;
use crate::application::services::sync_collection_engine::{
    SyncCollectionEngine, SyncMemberResolver,
};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::errors::NotFoundAsNone;
use crate::domain::repositories::contact_repository::ContactRepository;
use crate::domain::services::authorization::Resource;
use crate::infrastructure::repositories::pg::ContactPgRepository;
use crate::infrastructure::repositories::pg::contact_sync_change_pg_repository::ContactSyncChangePgRepository;
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

struct ContactMemberResolver {
    contact_storage: Arc<ContactPgRepository>,
}

impl SyncMemberResolver for ContactMemberResolver {
    type Member = ContactDto;

    async fn resolve(
        &self,
        member_id: Uuid,
        _label: &str,
    ) -> Result<Option<ContactDto>, DomainError> {
        // `Ok(None)`: hard-deleted after the row was logged → the engine
        // emits a tombstone. A failed read stays an error — reporting it
        // as deleted would make the client drop a contact that exists.
        let contact = self
            .contact_storage
            .get_contact_by_id(&member_id)
            .await
            .not_found_as_none()?
            .flatten();
        Ok(contact.map(ContactDto::from))
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
