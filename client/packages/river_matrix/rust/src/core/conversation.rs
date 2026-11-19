use std::collections::BTreeSet;

use anyhow::{Context, Result, ensure};
use matrix_sdk::{
    Room, RoomMemberships, RoomState,
    ruma::{
        OwnedRoomId, OwnedUserId, RoomId, UserId,
        api::client::{
            membership::get_member_events, room::create_room, state::get_state_event_for_key,
        },
        events::{StateEventType, direct::DirectUserIdentifier, room::join_rules::JoinRule},
    },
};
use serde::Deserialize;
use serde_json::{Value, json};

use super::connection::{MatrixCore, sdk_error};

const FALLBACK_EVENT: &str = "cool.gravitas.river.unencrypted_fallback.v1";
const ACTIVE_MEMBERS: RoomMemberships = RoomMemberships::JOIN.union(RoomMemberships::INVITE);

pub(super) fn fallback_event_type() -> StateEventType {
    FALLBACK_EVENT.into()
}

#[derive(Deserialize)]
struct FallbackLink {
    conversation: OwnedRoomId,
    participants: BTreeSet<OwnedUserId>,
}

pub(super) fn private_chat(room: &Room) -> bool {
    room.state() == RoomState::Joined
        && !room.is_tombstoned()
        && room.room_type().is_none()
        && matches!(room.join_rule(), Some(JoinRule::Invite))
}

impl MatrixCore {
    pub(super) async fn fallback_link(&self, room: &Room) -> Result<Option<Value>> {
        room.get_state_event(fallback_event_type(), "")
            .await
            .map_err(sdk_error)?
            .map(serde_json::to_value)
            .transpose()
            .map_err(Into::into)
    }

    async fn cached_participants(&self, room: &Room) -> Result<BTreeSet<OwnedUserId>> {
        Ok(room
            .members(ACTIVE_MEMBERS)
            .await
            .map_err(sdk_error)?
            .into_iter()
            .map(|member| member.user_id().to_owned())
            .collect())
    }

    async fn current_participants(&self, room: &RoomId) -> Result<BTreeSet<OwnedUserId>> {
        // The SDK's lazy member cache is useful for rendering. Recheck both
        // rosters on the server before opening or sending to a fallback.
        let response = self
            .client
            .send(get_member_events::v3::Request::new(room.to_owned()))
            .await
            .map_err(sdk_error)?;
        let mut participants = BTreeSet::new();
        for raw in response.chunk {
            let event: Value = serde_json::from_str(raw.json().get())?;
            if matches!(
                event["content"]["membership"].as_str(),
                Some("join" | "invite")
            ) {
                let user = event["state_key"].as_str().context("Invalid room member")?;
                participants.insert(UserId::parse(user)?);
            }
        }
        Ok(participants)
    }

    pub(super) async fn direct_peer(&self, room: &Room) -> Result<Option<OwnedUserId>> {
        if !private_chat(room)
            || room.direct_targets_length() != 1
            || (!room.are_members_synced() && room.active_members_count() != 2)
        {
            return Ok(None);
        }
        let participants: BTreeSet<_> = room
            .members_no_sync(ACTIVE_MEMBERS)
            .await
            .map_err(sdk_error)?
            .into_iter()
            .map(|member| member.user_id().to_owned())
            .collect();
        if participants.len() != 2 || !participants.contains(&self.own_user) {
            return Ok(None);
        }
        let targets = room.direct_targets();
        Ok(participants.into_iter().find(|peer| {
            peer != &self.own_user && targets.contains(<&DirectUserIdentifier>::from(peer.as_str()))
        }))
    }

    pub(super) async fn linked_conversation(
        &self,
        room: &Room,
        marker: &Option<Value>,
    ) -> Result<Option<OwnedRoomId>> {
        let Some(link) = marker.as_ref().and_then(|event| {
            serde_json::from_value::<FallbackLink>(event["content"].clone()).ok()
        }) else {
            return Ok(None);
        };
        let Some(origin) = self.client.get_room(&link.conversation) else {
            return Ok(None);
        };
        if origin.room_id() == room.room_id()
            || !private_chat(room)
            || !private_chat(&origin)
            || self.fallback_link(&origin).await?.is_some()
            || link.participants.len() < 2
            || !link.participants.contains(&self.own_user)
        {
            return Ok(None);
        }
        let fallback = self.cached_participants(room).await;
        let original = self.cached_participants(&origin).await;
        Ok((fallback.is_ok_and(|members| members == link.participants)
            && original.is_ok_and(|members| members == link.participants))
        .then_some(link.conversation))
    }

    pub(super) async fn open_fallback(&self, id: &str) -> Result<String> {
        let origin = self.writable_room(id)?;
        origin.request_encryption_state().await.map_err(sdk_error)?;
        ensure!(
            private_chat(&origin)
                && origin.encryption_state().is_encrypted()
                && self.fallback_link(&origin).await?.is_none(),
            "Unencrypted sending is available in private conversations"
        );
        let mut pending = self.pending_fallbacks.lock().await;
        let participants = self.current_participants(origin.room_id()).await?;
        ensure!(
            participants.len() >= 2 && participants.contains(&self.own_user),
            "This conversation needs at least two participants"
        );
        if let Some(id) = pending.get(origin.room_id()).cloned()
            && let Some(room) = self.client.get_room(&id)
            && room.state() == RoomState::Joined
            && self.fallback_link(&room).await?.is_none()
            && self.current_participants(&id).await? == participants
        {
            return Ok(json!({"room_id": id}).to_string());
        }
        for room in self.client.joined_rooms() {
            let marker = self.fallback_link(&room).await?;
            if !marker
                .as_ref()
                .is_some_and(|event| event["content"]["conversation"] == id)
                || self.linked_conversation(&room, &marker).await?.is_none()
            {
                continue;
            }
            room.request_encryption_state().await.map_err(sdk_error)?;
            if !room.encryption_state().is_encrypted()
                && self.current_participants(room.room_id()).await? == participants
            {
                return Ok(json!({"room_id": room.room_id()}).to_string());
            }
        }

        let mut request = create_room::v3::Request::new();
        request.preset = Some(create_room::v3::RoomPreset::PrivateChat);
        request.is_direct =
            participants.len() == 2 && origin.is_direct().await.map_err(sdk_error)?;
        request.power_level_content_override = Some(serde_json::from_value(json!({"invite": 50}))?);
        request.invite = participants
            .iter()
            .filter(|user| *user != &self.own_user)
            .cloned()
            .collect();
        request.name = Some(format!(
            "{} (unencrypted)",
            origin.display_name().await.map_err(sdk_error)?,
        ));
        request.initial_state = vec![
            serde_json::from_value(json!({"type": FALLBACK_EVENT, "state_key": "", "content": {
                "conversation": origin.room_id(), "participants": participants,
            }}))?,
            serde_json::from_value(json!({"type": "m.room.guest_access", "state_key": "",
                "content": {"guest_access": "forbidden"}}))?,
            serde_json::from_value(json!({"type": "m.room.history_visibility", "state_key": "",
                "content": {"history_visibility": "invited"}}))?,
        ];
        let room = self.client.create_room(request).await.map_err(sdk_error)?;
        let id = room.room_id().to_owned();
        pending.insert(origin.room_id().to_owned(), id.clone());
        Ok(json!({"room_id": id}).to_string())
    }

    pub(super) async fn check_fallback_send(&self, room: &Room) -> Result<()> {
        let Some(marker) = self.fallback_link(room).await? else {
            // Matrix may have acknowledged creation before the initial state
            // arrives. A fallback cannot be used before its link is known.
            ensure!(
                !self
                    .pending_fallbacks
                    .lock()
                    .await
                    .values()
                    .any(|id| id == room.room_id()),
                "The unencrypted conversation is still syncing"
            );
            return Ok(());
        };
        let link: FallbackLink = serde_json::from_value(marker["content"].clone())
            .context("The unencrypted conversation has an invalid link")?;
        let origin = self.room(link.conversation.as_str())?;
        ensure!(
            private_chat(room)
                && private_chat(&origin)
                && link.participants.len() >= 2
                && link.participants.contains(&self.own_user),
            "The conversation’s participants changed. Send from the original conversation."
        );
        let (source, destination, rules, visibility) = tokio::try_join!(
            self.current_participants(origin.room_id()),
            self.current_participants(room.room_id()),
            self.current_state(room, StateEventType::RoomJoinRules),
            self.current_state(room, StateEventType::RoomHistoryVisibility),
        )?;
        ensure!(
            source == link.participants
                && destination == link.participants
                && rules["join_rule"] == "invite"
                && visibility["history_visibility"] == "invited",
            "The unencrypted room’s access changed. Send from the original conversation."
        );
        Ok(())
    }

    async fn current_state(&self, room: &Room, event: StateEventType) -> Result<Value> {
        let response = self
            .client
            .send(get_state_event_for_key::v3::Request::new(
                room.room_id().to_owned(),
                event,
                String::new(),
            ))
            .await
            .map_err(sdk_error)?;
        Ok(serde_json::from_str(response.event_or_content.get())?)
    }
}
