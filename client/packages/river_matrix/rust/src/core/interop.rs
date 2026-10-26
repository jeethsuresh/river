//! Real-device integration test. Uses only the disposable private-CA fixture;
//! production clients never accept a TLS bypass or a test certificate.
use super::connection::MatrixCore;
use anyhow::{Context, Result};
use matrix_sdk::{Client, ruma::api::client::room::create_room};
use serde_json::{Value, json};
use std::{io::Cursor, time::Duration};

async fn device(name: &str) -> Result<MatrixCore> {
    let homeserver = std::env::var("MATRIX_TEST_HOMESERVER")?;
    anyhow::ensure!(
        homeserver == "https://native.test:8448",
        "Only the isolated fixture is allowed"
    );
    let ca = std::fs::read(std::env::var("MATRIX_TEST_CA")?)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let store = std::env::temp_dir().join(format!("river-matrix-test-{}", uuid::Uuid::new_v4()));
    let client = Client::builder()
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
        .await?;
    client
        .matrix_auth()
        .login_username("cryptoalice", "password123")
        .device_id(name)
        .send()
        .await?;
    Ok(MatrixCore::from_client(
        client.clone(),
        client.user_id().unwrap().to_owned(),
        uuid::Uuid::new_v4().to_string(),
    ))
}
async fn step(clients: &[&MatrixCore]) -> Result<()> {
    for core in clients {
        core.sync()
            .await
            .context("River production sync path failed")?;
    }
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
    let sent = first
        .send_attachment(
            room_id.clone(),
            "proof.txt".into(),
            "text/plain".into(),
            b"encrypted attachment".to_vec(),
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
        b"encrypted attachment"
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
    first.close(true).await?;
    second.close(true).await?;
    third.close(true).await?;
    println!(
        "RIVER MATRIX QR, cross-signing, backup recovery, historical decryption and encrypted attachment PASS"
    );
    Ok(())
}
