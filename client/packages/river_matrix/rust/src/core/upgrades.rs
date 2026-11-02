//! Follow only mutually linked, authorized Matrix replacements. Historical
//! rooms stay joined so their encrypted history and room keys remain available.
use super::connection::MatrixCore;
use matrix_sdk::{
    Room, RoomState,
    ruma::{OwnedRoomId, api::client::state::get_state_event_for_key, events::StateEventType},
};
use std::collections::{BTreeMap, BTreeSet};

fn linked(old: &Room, next: &Room) -> bool {
    old.room_id() != next.room_id()
        && old
            .successor_room()
            .is_some_and(|s| s.room_id == next.room_id())
        && next
            .predecessor_room()
            .is_some_and(|p| p.room_id == old.room_id())
}

impl MatrixCore {
    pub(crate) async fn follow_room_upgrades(&self) -> BTreeMap<OwnedRoomId, OwnedRoomId> {
        let mut replacements = BTreeMap::new();
        for old in self.client.joined_rooms() {
            let Some(successor) = old.successor_room() else {
                continue;
            };
            let Some(next) = self.client.get_room(&successor.room_id) else {
                continue;
            };
            // Never rejoin a declined replacement or follow an unrelated invite.
            if !matches!(next.state(), RoomState::Invited | RoomState::Joined)
                || !linked(&old, &next)
            {
                continue;
            }
            if let Ok(Some(member)) = next.get_member_no_sync(&self.own_user).await {
                use matrix_sdk::ruma::events::room::member::MembershipState;
                if matches!(
                    member.membership(),
                    MembershipState::Leave | MembershipState::Ban
                ) {
                    continue;
                }
            }
            if old.encryption_state().is_unknown() && old.request_encryption_state().await.is_err()
            {
                continue;
            }
            let was_encrypted = old.encryption_state().is_encrypted();
            if was_encrypted
                && !next.encryption_state().is_unknown()
                && !next.encryption_state().is_encrypted()
            {
                continue;
            }
            let joined_here = next.state() == RoomState::Invited;
            let next = if joined_here {
                match self.client.join_room_by_id(next.room_id()).await {
                    Ok(room) => room,
                    Err(_) => continue,
                }
            } else {
                next
            };
            if next.encryption_state().is_unknown()
                && next.request_encryption_state().await.is_err()
            {
                if joined_here {
                    let _ = next.leave().await;
                }
                continue;
            }
            let full_link = if joined_here {
                let request = get_state_event_for_key::v3::Request::new(
                    next.room_id().to_owned(),
                    StateEventType::RoomCreate,
                    String::new(),
                );
                let Ok(response) = self.client.send(request).await else {
                    let _ = next.leave().await;
                    continue;
                };
                let Ok(create) =
                    serde_json::from_str::<serde_json::Value>(response.event_or_content.get())
                else {
                    let _ = next.leave().await;
                    continue;
                };
                old.successor_room()
                    .is_some_and(|s| s.room_id == next.room_id())
                    && create["predecessor"]["room_id"].as_str() == Some(old.room_id().as_str())
            } else {
                linked(&old, &next)
            };
            if !full_link || (was_encrypted && !next.encryption_state().is_encrypted()) {
                // A stripped invitation must not become authority to send into
                // a mismatched or plaintext room after the full join completes.
                if joined_here {
                    let _ = next.leave().await;
                }
                continue;
            }
            replacements.insert(old.room_id().to_owned(), next.room_id().to_owned());
        }
        flatten(&replacements, |id| {
            self.client
                .get_room(id)
                .is_some_and(|room| room.is_tombstoned())
        })
    }
}

fn flatten(
    edges: &BTreeMap<OwnedRoomId, OwnedRoomId>,
    retired: impl Fn(&matrix_sdk::ruma::RoomId) -> bool,
) -> BTreeMap<OwnedRoomId, OwnedRoomId> {
    edges
        .keys()
        .filter_map(|source| {
            let mut current = source;
            let mut seen = BTreeSet::new();
            while let Some(next) = edges.get(current) {
                if !seen.insert(current) || seen.len() > 32 {
                    return None;
                }
                current = next;
            }
            if retired(current) {
                None
            } else {
                Some((source.clone(), current.clone()))
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn id(name: &str) -> OwnedRoomId {
        format!("!{name}:example.test").try_into().unwrap()
    }
    #[test]
    fn follows_completed_chains_and_rejects_cycles_and_unfinished_targets() {
        let edges = BTreeMap::from([(id("old"), id("middle")), (id("middle"), id("current"))]);
        let result = flatten(&edges, |_| false);
        assert_eq!(result.get(&id("old")), Some(&id("current")));
        assert_eq!(result.get(&id("middle")), Some(&id("current")));
        assert!(flatten(&edges, |target| target == id("current")).is_empty());
        let cycle = BTreeMap::from([(id("a"), id("b")), (id("b"), id("a"))]);
        assert!(flatten(&cycle, |_| true).is_empty());
    }
}
