//! Application-layer orchestration for WebDAV `sync-collection` REPORT
//! (RFC 6578) — wraps `SyncCollectionEngine` over the
//! `storage.folder_sync_changes` log, with a resolver that looks up the
//! delta's folders and files in one batch query each.
//!
//! Kept as its own service (rather than folded into `FolderService`/
//! `FileRetrievalService`) because it composes both — a WebDAV collection
//! mixes file and folder members — without changing either service's
//! constructor or existing call sites.

use std::collections::HashMap;
use std::sync::Arc;

use uuid::Uuid;

use crate::application::dtos::file_dto::FileDto;
use crate::application::dtos::folder_dto::FolderDto;
use crate::application::ports::change_log_port::SyncDelta;
use crate::application::services::sync_collection_engine::{
    SyncCollectionEngine, SyncMemberResolver,
};
use crate::common::errors::DomainError;
use crate::domain::entities::sync_token::SyncToken;
use crate::domain::repositories::sync_change_log_repository::SyncChangeRow;
use crate::domain::services::authorization::Resource;
use crate::infrastructure::repositories::pg::file_blob_read_repository::FileBlobReadRepository;
use crate::infrastructure::repositories::pg::folder_db_repository::FolderDbRepository;
use crate::infrastructure::repositories::pg::folder_sync_change_pg_repository::FolderSyncChangePgRepository;
use crate::infrastructure::services::pg_acl_engine::PgAclEngine;

/// A WebDAV collection member as it should be rendered in a
/// `sync-collection` response — a folder-membership change log mixes
/// both resource types, unlike CalDAV/CardDAV's homogeneous collections.
#[derive(Debug, Clone)]
pub enum WebdavSyncMember {
    Folder(FolderDto),
    File(FileDto),
}

/// Resolves a delta's live rows with two batch queries, one per member
/// type. Trashed members drop out of both (`NOT is_trashed`), so a member
/// trashed after its row was logged is reported as deleted.
struct WebdavMemberResolver {
    folder_storage: Arc<FolderDbRepository>,
    file_read: Arc<FileBlobReadRepository>,
}

impl SyncMemberResolver for WebdavMemberResolver {
    type Member = WebdavSyncMember;

    async fn resolve_batch(
        &self,
        _collection_id: Uuid,
        rows: &[&SyncChangeRow],
    ) -> Result<HashMap<Uuid, WebdavSyncMember>, DomainError> {
        let (folder_rows, file_rows): (Vec<_>, Vec<_>) = rows.iter().partition(|r| r.is_collection);
        let ids = |rows: Vec<&&SyncChangeRow>| -> Vec<String> {
            rows.iter().map(|r| r.member_id.to_string()).collect()
        };
        let (folder_ids, file_ids) = (ids(folder_rows), ids(file_rows));

        let mut members = HashMap::with_capacity(rows.len());
        if !folder_ids.is_empty() {
            for folder in self.folder_storage.get_folders_by_ids(&folder_ids).await? {
                let dto = FolderDto::from(folder);
                members.insert(dto.id.parse()?, WebdavSyncMember::Folder(dto));
            }
        }
        if !file_ids.is_empty() {
            for file in self.file_read.get_files_by_ids(&file_ids).await? {
                let dto = FileDto::from(file);
                members.insert(dto.id.parse()?, WebdavSyncMember::File(dto));
            }
        }
        Ok(members)
    }
}

pub struct WebdavSyncCollectionService {
    engine: SyncCollectionEngine<FolderSyncChangePgRepository, WebdavMemberResolver>,
}

impl WebdavSyncCollectionService {
    pub fn new(
        change_log: Arc<FolderSyncChangePgRepository>,
        folder_storage: Arc<FolderDbRepository>,
        file_read: Arc<FileBlobReadRepository>,
        authz: Arc<PgAclEngine>,
    ) -> Self {
        Self {
            engine: SyncCollectionEngine::new(
                change_log,
                WebdavMemberResolver {
                    folder_storage,
                    file_read,
                },
                authz,
                Resource::Folder,
                // The leaf name is the href segment as-is; the handler
                // percent-encodes it and appends `/` for collections.
                |label| label.to_owned(),
                "FolderSyncChange",
            ),
        }
    }

    /// Mints the token an **initial** sync response should hand back
    /// (empty/absent client `sync-token` — the caller renders a full
    /// listing itself and just needs a cursor for the client's *next*
    /// poll).
    pub async fn mint_initial_token(
        &self,
        collection_folder_id: Uuid,
        caller_id: Uuid,
    ) -> Result<SyncToken, DomainError> {
        self.engine
            .mint_initial_token(collection_folder_id, caller_id)
            .await
    }

    /// Resolves the delta for `collection_folder_id` since `since_token`.
    /// Authz, token expiry and tombstone rules are the engine's (see
    /// `SyncCollectionEngine::list_changes_with_perms`).
    pub async fn list_changes_with_perms(
        &self,
        collection_folder_id: Uuid,
        since_token: Option<SyncToken>,
        caller_id: Uuid,
    ) -> Result<SyncDelta<WebdavSyncMember>, DomainError> {
        self.engine
            .list_changes_with_perms(collection_folder_id, since_token, caller_id)
            .await
    }
}
