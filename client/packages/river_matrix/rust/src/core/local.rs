//! River UI records share the SDK's encrypted, account/device-specific state
//! store. These actions perform no HTTP requests, including after a restart.
use anyhow::{Context, Result, ensure};
use matrix_sdk::RoomState;
use matrix_sdk_store_encryption::StoreCipher;
use serde_json::{Value, json};

use super::connection::{MatrixCore, sdk_error};

impl MatrixCore {
    pub(crate) async fn local_data(&self, data: &Value, write: bool) -> Result<String> {
        self.active()?;
        let scope = data["scope"].as_str().context("Missing local scope")?;
        let key = match scope {
            "overview" => "river.ui.v1.overview".to_owned(),
            "history" | "draft" | "thread" => {
                let room_id = matrix_sdk::ruma::RoomId::parse(
                    data["room"].as_str().context("Missing room")?,
                )?;
                // Drafts are this device's own input. A newly created room may
                // not have reached the SDK yet, but typing must still persist
                // locally without waiting for a network sync. History and
                // threads continue to require a joined room.
                if scope != "draft" || self.client.get_room(&room_id).is_some() {
                    let room = self.room(room_id.as_str())?;
                    ensure!(
                        room.state() == RoomState::Joined,
                        "Room is no longer joined"
                    );
                }
                let suffix = if scope == "thread" {
                    matrix_sdk::ruma::EventId::parse(
                        data["event"].as_str().context("Missing thread root")?,
                    )?
                    .to_string()
                } else {
                    String::new()
                };
                format!("river.ui.v1.{scope}.{room_id}.{suffix}")
            }
            _ => anyhow::bail!("Invalid local scope"),
        };
        let store = self.client.state_store();
        if write {
            let value = data.get("value").context("Missing local value")?;
            ensure!(value.is_object() || value.is_null(), "Invalid local value");
            if value.is_null() {
                store
                    .remove_custom_value(key.as_bytes())
                    .await
                    .map_err(sdk_error)?;
            } else {
                let bytes = serde_json::to_vec(value)?;
                ensure!(bytes.len() <= 16 * 1024 * 1024, "Local record is too large");
                // SDK custom values bypass its ordinary value encryption.
                // Wrap each record with the SDK cipher and existing high-entropy
                // device secret; no shared cipher initialization race is needed.
                let cipher = StoreCipher::new()?;
                let secret = self.local_key.as_ref().context("Missing local store key")?;
                let exported = cipher.export_with_key(secret.as_bytes())?;
                let encrypted = cipher.encrypt_value(&json!({"key":key,"value":value}))?;
                let mut envelope = Vec::with_capacity(4 + exported.len() + encrypted.len());
                envelope.extend_from_slice(&(exported.len() as u32).to_be_bytes());
                envelope.extend_from_slice(&exported);
                envelope.extend_from_slice(&encrypted);
                store
                    .set_custom_value(key.as_bytes(), envelope)
                    .await
                    .map_err(sdk_error)?;
            }
            Ok("{}".into())
        } else {
            let value = store
                .get_custom_value(key.as_bytes())
                .await
                .map_err(sdk_error)?
                .map(|bytes| -> Result<Value> {
                    ensure!(bytes.len() >= 4, "Invalid local envelope");
                    let length = u32::from_be_bytes(bytes[..4].try_into()?) as usize;
                    ensure!(length <= bytes.len() - 4, "Invalid local envelope");
                    let secret = self.local_key.as_ref().context("Missing local store key")?;
                    let cipher =
                        StoreCipher::import_with_key(secret.as_bytes(), &bytes[4..4 + length])?;
                    let record: Value = cipher.decrypt_value(&bytes[4 + length..])?;
                    ensure!(record["key"] == key, "Local record belongs to another room");
                    Ok(record["value"].clone())
                })
                .transpose()?;
            Ok(json!({"value": value}).to_string())
        }
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
mod tests {
    use super::*;
    use matrix_sdk::{Client, RoomInfo, StateChanges, ruma::room_id};

    const PASSPHRASE: &str = "offline-cache-test-passphrase-at-least-32-bytes";
    const SESSION: &str =
        r#"{"user_id":"@alice:offline.invalid","device_id":"OFFLINE","access_token":"test-only"}"#;

    async fn open(path: &std::path::Path) -> Result<MatrixCore> {
        MatrixCore::open(
            "https://offline.invalid".into(),
            "@alice:offline.invalid".into(),
            path.to_string_lossy().into_owned(),
            PASSPHRASE.into(),
            Some(SESSION.into()),
        )
        .await
    }

    async fn exercise_sqlite_reopen(path: &std::path::Path) -> Result<()> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let seed = Client::builder()
            .homeserver_url("https://offline.invalid")
            .sqlite_store(path, Some(PASSPHRASE))
            .build()
            .await?;
        let room = room_id!("!cached:offline.invalid");
        let mut changes = StateChanges::default();
        changes
            .room_infos
            .insert(room.to_owned(), RoomInfo::new(room, RoomState::Joined));
        let left = room_id!("!left:offline.invalid");
        changes
            .room_infos
            .insert(left.to_owned(), RoomInfo::new(left, RoomState::Left));
        seed.state_store().save_changes(&changes).await?;
        drop(seed);
        let core = open(path).await.context("Open seeded SQLite store")?;
        let pending_room = "!new:offline.invalid";
        let pending_draft = json!({"text":"Draft before the first room sync"});
        assert!(
            core.action(
                json!({"action":"local_write","scope":"draft","room":left,"value":{}}).to_string()
            )
            .await
            .is_err()
        );
        core.action(json!({"action":"local_write","scope":"draft","room":pending_room,"value":pending_draft}).to_string()).await?;
        assert!(
            core.action(
                json!({"action":"local_write","scope":"draft","room":"not-a-room","value":{}})
                    .to_string()
            )
            .await
            .is_err()
        );
        let history = json!({"events":[{"event_id":"$old","content":{"body":"distinct-private-history-9dcac9"}}],"next_cursor":"older"});
        let draft = json!({"text":"distinct-private-draft-f25c2b","txn":"stable-retry-id"});
        for (scope, value) in [("history", history.clone()), ("draft", draft.clone())] {
            core.action(
                json!({"action":"local_write","scope":scope,"room":room,"value":value}).to_string(),
            )
            .await?;
        }
        core.close(false).await?;
        drop(core);
        let restored = open(path).await.context("Reopen cached SQLite store")?;
        let pending: Value = serde_json::from_str(
            &restored
                .action(
                    json!({"action":"local_read","scope":"draft","room":pending_room}).to_string(),
                )
                .await?,
        )?;
        assert_eq!(pending["value"], pending_draft);
        assert!(
            restored
                .action(
                    json!({"action":"local_read","scope":"history","room":pending_room})
                        .to_string()
                )
                .await
                .is_err()
        );
        for (scope, expected) in [("history", history), ("draft", draft)] {
            let result: Value = serde_json::from_str(
                &restored
                    .action(json!({"action":"local_read","scope":scope,"room":room}).to_string())
                    .await?,
            )?;
            assert_eq!(result["value"], expected);
        }
        let rooms: Value = serde_json::from_str(&restored.rooms().await?)?;
        assert!(
            rooms["rooms"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["room_id"] == room.as_str())
        );
        restored
            .action(
                json!({"action":"local_write","scope":"draft","room":room,"value":null})
                    .to_string(),
            )
            .await?;
        let cleared: Value = serde_json::from_str(
            &restored
                .action(json!({"action":"local_read","scope":"draft","room":room}).to_string())
                .await?,
        )?;
        assert!(cleared["value"].is_null());
        assert!(restored.action(json!({"action":"local_read","scope":"history","room":"!unknown:offline.invalid"}).to_string()).await.is_err());
        assert!(
            restored
                .action(json!({"action":"local_write","scope":"arbitrary","value":{}}).to_string())
                .await
                .is_err()
        );
        restored.close(false).await?;
        drop(restored);
        Ok(())
    }

    #[test]
    fn encrypted_history_and_drafts_survive_sqlite_reopen_without_network() -> Result<()> {
        let path = std::env::temp_dir().join(format!("river-local-{}", uuid::Uuid::new_v4()));
        {
            // SDK background tasks can retain SQLite pool handles until their
            // runtime stops. Drain them before inspecting/removing the fixture;
            // Windows correctly rejects deletion while those handles are open.
            let runtime = tokio::runtime::Runtime::new()?;
            runtime.block_on(exercise_sqlite_reopen(&path))?;
        }
        for file in std::fs::read_dir(&path).context("Inspect SQLite fixture directory")? {
            let file = file?.path();
            if file.is_file() {
                let bytes = std::fs::read(&file).context("Inspect SQLite fixture file")?;
                for secret in [
                    b"distinct-private-history-9dcac9".as_slice(),
                    b"distinct-private-draft-f25c2b".as_slice(),
                    b"Draft before the first room sync".as_slice(),
                ] {
                    assert!(
                        !bytes.windows(secret.len()).any(|part| part == secret),
                        "plaintext in {file:?}"
                    );
                }
            }
        }
        std::fs::remove_dir_all(path).context("Remove closed SQLite fixture")?;
        Ok(())
    }
}
