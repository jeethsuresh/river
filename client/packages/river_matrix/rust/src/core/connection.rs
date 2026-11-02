use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};

pub(crate) fn sdk_error(error: impl std::fmt::Display) -> anyhow::Error {
    anyhow::anyhow!("{error}")
}
fn sync_error(error: matrix_sdk::Error) -> anyhow::Error {
    if matches!(
        error.client_api_error_kind(),
        Some(matrix_sdk::ruma::api::error::ErrorKind::UnknownToken { .. })
    ) {
        anyhow::anyhow!("RIVER_MATRIX_SESSION_EXPIRED")
    } else if matches!(&error, matrix_sdk::Error::Http(e)
        if matches!(e.as_ref(), matrix_sdk::HttpError::Reqwest(_)))
    {
        anyhow::anyhow!("RIVER_NETWORK_UNAVAILABLE: {error}")
    } else {
        sdk_error(error)
    }
}
use matrix_sdk::{
    Client, Room, RoomMemberships, RoomState,
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    room::MessagesOptions,
    ruma::{
        OwnedUserId, RoomId, UserId,
        events::{
            StateEventType, key::verification::request::ToDeviceKeyVerificationRequestEvent,
            room::member::MembershipState,
        },
    },
    sliding_sync::{SlidingSync, SlidingSyncList, SlidingSyncMode, Version},
};
use serde_json::{Value, json};
use tokio::sync::Mutex;

#[cfg(not(test))]
const POLL_TIMEOUT: Duration = Duration::from_secs(20);
#[cfg(test)]
const POLL_TIMEOUT: Duration = Duration::from_millis(10);

/// A single account's client. Private crypto state stays in the encrypted local
/// SDK store. This object and its session are never sent to River's Go relay.
pub struct MatrixCore {
    pub(crate) client: Client,
    pub(crate) local_key: Option<zeroize::Zeroizing<String>>,
    pub(crate) own_user: OwnedUserId,
    sliding: Mutex<Option<SlidingSync>>,
    connection_id: String,
    polling: Mutex<()>,
    closed: AtomicBool,
    pub(crate) verification_flows: Arc<Mutex<Vec<String>>>,
}

impl MatrixCore {
    pub async fn open(
        homeserver: String,
        expected_user: String,
        store: String,
        store_key: String,
        session: Option<String>,
    ) -> Result<Self> {
        let origin = url::Url::parse(&homeserver)?;
        ensure!(
            origin.scheme() == "https"
                && origin.host_str().is_some()
                && origin.username().is_empty()
                && origin.password().is_none()
                && origin.query().is_none()
                && origin.fragment().is_none(),
            "Invalid Matrix homeserver"
        );
        ensure!(
            !store.is_empty() && store_key.len() >= 32,
            "Invalid local Matrix store"
        );
        let own_user = UserId::parse(expected_user)?;
        let session: Option<MatrixSession> =
            session.map(|s| serde_json::from_str(&s)).transpose()?;
        if let Some(session) = &session {
            ensure!(
                session.meta.user_id == own_user,
                "Matrix session belongs to another account"
            );
        }
        let holder = uuid::Uuid::new_v4().to_string();
        #[cfg(not(target_family = "wasm"))]
        let _ = rustls::crypto::ring::default_provider().install_default();
        let builder = Client::builder()
            .homeserver_url(homeserver)
            .with_encryption_settings(matrix_sdk::encryption::EncryptionSettings {
                backup_download_strategy:
                    matrix_sdk::encryption::BackupDownloadStrategy::AfterDecryptionFailure,
                ..Default::default()
            })
            .respect_login_well_known(false)
            .handle_refresh_tokens()
            .cross_process_store_config(
                matrix_sdk_common::cross_process_lock::CrossProcessLockConfig::multi_process(
                    holder.clone(),
                ),
            );
        #[cfg(not(target_family = "wasm"))]
        let builder = builder
            .user_agent("River/Matrix")
            .sqlite_store(&store, Some(&store_key));
        #[cfg(target_family = "wasm")]
        let builder = builder.indexeddb_store(&store, Some(&store_key));
        let client = builder.build().await.map_err(sdk_error)?;
        if let Some(session) = session {
            client
                .matrix_auth()
                .restore_session(session, Default::default())
                .await
                .map_err(sdk_error)?;
        }
        let mut core = Self::from_client(client, own_user, holder);
        core.local_key = Some(zeroize::Zeroizing::new(store_key));
        Ok(core)
    }

    pub(crate) fn from_client(client: Client, own_user: OwnedUserId, holder: String) -> Self {
        let verification_flows = Arc::new(Mutex::new(Vec::<String>::new()));
        let pending = verification_flows.clone();
        let expected = own_user.clone();
        client.add_event_handler(move |event: ToDeviceKeyVerificationRequestEvent| {
            let pending = pending.clone();
            let expected = expected.clone();
            async move {
                if event.sender == expected {
                    let mut pending = pending.lock().await;
                    let id = event.content.transaction_id.to_string();
                    if !pending.contains(&id) {
                        if pending.len() >= 64 {
                            pending.remove(0);
                        }
                        pending.push(id);
                    }
                }
            }
        });
        Self {
            client,
            local_key: None,
            own_user,
            verification_flows,
            connection_id: holder[..15].to_owned(),
            sliding: Mutex::new(None),
            polling: Mutex::new(()),
            closed: AtomicBool::new(false),
        }
    }

    pub(crate) fn active(&self) -> Result<()> {
        ensure!(
            !self.closed.load(Ordering::SeqCst),
            "Matrix session is closed"
        );
        ensure!(
            self.client.user_id() == Some(&self.own_user),
            "Connect Matrix messaging first"
        );
        Ok(())
    }

    /// Redeem only the browser-approved, short-lived SSO token. The resulting
    /// account must match the authenticated Gravitas profile before it is used.
    pub async fn login(&self, login_token: String) -> Result<String> {
        ensure!(
            !self.closed.load(Ordering::SeqCst),
            "Matrix session is closed"
        );
        self.client
            .matrix_auth()
            .login_token(&login_token)
            .initial_device_display_name("River")
            .request_refresh_token()
            .send()
            .await
            .map_err(sdk_error)?;
        if self.client.user_id() != Some(&self.own_user) {
            let _ = self.client.matrix_auth().logout().await;
            bail!("The Matrix account differs from the signed-in River account");
        }
        self.credentials().await
    }

    pub async fn credentials(&self) -> Result<String> {
        self.active()?;
        Ok(serde_json::to_string(
            &self
                .client
                .matrix_auth()
                .session()
                .context("Missing Matrix session")?,
        )?)
    }

    /// One sync request per connection. The Dart controller owns the cancellable
    /// loop and saves credentials after requests, including failures. A token
    /// rotation wakes a pending poll so it can be persisted immediately.
    pub async fn sync(&self) -> Result<String> {
        self.active()?;
        let _poll = self.polling.lock().await;
        let mut sliding = self.sliding.lock().await;
        if sliding.is_none()
            && self
                .client
                .available_sliding_sync_versions()
                .await
                .iter()
                .any(|v| matches!(v, Version::Native))
        {
            *sliding = Some(
                self.client
                    .sliding_sync(&self.connection_id)
                    .map_err(sdk_error)?
                    .version(Version::Native)
                    .with_all_extensions()
                    .poll_timeout(POLL_TIMEOUT)
                    .add_list(
                        SlidingSyncList::builder("rooms")
                            .sync_mode(SlidingSyncMode::new_growing(100))
                            .timeline_limit(30)
                            .required_state(vec![
                                (StateEventType::RoomCreate, "".into()),
                                (StateEventType::RoomName, "".into()),
                                (StateEventType::RoomTopic, "".into()),
                                (StateEventType::RoomAvatar, "".into()),
                                (StateEventType::RoomEncryption, "".into()),
                                (StateEventType::RoomPowerLevels, "".into()),
                                (StateEventType::RoomJoinRules, "".into()),
                                (StateEventType::RoomTombstone, "".into()),
                                (StateEventType::RoomMember, "$ME".into()),
                                (StateEventType::SpaceParent, "*".into()),
                                (StateEventType::SpaceChild, "*".into()),
                                (StateEventType::RoomMember, "$LAZY".into()),
                                (
                                    StateEventType::from("cool.gravitas.river.group.v1"),
                                    "".into(),
                                ),
                            ]),
                    )
                    .build()
                    .await
                    .map_err(sdk_error)?,
            );
        }
        let connection = sliding.clone();
        drop(sliding);
        let mut session_changes = self.client.subscribe_to_session_changes();
        let poll = async {
            if let Some(connection) = connection {
                // Unlike SlidingSync::sync(), sync_once() does not expire an
                // invalid cursor. Recover here while holding the polling lock,
                // so foreground room creation never receives a stale position.
                // Retry once; a persistently failing server must still return.
                let mut result = connection.sync_once().await;
                for attempt in 0..2 {
                    if !matches!(&result, Err(error) if error.client_api_error_kind()
                        == Some(&matrix_sdk::ruma::api::error::ErrorKind::UnknownPos))
                    {
                        break;
                    }
                    connection.expire_session().await;
                    if attempt == 0 {
                        self.active()?;
                        result = connection.sync_once().await;
                    }
                }
                Ok::<_, anyhow::Error>(result.map_err(sync_error)?.rooms)
            } else {
                let response = self
                    .client
                    .sync_once(SyncSettings::default().timeout(POLL_TIMEOUT))
                    .await
                    .map_err(sync_error)?;
                Ok(response
                    .rooms
                    .joined
                    .keys()
                    .chain(response.rooms.invited.keys())
                    .chain(response.rooms.left.keys())
                    .chain(response.rooms.knocked.keys())
                    .cloned()
                    .collect())
            }
        };
        tokio::pin!(poll);
        let (changed, credentials_changed) = loop {
            tokio::select! {
                result = &mut poll => break (result?, false),
                change = session_changes.recv() => match change {
                    Ok(matrix_sdk::SessionChange::TokensRefreshed) |
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        // Do not hold a newly rotated single-use refresh token
                        // behind another long poll. Return it to the durable
                        // client store now; the next sync resumes the same cursor.
                        break (Vec::new(), true);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        break ((&mut poll).await?, false);
                    }
                    _ => {}
                }
            }
        };
        self.active()?;
        let mut result: Value = serde_json::from_str(&self.rooms().await.map_err(sdk_error)?)?;
        result["changed"] = json!(changed);
        result["credentials_changed"] = json!(credentials_changed);
        Ok(result.to_string())
    }

    pub async fn rooms(&self) -> Result<String> {
        self.active()?;
        let replacements = self.follow_room_upgrades().await;
        let mut rooms = Vec::new();
        for room in self.client.rooms() {
            let membership = match room.state() {
                RoomState::Joined => "join",
                RoomState::Invited => "invite",
                RoomState::Knocked => "knock",
                _ => "leave",
            };
            let mut parents = Vec::new();
            for event in room
                .get_state_events(StateEventType::SpaceParent)
                .await
                .map_err(sdk_error)?
            {
                let value = serde_json::to_value(event)?;
                if let Some(parent) = value["state_key"].as_str() {
                    parents.push(parent.to_owned());
                }
            }
            let metadata = room
                .get_state_event(StateEventType::from("cool.gravitas.river.group.v1"), "")
                .await
                .map_err(sdk_error)?;
            let metadata: Value = metadata
                .map(serde_json::to_value)
                .transpose()?
                .unwrap_or(Value::Null);
            let metadata = &metadata["content"];
            let power = room.power_levels_or_default().await;
            let name = room
                .display_name()
                .await
                .map(|v| v.to_string())
                .unwrap_or_else(|_| room.room_id().to_string());
            rooms.push(json!({
                "room_id": room.room_id(), "name": name, "membership": membership,
                "replacement_room": replacements.get(room.room_id()),
                "upgrade_pending": room.is_tombstoned() && !replacements.contains_key(room.room_id()),
                "kind": if room.is_space() {"space"} else if room.is_direct().await.unwrap_or(false) {"dm"} else {metadata["kind"].as_str().unwrap_or("group")},
                "channel_kind": metadata["channel_kind"],
                "description": room.topic(),
                "parents": parents, "encrypted": room.encryption_state().is_encrypted(),
                "can_manage": power.user_can_send_state(&self.own_user, StateEventType::RoomName),
                "can_encrypt": power.user_can_send_state(&self.own_user, StateEventType::RoomEncryption),
                "unread_count": room.unread_notification_counts().notification_count,
            }));
        }
        Ok(
            json!({"rooms": rooms, "user_id": self.own_user, "device_id": self.client.device_id()})
                .to_string(),
        )
    }

    pub(crate) fn room(&self, room: &str) -> Result<Room> {
        self.active()?;
        self.client
            .get_room(&RoomId::parse(room)?)
            .context("Room is no longer available")
    }

    pub(crate) fn writable_room(&self, id: &str) -> Result<Room> {
        let room = self.room(id)?;
        ensure!(
            !room.is_tombstoned(),
            "This conversation is moving to a compatible room. Try again in a moment."
        );
        Ok(room)
    }

    pub async fn history(&self, room: String, cursor: Option<String>) -> Result<String> {
        let room = self.room(&room)?;
        let mut options = MessagesOptions::backward();
        options.limit = 50u32.into();
        options.from = cursor;
        let page = room.messages(options).await.map_err(sdk_error)?;
        let events: Result<Vec<Value>> = page
            .chunk
            .into_iter()
            .rev()
            .map(|event| {
                let mut value: Value = serde_json::from_str(event.raw().json().get())?;
                value["room_id"] = json!(room.room_id());
                value["river_encrypted"] = json!(event.encryption_info().is_some());
                Ok(value)
            })
            .collect();
        Ok(json!({"events": events?, "next_cursor": page.end}).to_string())
    }

    pub async fn members(&self, room: String) -> Result<String> {
        let room = self.room(&room)?;
        let mut members = Vec::new();
        for member in room
            .members(RoomMemberships::JOIN | RoomMemberships::INVITE)
            .await
            .map_err(sdk_error)?
        {
            members.push(json!({"user_id": member.user_id(), "username": member.display_name().unwrap_or(member.user_id().localpart()), "membership": member.membership()}));
        }
        Ok(json!({"members": members}).to_string())
    }

    pub async fn send(
        &self,
        room: String,
        event_type: String,
        content: String,
        transaction: String,
    ) -> Result<String> {
        let room = self.writable_room(&room)?;
        let content: Value = serde_json::from_str(&content)?;
        ensure!(content.is_object(), "Message content must be an object");
        room.request_encryption_state().await.map_err(sdk_error)?;
        let transaction: matrix_sdk::ruma::OwnedTransactionId = transaction.into();
        let response = room
            .send_raw(&event_type, content)
            .with_transaction_id(&transaction)
            .await
            .map_err(sdk_error)?;
        Ok(json!({"event_id": response.response.event_id}).to_string())
    }

    pub async fn action(&self, payload: String) -> Result<String> {
        self.active()?;
        let data: Value = serde_json::from_str(&payload)?;
        let text = |key: &str| -> Result<&str> {
            data[key].as_str().with_context(|| format!("Missing {key}"))
        };
        match text("action")? {
            "local_read" => return self.local_data(&data, false).await,
            "local_write" => return self.local_data(&data, true).await,
            "reaction" => {
                self.reaction(&data).await?;
            }
            "edit" => {
                self.edit(&data).await?;
            }
            "join" => {
                let via: Result<Vec<matrix_sdk::ruma::OwnedServerName>> = data["via"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|v| {
                        Ok(matrix_sdk::ruma::ServerName::parse(
                            v.as_str().context("Invalid routing server")?,
                        )?)
                    })
                    .collect();
                let room = self
                    .client
                    .join_room_by_id_or_alias(text("room")?.try_into()?, &via?)
                    .await
                    .map_err(sdk_error)?;
                return Ok(json!({"room_id": room.room_id()}).to_string());
            }
            "direct" => {
                let user = UserId::parse(text("user")?)?;
                let replacements = self.follow_room_upgrades().await;
                // A join can move m.direct on the homeserver before that account
                // data arrives in sync. Preserve the server's preferred order,
                // rather than choosing an arbitrary room from the SDK cache.
                let mut current = None;
                let mut pending = false;
                if let Some(raw) = self
                    .client
                    .account()
                    .fetch_account_data(
                        matrix_sdk::ruma::events::GlobalAccountDataEventType::Direct,
                    )
                    .await
                    .map_err(sdk_error)?
                {
                    let direct: Value = serde_json::from_str(raw.json().get())?;
                    if let Some(ids) = direct[user.as_str()].as_array() {
                        for id in ids.iter().filter_map(Value::as_str) {
                            let Ok(id) = RoomId::parse(id) else {
                                continue;
                            };
                            let target = replacements.get(&id).unwrap_or(&id);
                            if let Some(room) = self.client.get_room(target) {
                                pending |= room.is_tombstoned();
                                let joined = room
                                    .get_member_no_sync(&self.own_user)
                                    .await
                                    .map_err(sdk_error)?
                                    .is_none_or(|member| {
                                        member.membership() == &MembershipState::Join
                                    });
                                if room.state() == RoomState::Joined
                                    && !room.is_tombstoned()
                                    && joined
                                {
                                    current = Some(room);
                                    break;
                                }
                            } else {
                                pending = true;
                            }
                        }
                    }
                }
                let (room, created) = match current {
                    Some(room) => (room, false),
                    None => {
                        ensure!(
                            !pending && self.client.get_dm_rooms(&user).next().is_none(),
                            "This conversation is moving to a compatible room. Try again in a moment."
                        );
                        (self.client.create_dm(&user).await.map_err(sdk_error)?, true)
                    }
                };
                room.request_encryption_state().await.map_err(sdk_error)?;
                if created {
                    // SDK create_dm sends encryption in initial_state. Never
                    // accept a new plaintext room if the server omitted it.
                    ensure!(
                        room.encryption_state().is_encrypted(),
                        "New direct rooms must be encrypted"
                    );
                } else if !room.encryption_state().is_encrypted() {
                    let power = room.power_levels_or_default().await;
                    if power.user_can_send_state(&self.own_user, StateEventType::RoomEncryption) {
                        room.enable_encryption().await.map_err(sdk_error)?;
                    }
                }
                return Ok(json!({"room_id": room.room_id()}).to_string());
            }
            "read" => {
                self.room(text("room")?)?.send_single_receipt(
                    matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType::ReadPrivate,
                    matrix_sdk::ruma::events::receipt::ReceiptThread::Unthreaded,
                    matrix_sdk::ruma::EventId::parse(text("event")?)?,
                ).await.map_err(sdk_error)?;
            }
            "redact" => {
                self.room(text("room")?)?
                    .redact(
                        &matrix_sdk::ruma::EventId::parse(text("event")?)?,
                        None,
                        None,
                    )
                    .await
                    .map_err(sdk_error)?;
            }
            "kick" => {
                self.room(text("room")?)?
                    .kick_user(&UserId::parse(text("user")?)?, None)
                    .await
                    .map_err(sdk_error)?;
            }
            "invite" => {
                self.room(text("room")?)?
                    .invite_user_by_id(&UserId::parse(text("user")?)?)
                    .await
                    .map_err(sdk_error)?;
            }
            "leave" => {
                self.room(text("room")?)?.leave().await.map_err(sdk_error)?;
            }
            "encrypt" => {
                self.room(text("room")?)?
                    .enable_encryption()
                    .await
                    .map_err(sdk_error)?;
            }
            "rename" => {
                self.room(text("room")?)?
                    .set_name(text("name")?.to_owned())
                    .await
                    .map_err(sdk_error)?;
            }
            "typing" => {
                self.room(text("room")?)?
                    .typing_notice(data["typing"].as_bool().unwrap_or(false))
                    .await
                    .map_err(sdk_error)?;
            }
            "state" => {
                self.room(text("room")?)?
                    .send_state_event_raw(
                        text("type")?,
                        data["state_key"].as_str().unwrap_or(""),
                        data["content"].clone(),
                    )
                    .await
                    .map_err(sdk_error)?;
            }
            _ => bail!("Unsupported Matrix action"),
        }
        Ok("{}".into())
    }

    pub async fn close(&self, logout: bool) -> Result<()> {
        self.closed.store(true, Ordering::SeqCst);
        if let Some(sliding) = self.sliding.lock().await.as_ref() {
            let _ = sliding.stop_sync();
        }
        if logout && self.client.user_id().is_some() {
            self.client
                .matrix_auth()
                .logout()
                .await
                .map_err(sdk_error)?;
        }
        Ok(())
    }
}
