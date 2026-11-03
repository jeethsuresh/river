//! Notification content is fetched and decrypted by the existing SDK device.
//! The distributor receives identifiers only; this result never leaves River.
use super::connection::MatrixCore;
use anyhow::{Context, Result};
use matrix_sdk::{
    RoomState,
    config::RequestConfig,
    ruma::{EventId, RoomId, UserId},
};
use serde_json::{Value, json};
use std::time::Duration;

fn preview(event: &Value, own_user: &str) -> Option<String> {
    if event["type"] != "m.room.message"
        || event["sender"] == own_user
        || event["unsigned"].get("redacted_because").is_some()
        || event["content"]["m.relates_to"]["rel_type"] == "m.replace"
    {
        return None;
    }
    let content = &event["content"];
    let text = match content["msgtype"].as_str()? {
        "m.text" | "m.notice" | "m.emote" => content["body"].as_str()?,
        "m.image" => "Photo",
        "m.video" => "Video",
        "m.audio" => "Audio message",
        "m.file" => "File",
        "m.location" => "Location",
        _ => return None,
    };
    let text: String = text
        .chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .take(500)
        .collect();
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

impl MatrixCore {
    pub(crate) async fn notification(&self, room: &str, event: &str) -> Result<String> {
        let room_id = RoomId::parse(room)?;
        let event_id = EventId::parse(event)?;
        let work = async {
            self.active()?;
            let Some(room) = self.client.get_room(&room_id) else {
                return Ok(json!({"needs_sync": true}));
            };
            if room.state() != RoomState::Joined {
                return Ok(json!({}));
            }
            let event = room
                .event(
                    &event_id,
                    Some(
                        RequestConfig::default()
                            .timeout(Duration::from_secs(10))
                            .retry_limit(0),
                    ),
                )
                .await?;
            let value: Value = serde_json::from_str(event.raw().json().get())?;
            if value["event_id"] != event_id.as_str()
                || value["unsigned"].get("redacted_because").is_some()
            {
                return Ok(json!({}));
            }
            if value["type"] == "m.room.encrypted" {
                // Dart performs the bounded key sync through its durable
                // transport, saving rotated tokens before fetching again.
                return Ok(json!({"needs_sync": true}));
            }
            // An encrypted room must never preview an injected plaintext event.
            if room.encryption_state().is_encrypted() && event.encryption_info().is_none() {
                return Ok(json!({}));
            }
            let Some(body) = preview(&value, self.own_user.as_str()) else {
                return Ok(json!({}));
            };
            let sender = UserId::parse(value["sender"].as_str().context("Missing sender")?)?;
            let member = room.get_member_no_sync(&sender).await?;
            let sender_name = member
                .as_ref()
                .and_then(|m| m.display_name())
                .unwrap_or(sender.as_str())
                .to_owned();
            let title = room.display_name().await?.to_string();
            Ok::<_, anyhow::Error>(json!({"title": title, "sender": sender_name, "body": body}))
        };
        let result = matrix_sdk_common::timeout::timeout(work, Duration::from_secs(20)).await??;
        self.active()?;
        Ok(result.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_message_content_is_previewed() {
        let event = json!({"type":"m.room.message", "sender":"@bob:test", "content":{
            "msgtype":"m.text", "body":"Hello 🌊🔐", "format":"org.matrix.custom.html", "formatted_body":"wrong"}});
        assert_eq!(
            preview(&event, "@alice:test").as_deref(),
            Some("Hello 🌊🔐")
        );
        assert!(preview(&event, "@bob:test").is_none());
        let mut redacted = event.clone();
        redacted["unsigned"] = json!({"redacted_because":{}});
        assert!(preview(&redacted, "@alice:test").is_none());
        let mut edited = event.clone();
        edited["content"]["m.relates_to"] = json!({"rel_type":"m.replace"});
        assert!(preview(&edited, "@alice:test").is_none());
        let encrypted = json!({"type":"m.room.encrypted", "sender":"@bob:test", "content":{"body":"untrusted"}});
        assert!(preview(&encrypted, "@alice:test").is_none());
        let attachment = json!({"type":"m.room.message", "sender":"@bob:test", "content":{"msgtype":"m.file","body":"secret.pdf"}});
        assert_eq!(preview(&attachment, "@alice:test").as_deref(), Some("File"));
    }
}
