//! Real-device integration test. Uses only the disposable private-CA fixture;
//! production clients never accept a TLS bypass or a test certificate.
use super::connection::MatrixCore;
use anyhow::{Context, Result};
use matrix_sdk::{
    Client, ClientBuilder, RoomState,
    ruma::{
        EventId, RoomId,
        api::client::{
            account::register,
            room::{create_room, get_room_event},
            uiaa,
        },
        events::StateEventType,
    },
};
use serde_json::{Value, json};
use std::{io::Cursor, time::Duration};

async fn device(name: &str) -> Result<MatrixCore> {
    device_as(name, "cryptoalice").await
}

async fn device_as(name: &str, user: &str) -> Result<MatrixCore> {
    device_as_with(name, user, |builder| builder).await
}

async fn device_as_with(
    name: &str,
    user: &str,
    customize: impl FnOnce(ClientBuilder) -> ClientBuilder,
) -> Result<MatrixCore> {
    let homeserver = std::env::var("MATRIX_TEST_HOMESERVER")?;
    anyhow::ensure!(
        homeserver == "https://native.test:8448",
        "Only the isolated fixture is allowed"
    );
    let client = fixture_client(&homeserver, customize).await?;
    client
        .matrix_auth()
        .login_username(user, "password123")
        .device_id(name)
        .send()
        .await?;
    fixture_core(client)
}

async fn fixture_client(
    homeserver: &str,
    customize: impl FnOnce(ClientBuilder) -> ClientBuilder,
) -> Result<Client> {
    anyhow::ensure!(
        matches!(
            homeserver,
            "https://native.test:8448" | "https://reference.test:8448"
        ),
        "Only the isolated fixture is allowed"
    );
    let ca = std::fs::read(std::env::var("MATRIX_TEST_CA")?)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let store = std::env::temp_dir().join(format!("river-matrix-test-{}", uuid::Uuid::new_v4()));
    Ok(customize(Client::builder())
        .homeserver_url(homeserver)
        .with_encryption_settings(matrix_sdk::encryption::EncryptionSettings {
            backup_download_strategy:
                matrix_sdk::encryption::BackupDownloadStrategy::AfterDecryptionFailure,
            ..Default::default()
        })
        .respect_login_well_known(false)
        .add_root_certificates(vec![matrix_sdk::reqwest::Certificate::from_pem(&ca)?])
        .sqlite_store(&store, Some("isolated-test-store-passphrase-long-enough"))
        .build()
        .await?)
}

fn fixture_core(client: Client) -> Result<MatrixCore> {
    let user = client
        .user_id()
        .context("Test login did not establish a session")?
        .to_owned();
    Ok(MatrixCore::from_client(
        client,
        user,
        uuid::Uuid::new_v4().to_string(),
    ))
}

async fn synapse_device() -> Result<MatrixCore> {
    let client = fixture_client("https://reference.test:8448", |builder| builder).await?;
    let mut request = register::v3::Request::new();
    request.username = Some(format!("riverinterop{}", uuid::Uuid::new_v4().simple()));
    request.password = Some("isolated-test-device".into());
    request.auth = Some(uiaa::AuthData::Dummy(uiaa::Dummy::new()));
    client.matrix_auth().register(request).await?;
    fixture_core(client)
}
async fn step(clients: &[&MatrixCore]) -> Result<()> {
    for core in clients {
        core.sync()
            .await
            .context("River production sync path failed")?;
    }
    Ok(())
}

async fn assert_encrypted_wire_event(
    core: &MatrixCore,
    room: &RoomId,
    event: &EventId,
    plaintext: &str,
) -> Result<()> {
    let response = core
        .client
        .send(get_room_event::v3::Request::new(
            room.to_owned(),
            event.to_owned(),
        ))
        .await?;
    let wire: Value = serde_json::from_str(response.event.json().get())?;
    assert_eq!(wire["type"], "m.room.encrypted");
    assert_eq!(wire["content"]["algorithm"], "m.megolm.v1.aes-sha2");
    assert!(wire["content"]["ciphertext"].is_string());
    assert!(!wire["content"].to_string().contains(plaintext));
    Ok(())
}

async fn decrypted_event(core: &MatrixCore, room: &RoomId, event: &EventId) -> Result<Value> {
    tokio::time::timeout(Duration::from_secs(80), async {
        loop {
            core.sync().await?;
            let history: Value =
                serde_json::from_str(&core.history(room.to_string(), None).await?)?;
            if let Some(found) = history["events"]
                .as_array()
                .context("Missing room timeline")?
                .iter()
                .find(|item| item["event_id"] == event.as_str() && item["type"] == "m.room.message")
            {
                assert_eq!(found["river_encrypted"], true);
                return Ok(found.clone());
            }
        }
    })
    .await
    .with_context(|| format!("{event} did not decrypt for {} in {room}", core.own_user))?
}

async fn federated_round_trip(host: &MatrixCore, joiner: &MatrixCore, room: &RoomId) -> Result<()> {
    let room_id = room.to_string();
    let host_room = host
        .client
        .get_room(room)
        .context("Host cannot see its new room")?;
    host_room.request_encryption_state().await?;
    assert!(
        host_room.encryption_state().is_encrypted(),
        "Encryption must be set before the invite is accepted"
    );

    tokio::time::timeout(Duration::from_secs(80), async {
        loop {
            joiner.sync().await?;
            if joiner
                .client
                .get_room(room)
                .is_some_and(|room| room.state() == RoomState::Invited)
            {
                return Ok::<_, anyhow::Error>(());
            }
        }
    })
    .await
    .context("Federated invitation did not reach the other homeserver")??;
    assert_eq!(
        joiner
            .send(
                room_id.clone(),
                "m.room.message".into(),
                json!({"msgtype":"m.text", "body":"must be rejected before joining"}).to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await
            .expect_err("An invite must not allow a message to be sent")
            .to_string(),
        "Join this conversation before sending."
    );
    assert_eq!(
        joiner
            .send_attachment(
                room_id.clone(),
                "pre-join.txt".into(),
                "text/plain".into(),
                b"must be rejected before joining".to_vec(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await
            .expect_err("An invite must not allow an attachment to be uploaded")
            .to_string(),
        "Join this conversation before sending."
    );

    let response: Value = serde_json::from_str(
        &joiner
            .action(
                json!({
                    "action": "join", "room": room_id, "via": [host.own_user.server_name()],
                })
                .to_string(),
            )
            .await?,
    )?;
    assert_eq!(response["room_id"], room_id);
    tokio::time::timeout(Duration::from_secs(80), async {
        loop {
            host.sync().await?;
            let list: Value = serde_json::from_str(&host.members(room_id.clone()).await?)?;
            if list["members"]
                .as_array()
                .context("Missing room members")?
                .iter()
                .any(|member| {
                    member["user_id"] == joiner.own_user.as_str() && member["membership"] == "join"
                })
            {
                return Ok::<_, anyhow::Error>(());
            }
        }
    })
    .await
    .context("Accepted membership did not reach the room host")??;

    let mut previous = None;
    for (sender, recipient) in [(host, joiner), (joiner, host)] {
        let body = format!("Encrypted message from {}", sender.own_user);
        let mut content = json!({"msgtype":"m.text", "body":body});
        if let Some(ref event) = previous {
            content["m.relates_to"] = json!({"m.in_reply_to":{"event_id":event}});
        }
        let sent: Value = serde_json::from_str(
            &sender
                .send(
                    room_id.clone(),
                    "m.room.message".into(),
                    content.to_string(),
                    uuid::Uuid::new_v4().to_string(),
                )
                .await?,
        )?;
        let event = EventId::parse(
            sent["event_id"]
                .as_str()
                .context("Missing encrypted send ID")?,
        )?;
        assert_encrypted_wire_event(sender, room, &event, &body).await?;
        let received = decrypted_event(recipient, room, &event).await?;
        assert_eq!(received["sender"], sender.own_user.as_str());
        assert_eq!(received["content"]["body"], body);
        if let Some(ref replied_to) = previous {
            assert_eq!(
                received["content"]["m.relates_to"]["m.in_reply_to"]["event_id"],
                json!(replied_to)
            );
        }
        assert_encrypted_wire_event(recipient, room, &event, &body).await?;
        previous = Some(event);

        let filename = "federated-attachment.txt";
        let bytes = format!("Encrypted attachment sent by {}", sender.own_user).into_bytes();
        let uploaded: Value = serde_json::from_str(
            &sender
                .send_attachment(
                    room_id.clone(),
                    filename.into(),
                    "text/plain".into(),
                    bytes.clone(),
                    uuid::Uuid::new_v4().to_string(),
                )
                .await?,
        )?;
        let attachment = EventId::parse(
            uploaded["event_id"]
                .as_str()
                .context("Missing attachment ID")?,
        )?;
        let received = decrypted_event(recipient, room, &attachment).await?;
        assert_eq!(received["content"]["body"], filename);
        assert!(received["content"]["file"].is_object());
        assert_eq!(
            recipient
                .download_attachment(received["content"].to_string())
                .await?,
            bytes
        );
        assert_encrypted_wire_event(sender, room, &attachment, filename).await?;
        assert_encrypted_wire_event(recipient, room, &attachment, filename).await?;
    }

    joiner
        .action(json!({"action":"leave", "room":room_id}).to_string())
        .await?;
    assert_eq!(
        joiner
            .send(
                room_id,
                "m.room.message".into(),
                json!({"msgtype":"m.text", "body":"must be rejected after leaving"}).to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await
            .expect_err("A departed member must not send a message")
            .to_string(),
        "Join this conversation before sending."
    );
    println!(
        "RIVER MATRIX {}-hosted encrypted invite, join, bidirectional text/reply and media, and membership checks PASS",
        host.own_user.server_name()
    );
    Ok(())
}

#[tokio::test]
#[ignore = "requires the isolated Gravitas and Synapse HTTPS fixtures"]
async fn federated_encrypted_conversations() -> Result<()> {
    let river = device_as(
        &format!("RIVER-FEDERATION-{}", uuid::Uuid::new_v4()),
        "deactlater",
    )
    .await?;
    let external = synapse_device().await?;
    tokio::try_join!(river.sync(), external.sync())?;

    let response: Value = serde_json::from_str(
        &river
            .action(
                json!({
                    "action": "direct", "user": external.own_user,
                })
                .to_string(),
            )
            .await?,
    )?;
    let room = RoomId::parse(
        response["room_id"]
            .as_str()
            .context("River did not create a direct room")?,
    )?;
    federated_round_trip(&river, &external, &room).await?;

    let room = external.client.create_dm(&river.own_user).await?;
    federated_round_trip(&external, &river, room.room_id()).await?;

    river.close(true).await?;
    external.close(true).await?;
    Ok(())
}
fn image(code: &Value) -> Result<Vec<u8>> {
    let width = code["size"].as_u64().context("QR size")? as usize;
    let pixels = code["pixels"].as_array().context("QR pixels")?;
    let scale = 8;
    let mut image = image::GrayImage::from_pixel(
        ((width + 8) * scale) as u32,
        ((width + 8) * scale) as u32,
        image::Luma([255]),
    );
    for (index, color) in pixels.iter().enumerate() {
        if color.as_bool() == Some(true) {
            for dy in 0..scale {
                for dx in 0..scale {
                    image.put_pixel(
                        (((index % width) + 4) * scale + dx) as u32,
                        (((index / width) + 4) * scale + dy) as u32,
                        image::Luma([0]),
                    );
                }
            }
        }
    }
    let mut png = Cursor::new(Vec::new());
    image.write_to(&mut png, image::ImageFormat::Png)?;
    Ok(png.into_inner())
}

async fn automatic_room_replacements(first: &MatrixCore) -> Result<()> {
    use matrix_sdk::ruma::{
        RoomVersionId, api::client::room::upgrade_room,
        events::room::tombstone::RoomTombstoneEventContent,
    };
    let peer = device_as(
        &format!("RIVER-UPGRADE-{}", uuid::Uuid::new_v4()),
        "deactlater",
    )
    .await?;
    step(&[first, &peer]).await?;
    for encrypted in [false, true] {
        let mut create = create_room::v3::Request::new();
        create.room_version = Some(RoomVersionId::V11);
        create.invite = vec![peer.own_user.clone()];
        if encrypted {
            create.initial_state = vec![serde_json::from_value(
                json!({"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}),
            )?];
        }
        let old = first.client.create_room(create).await?;
        step(&[first, &peer]).await?;
        peer.client.join_room_by_id(old.room_id()).await?;
        for (core, target) in [(first, &peer.own_user), (&peer, &first.own_user)] {
            core.client
                .account()
                .mark_as_dm(old.room_id(), &[target.clone()])
                .await?;
        }
        step(&[first, &peer]).await?;
        let sent: Value = serde_json::from_str(
            &first
                .send(
                    old.room_id().to_string(),
                    "m.room.message".into(),
                    json!({"msgtype":"m.text","body":"history survives the version upgrade"})
                        .to_string(),
                    uuid::Uuid::new_v4().to_string(),
                )
                .await?,
        )?;
        step(&[first, &peer]).await?;
        let response = first
            .client
            .send(upgrade_room::v3::Request::new(
                old.room_id().to_owned(),
                RoomVersionId::V12,
            ))
            .await?;
        for _ in 0..8 {
            step(&[first, &peer]).await?;
            if peer
                .client
                .get_room(&response.replacement_room)
                .is_some_and(|r| r.state() == matrix_sdk::RoomState::Joined)
            {
                break;
            }
        }
        let target = peer
            .client
            .get_room(&response.replacement_room)
            .context("Replacement missing")?;
        assert_eq!(
            target.state(),
            matrix_sdk::RoomState::Joined,
            "River must accept a mutually linked replacement"
        );
        target.request_encryption_state().await?;
        assert_eq!(target.encryption_state().is_encrypted(), encrypted);
        let snapshot: Value = serde_json::from_str(&peer.rooms().await?)?;
        let historical = snapshot["rooms"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["room_id"] == old.room_id().as_str())
            .context("Historical room missing")?;
        assert_eq!(
            historical["replacement_room"],
            response.replacement_room.as_str()
        );
        let opened: Value = serde_json::from_str(
            &peer
                .action(json!({"action":"direct","user":first.own_user}).to_string())
                .await
                .with_context(|| format!("Open replacement direct (encrypted={encrypted})"))?,
        )?;
        assert_eq!(opened["room_id"], response.replacement_room.as_str());
        let delivered: Value = serde_json::from_str(
            &peer
                .send(
                    target.room_id().to_string(),
                    "m.room.message".into(),
                    json!({"msgtype":"m.text","body":"River sends through the replacement"})
                        .to_string(),
                    uuid::Uuid::new_v4().to_string(),
                )
                .await?,
        )?;
        if encrypted {
            let members = target
                .members_no_sync(matrix_sdk::RoomMemberships::JOIN)
                .await?;
            assert_eq!(
                members.len(),
                2,
                "Encryption must load both replacement members"
            );
        }
        let mut received = false;

        for _ in 0..16 {
            step(&[first, &peer]).await?;
            let after: Value =
                serde_json::from_str(&first.history(target.room_id().to_string(), None).await?)?;
            if after["events"].as_array().unwrap().iter().any(|e| {
                e["event_id"] == delivered["event_id"]
                    && e["content"]["body"] == "River sends through the replacement"
            }) {
                received = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        assert!(received, "Replacement delivery encrypted={encrypted}");
        assert!(
            first
                .send(
                    old.room_id().to_string(),
                    "m.room.message".into(),
                    json!({"body":"must not go to old room"}).to_string(),
                    uuid::Uuid::new_v4().to_string()
                )
                .await
                .is_err()
        );
        let history: Value =
            serde_json::from_str(&peer.history(old.room_id().to_string(), None).await?)?;
        assert!(
            history["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|e| e["event_id"] == sent["event_id"]
                    && e["content"]["body"] == "history survives the version upgrade")
        );
        target.leave().await?;
        step(&[first, &peer]).await?;
        peer.rooms().await?;
        assert_eq!(
            target.state(),
            matrix_sdk::RoomState::Left,
            "A declined replacement must not be rejoined"
        );
    }
    for downgrade in [false, true] {
        let mut create = create_room::v3::Request::new();
        create.room_version = Some(RoomVersionId::V11);
        create.invite = vec![peer.own_user.clone()];
        if downgrade {
            create.initial_state = vec![serde_json::from_value(
                json!({"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}),
            )?];
        }
        let old = first.client.create_room(create).await?;
        step(&[first, &peer]).await?;
        peer.client.join_room_by_id(old.room_id()).await?;
        step(&[first, &peer]).await?;
        let mut candidate = create_room::v3::Request::new();
        candidate.room_version = Some(RoomVersionId::V12);
        candidate.invite = vec![peer.own_user.clone()];
        if downgrade {
            candidate.creation_content = Some(serde_json::from_value(
                json!({"predecessor":{"room_id":old.room_id()}}),
            )?);
        }
        let candidate = first.client.create_room(candidate).await?;
        old.send_state_event(RoomTombstoneEventContent::new(
            "Test replacement".into(),
            candidate.room_id().to_owned(),
        ))
        .await?;
        step(&[first, &peer]).await?;
        assert_ne!(
            peer.client
                .get_room(candidate.room_id())
                .context("Candidate invite missing")?
                .state(),
            matrix_sdk::RoomState::Joined,
            "Unrelated or plaintext replacements must not remain joined"
        );
    }
    peer.close(true).await?;
    println!(
        "RIVER MATRIX automatic replacements, encrypted history, declined invites and downgrade rejection PASS"
    );
    Ok(())
}

async fn restored_member_cache(first: &MatrixCore) -> Result<()> {
    use matrix_sdk::ruma::api::client::membership::invite_user::v3::{
        InvitationRecipient, InviteUserId, Request,
    };
    let peer = device_as(
        &format!("RIVER-ROSTER-{}", uuid::Uuid::new_v4()),
        "deactlater",
    )
    .await?;
    // Discover this recipient's new device before deliberately making only
    // the room roster stale below.
    step(&[&peer, first]).await?;
    let mut create = create_room::v3::Request::new();
    create.initial_state = vec![serde_json::from_value(
        json!({"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}),
    )?];
    let room = first.client.create_room(create).await?;
    step(&[first]).await?;
    assert_eq!(
        room.members(matrix_sdk::RoomMemberships::ACTIVE)
            .await?
            .len(),
        1
    );
    assert!(room.are_members_synced());
    // Another device can change membership while this device is offline. Use
    // the raw API so this sender retains its stale, supposedly complete roster.
    first
        .client
        .send(Request::new(
            room.room_id().to_owned(),
            InvitationRecipient::UserId(InviteUserId::new(peer.own_user.clone())),
        ))
        .await?;
    step(&[&peer]).await?;
    peer.client.join_room_by_id(room.room_id()).await?;
    assert_eq!(
        room.members_no_sync(matrix_sdk::RoomMemberships::JOIN)
            .await?
            .len(),
        1
    );
    let restored = MatrixCore::from_client(
        first.client.clone(),
        first.own_user.clone(),
        uuid::Uuid::new_v4().to_string(),
    );
    let sent: Value = serde_json::from_str(
        &restored
            .send(
                room.room_id().to_string(),
                "m.room.message".into(),
                json!({"msgtype":"m.text","body":"restored devices reload recipients"}).to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await?,
    )?;
    assert_eq!(
        room.members_no_sync(matrix_sdk::RoomMemberships::JOIN)
            .await?
            .len(),
        2
    );
    let mut received = false;
    for _ in 0..16 {
        step(&[&peer]).await?;
        let history: Value =
            serde_json::from_str(&peer.history(room.room_id().to_string(), None).await?)?;
        if history["events"].as_array().unwrap().iter().any(|e| {
            e["event_id"] == sent["event_id"]
                && e["content"]["body"] == "restored devices reload recipients"
        }) {
            received = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(
        received,
        "A restored device must refresh stale recipients before encrypting"
    );
    peer.close(true).await?;
    println!("RIVER MATRIX restored stale member cache and encrypted recipient delivery PASS");
    Ok(())
}

async fn direct_room_permissions(first: &MatrixCore) -> Result<()> {
    let peer = device_as(&format!("RIVER-DM-{}", uuid::Uuid::new_v4()), "deactlater").await?;
    step(&[first, &peer]).await?;
    let mut create = create_room::v3::Request::new();
    create.is_direct = true;
    create.invite = vec![peer.own_user.clone()];
    create.power_level_content_override = Some(serde_json::from_value(json!({
        "users": { first.own_user.as_str(): 100 },
        "users_default": 0, "state_default": 100, "events_default": 0
    }))?);
    let legacy = first.client.create_room(create).await?;
    step(&[first, &peer]).await?;
    peer.action(json!({"action":"join", "room":legacy.room_id()}).to_string())
        .await?;
    peer.client
        .account()
        .mark_as_dm(legacy.room_id(), &[first.own_user.clone()])
        .await?;
    step(&[first, &peer]).await?;
    let joined = peer
        .client
        .get_room(legacy.room_id())
        .context("Joined DM missing")?;
    joined.request_encryption_state().await?;
    assert!(!joined.encryption_state().is_encrypted());
    assert!(
        !joined
            .power_levels_or_default()
            .await
            .user_can_send_state(&peer.own_user, StateEventType::RoomEncryption)
    );
    let acl_event = serde_json::to_value(
        joined
            .get_state_event(StateEventType::RoomPowerLevels, "")
            .await?,
    )?;
    let acl = acl_event["content"].clone();
    assert_eq!(acl["state_default"], 100);
    let opened: Value = serde_json::from_str(
        &peer
            .action(json!({"action":"direct", "user":first.own_user}).to_string())
            .await?,
    )?;
    assert_eq!(opened["room_id"], legacy.room_id().as_str());
    assert!(!joined.encryption_state().is_encrypted());
    assert_eq!(
        serde_json::to_value(
            joined
                .get_state_event(StateEventType::RoomPowerLevels, "")
                .await?
        )?["content"],
        acl
    );

    // The creator can upgrade the same legacy DM. The other participant then
    // reopens it without changing its encryption state or power levels.
    let upgraded: Value = serde_json::from_str(
        &first
            .action(json!({"action":"direct", "user":peer.own_user}).to_string())
            .await?,
    )?;
    assert_eq!(upgraded["room_id"], legacy.room_id().as_str());
    step(&[first, &peer]).await?;
    assert!(joined.encryption_state().is_encrypted());
    peer.action(json!({"action":"direct", "user":first.own_user}).to_string())
        .await?;
    assert!(joined.encryption_state().is_encrypted());
    assert_eq!(
        serde_json::to_value(
            joined
                .get_state_event(StateEventType::RoomPowerLevels, "")
                .await?
        )?["content"],
        acl
    );

    let fallback: Value = serde_json::from_str(
        &first
            .action(
                json!({
                    "action": "unencrypted_fallback", "room": legacy.room_id(),
                })
                .to_string(),
            )
            .await?,
    )?;
    let fallback_id = matrix_sdk::ruma::RoomId::parse(
        fallback["room_id"]
            .as_str()
            .context("Unencrypted room ID missing")?,
    )?;
    assert_ne!(
        fallback_id.as_ref() as &matrix_sdk::ruma::RoomId,
        legacy.room_id()
    );
    step(&[first, &peer]).await?;
    step(&[first, &peer]).await?;
    for core in [first, &peer] {
        let rooms: Value = serde_json::from_str(&core.rooms().await?)?;
        assert!(rooms["rooms"].as_array().unwrap().iter().any(|r| {
            r["room_id"] == fallback_id.as_str()
                && r["fallback_for"] == legacy.room_id().as_str()
                && r["encrypted"] == false
        }));
        let reused: Value = serde_json::from_str(
            &core
                .action(
                    json!({
                        "action": "unencrypted_fallback", "room": legacy.room_id(),
                    })
                    .to_string(),
                )
                .await?,
        )?;
        assert_eq!(reused["room_id"], fallback_id.as_str());
    }
    let content = json!({"msgtype": "m.text", "body": "Explicit unencrypted fallback"});
    let sent: Value = serde_json::from_str(
        &first
            .send(
                fallback_id.to_string(),
                "m.room.message".into(),
                content.to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await?,
    )?;
    let raw = peer
        .client
        .send(
            matrix_sdk::ruma::api::client::room::get_room_event::v3::Request::new(
                fallback_id.clone(),
                matrix_sdk::ruma::EventId::parse(
                    sent["event_id"]
                        .as_str()
                        .context("Missing fallback event")?,
                )?,
            ),
        )
        .await?;
    let raw: Value = serde_json::from_str(raw.event.json().get())?;
    assert_eq!(raw["type"], "m.room.message");
    assert_eq!(raw["content"], content);
    assert!(joined.encryption_state().is_encrypted());

    peer.action(json!({"action": "leave", "room": fallback_id}).to_string())
        .await?;
    assert!(
        first
            .send(
                fallback_id.to_string(),
                "m.room.message".into(),
                content.to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await
            .is_err(),
        "A stale sync roster must not authorize unencrypted sending"
    );

    let new_peer = matrix_sdk::ruma::UserId::parse("@deactclient:native.test:8448")?;
    assert!(first.client.get_dm_room(&new_peer).is_none());
    let created: Value = serde_json::from_str(
        &first
            .action(json!({"action":"direct", "user":new_peer}).to_string())
            .await?,
    )?;
    let created_id =
        matrix_sdk::ruma::RoomId::parse(created["room_id"].as_str().context("New DM ID missing")?)?;
    let room = first
        .client
        .get_room(&created_id)
        .context("New DM missing")?;
    room.request_encryption_state().await?;
    assert!(room.encryption_state().is_encrypted());
    let sent: Value = serde_json::from_str(
        &first
            .send(
                created_id.to_string(),
                "m.room.message".into(),
                json!({"msgtype":"m.text", "body":"new DM stays encrypted"}).to_string(),
                format!("dm-encrypted-{}", uuid::Uuid::new_v4()),
            )
            .await?,
    )?;
    let raw = first
        .client
        .send(
            matrix_sdk::ruma::api::client::room::get_room_event::v3::Request::new(
                created_id,
                matrix_sdk::ruma::EventId::parse(
                    sent["event_id"].as_str().context("DM message ID missing")?,
                )?,
            ),
        )
        .await?;
    let raw: Value = serde_json::from_str(raw.event.json().get())?;
    assert_eq!(raw["type"], "m.room.encrypted");
    assert!(
        !raw["content"]
            .to_string()
            .contains("new DM stays encrypted")
    );
    let fresh = device_as_with(
        &format!("RIVER-PLAIN-{}", uuid::Uuid::new_v4()),
        "deactclient",
        |builder| {
            builder.with_room_key_recipient_strategy(
                matrix_sdk_crypto::CollectStrategy::IdentityBasedStrategy,
            )
        },
    )
    .await?;
    let result: Value = serde_json::from_str(
        &fresh
            .action(
                json!({
                    "action":"direct", "user":peer.own_user, "prefer_encryption":false,
                })
                .to_string(),
            )
            .await?,
    )?;
    let wire = result["room_id"]
        .as_str()
        .context("Plain direct room missing")?;
    step(&[&fresh, &peer]).await?;
    let room = fresh.room(wire)?;
    assert!(!room.encryption_state().is_encrypted());
    let result: Value = serde_json::from_str(
        &fresh
            .send(
                wire.into(),
                "m.room.message".into(),
                json!({"msgtype":"m.text", "body":"direct chat without verification"}).to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await?,
    )?;
    assert!(result["event_id"].is_string());
    let mut request = create_room::v3::Request::new();
    request.invite = vec![peer.own_user.clone()];
    request.initial_state = vec![serde_json::from_value(json!({
        "type": "m.room.encryption", "state_key": "",
        "content": {"algorithm": "m.megolm.v1.aes-sha2"},
    }))?];
    let encrypted = fresh.client.create_room(request).await?;
    step(&[&fresh, &peer]).await?;
    let blocked: Value = serde_json::from_str(
        &fresh
            .send(
                encrypted.room_id().to_string(),
                "m.room.message".into(),
                json!({"msgtype":"m.text", "body":"encryption requires device verification"})
                    .to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await?,
    )?;
    assert_eq!(blocked, json!({"encryption_unavailable": true}));
    fresh.close(true).await?;
    peer.close(true).await?;
    println!("RIVER MATRIX new/encrypted/legacy DM permissions and unchanged ACL PASS");
    Ok(())
}

async fn encrypted_notification_previews(first: &MatrixCore) -> Result<()> {
    let peer = device_as(
        &format!("RIVER-NOTIFY-{}", uuid::Uuid::new_v4()),
        "deactlater",
    )
    .await?;
    step(&[first, &peer]).await?;
    let mut create = create_room::v3::Request::new();
    create.name = Some("Notification friends".into());
    create.invite = vec![peer.own_user.clone()];
    create.initial_state = vec![serde_json::from_value(
        json!({"type":"m.room.encryption","state_key":"",
        "content":{"algorithm":"m.megolm.v1.aes-sha2"}}),
    )?];
    let room = first.client.create_room(create).await?;
    step(&[first, &peer]).await?;
    peer.client.join_room_by_id(room.room_id()).await?;
    step(&[&peer, first]).await?;
    let sent: Value = serde_json::from_str(
        &first
            .send(
                room.room_id().to_string(),
                "m.room.message".into(),
                json!({"msgtype":"m.text","body":"Hello 🌊🔐 from another device"}).to_string(),
                uuid::Uuid::new_v4().to_string(),
            )
            .await?,
    )?;
    let event = sent["event_id"].as_str().unwrap();
    // Do not sync the recipient: the notification operation must fetch its
    // to-device room key itself using the ordinary shared SDK sync.
    let mut result = json!({});
    for attempt in 0..3 {
        result = serde_json::from_str(
            &peer
                .action(
                    json!({"action":"notification","room":room.room_id(),"event":event})
                        .to_string(),
                )
                .await?,
        )?;
        if result["needs_sync"] != true {
            break;
        }
        if attempt < 2 {
            peer.sync().await?;
        }
    }
    assert_eq!(result["title"], "Notification friends");
    assert_eq!(result["body"], "Hello 🌊🔐 from another device");
    let raw = first
        .client
        .send(
            matrix_sdk::ruma::api::client::room::get_room_event::v3::Request::new(
                room.room_id().to_owned(),
                matrix_sdk::ruma::EventId::parse(event)?,
            ),
        )
        .await?;
    assert_eq!(
        serde_json::from_str::<Value>(raw.event.json().get())?["type"],
        "m.room.encrypted"
    );
    let own: Value =
        serde_json::from_str(&first.notification(room.room_id().as_str(), event).await?)?;
    assert!(own.as_object().unwrap().is_empty());
    room.redact(&matrix_sdk::ruma::EventId::parse(event)?, None, None)
        .await?;
    let removed: Value =
        serde_json::from_str(&peer.notification(room.room_id().as_str(), event).await?)?;
    assert!(removed.as_object().unwrap().is_empty());
    peer.close(true).await?;
    println!(
        "RIVER MATRIX encrypted notification fetch, to-device key sync, emoji preview and redaction PASS"
    );
    Ok(())
}

#[tokio::test]
#[ignore = "requires the isolated Gravitas/Synapse fixture; run integration/matrix/run.sh"]
async fn qr_verification_recovers_historical_encrypted_messages() -> Result<()> {
    let prefix = uuid::Uuid::new_v4().simple().to_string();
    let first = device(&format!("RIVER-A-{prefix}")).await?;
    step(&[&first]).await?;
    let mut recovery: Value = serde_json::from_str(&first.setup_recovery(None).await?)?;
    if let Some(auth) = recovery.get("authentication") {
        recovery = serde_json::from_str(
            &first
                .setup_recovery(Some(
                    json!({
                        "type": "m.login.password", "session": auth["session"],
                        "identifier": {"type":"m.id.user", "user":first.own_user},
                        "password":"password123"
                    })
                    .to_string(),
                ))
                .await?,
        )?;
    }
    let key = recovery["recovery_key"]
        .as_str()
        .context("No recovery key was returned")?
        .to_owned();
    let mut create = create_room::v3::Request::new();
    create.initial_state.push(serde_json::from_value(
        json!({"type":"m.room.encryption", "state_key":"",
        "content":{"algorithm":"m.megolm.v1.aes-sha2"}}),
    )?);
    let room = first.client.create_room(create).await?;
    step(&[&first]).await?;
    let room_id = room.room_id().to_string();
    let sliding: Value = serde_json::from_str(&first.sync().await?)?;
    assert!(
        sliding["rooms"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["room_id"] == room_id && r["encrypted"] == true)
    );
    let event: Value = serde_json::from_str(
        &first
            .send(
                room_id.clone(),
                "m.room.message".into(),
                json!({"msgtype":"m.text","body":"history before the second device"}).to_string(),
                format!("history-{prefix}"),
            )
            .await?,
    )?;
    let event_id = matrix_sdk::ruma::EventId::parse(event["event_id"].as_str().unwrap())?;
    let raw = first
        .client
        .send(
            matrix_sdk::ruma::api::client::room::get_room_event::v3::Request::new(
                room.room_id().to_owned(),
                event_id.clone(),
            ),
        )
        .await?;
    let raw: Value = serde_json::from_str(raw.event.json().get())?;
    assert_eq!(raw["type"], "m.room.encrypted");
    assert!(
        !raw["content"]
            .to_string()
            .contains("history before the second device")
    );
    step(&[&first]).await?;
    tokio::time::timeout(
        Duration::from_secs(45),
        first.client.encryption().backups().wait_for_steady_state(),
    )
    .await??;
    let second = device(&format!("RIVER-B-{prefix}")).await?;
    step(&[&first, &second]).await?;
    let request: Value = serde_json::from_str(
        &first
            .request_verification(second.client.device_id().unwrap().to_string())
            .await?,
    )?;
    let flow = request["id"].as_str().unwrap().to_owned();
    step(&[&second]).await?;
    second
        .verification_action(flow.clone(), "accept".into())
        .await?;
    step(&[&first]).await?;
    let code: Value = serde_json::from_str(&first.verification_qr(flow.clone()).await?)?;
    let png = image(&code)?;
    assert!(
        second
            .scan_verification_image("another-transaction".into(), png.clone())
            .await
            .is_err()
    );
    second.scan_verification_image(flow.clone(), png).await?;
    step(&[&first]).await?;
    let status: Value = serde_json::from_str(&first.security().await?)?;
    assert!(
        status["requests"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == flow && r["scanned"] == true)
    );
    // The displaying device requires a human confirmation; scanning alone
    // must not mark the other device trusted.
    let other = first
        .client
        .encryption()
        .get_device(&first.own_user, second.client.device_id().unwrap())
        .await?
        .unwrap();
    assert!(!other.is_verified());
    first
        .verification_action(flow.clone(), "confirm_qr".into())
        .await?;
    for _ in 0..6 {
        step(&[&first, &second]).await?;
    }
    let mut status: Value = serde_json::from_str(&second.security().await?)?;
    for _ in 0..20 {
        if status["identity_verified"] == true
            && status["has_private_identity"] == true
            && status["backup_enabled"] == true
        {
            break;
        }
        step(&[&first, &second]).await?;
        tokio::time::sleep(Duration::from_millis(250)).await;
        status = serde_json::from_str(&second.security().await?)?;
    }
    assert_eq!(status["identity_verified"], true);
    assert_eq!(status["has_private_identity"], true);
    assert_eq!(
        status["backup_enabled"], true,
        "QR verification must transfer the encrypted backup secret"
    );
    let mut recovered = false;
    for _ in 0..20 {
        let historical: Value =
            serde_json::from_str(&second.history(room_id.clone(), None).await?)?;
        if historical["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["content"]["body"] == "history before the second device")
        {
            recovered = true;
            break;
        }
        step(&[&first, &second]).await?;
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(
        recovered,
        "Historical encrypted message was not recovered from backup"
    );
    let attachment = vec![0x5a; 32 * 1024 * 1024];
    assert!(
        first
            .send_attachment(
                room_id.clone(),
                "too-large.bin".into(),
                "application/octet-stream".into(),
                vec![0x5a; attachment.len() + 1],
                format!("oversize-{prefix}"),
            )
            .await
            .is_err()
    );
    let sent = first
        .send_attachment(
            room_id.clone(),
            "proof.txt".into(),
            "text/plain".into(),
            attachment.clone(),
            format!("file-{prefix}"),
        )
        .await?;
    let sent: Value = serde_json::from_str(&sent)?;
    for _ in 0..3 {
        step(&[&first, &second]).await?;
    }
    let files: Value = serde_json::from_str(&second.history(room_id, None).await?)?;
    let file = files["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["event_id"] == sent["event_id"])
        .context("attachment not found")?;
    assert!(file["content"]["file"].is_object());
    assert_eq!(
        second
            .download_attachment(file["content"].to_string())
            .await?,
        attachment
    );
    // A third device exercises the separate recovery-key path without QR.
    let third = device(&format!("RIVER-C-{prefix}")).await?;
    step(&[&third]).await?;
    third.recover(key).await?;
    let status: Value = serde_json::from_str(&third.security().await?)?;
    assert_eq!(status["identity_verified"], true);
    let mut recovered = false;
    for _ in 0..20 {
        let history: Value =
            serde_json::from_str(&third.history(room.room_id().to_string(), None).await?)?;
        if history["events"].as_array().unwrap().iter().any(|e| {
            e["event_id"] == event["event_id"]
                && e["content"]["body"] == "history before the second device"
        }) {
            recovered = true;
            break;
        }
        step(&[&third]).await?;
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(
        recovered,
        "Recovery-key device did not decrypt historical messages"
    );
    direct_room_permissions(&first).await?;
    automatic_room_replacements(&first).await?;
    restored_member_cache(&first).await?;
    encrypted_notification_previews(&first).await?;
    first.close(true).await?;
    second.close(true).await?;
    third.close(true).await?;
    println!(
        "RIVER MATRIX QR, cross-signing, backup recovery, historical decryption and encrypted attachment PASS"
    );
    Ok(())
}
