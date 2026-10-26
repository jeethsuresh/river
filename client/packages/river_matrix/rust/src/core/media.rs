use anyhow::{Context, Result, ensure};
use matrix_sdk::{
    attachment::AttachmentConfig,
    ruma::events::room::message::{MessageType, RoomMessageEventContent},
};
use serde_json::json;

use super::connection::{MatrixCore, sdk_error};

impl MatrixCore {
    pub async fn send_attachment(
        &self,
        room: String,
        name: String,
        content_type: String,
        bytes: Vec<u8>,
        transaction: String,
    ) -> Result<String> {
        ensure!(
            bytes.len() <= 32 * 1024 * 1024,
            "Attachments must be at most 32 MiB"
        );
        let room = self.room(&room)?;
        room.request_encryption_state().await.map_err(sdk_error)?;
        let mime: mime::Mime = content_type.parse()?;
        let config = AttachmentConfig::new().txn_id(transaction.into());
        let response = room
            .send_attachment(name, &mime, bytes, config)
            .await
            .map_err(sdk_error)?;
        Ok(json!({"event_id": response.event_id}).to_string())
    }

    /// The SDK validates the MXC source and authenticates/decrypts encrypted
    /// attachment bytes using the key carried in the decrypted room event.
    pub async fn download_attachment(&self, content: String) -> Result<Vec<u8>> {
        self.active()?;
        let content: RoomMessageEventContent = serde_json::from_str(&content)?;
        let media = self.client.media();
        let bytes = match content.msgtype {
            MessageType::Image(content) => media.get_file(&content, true).await,
            MessageType::File(content) => media.get_file(&content, true).await,
            MessageType::Video(content) => media.get_file(&content, true).await,
            MessageType::Audio(content) => media.get_file(&content, true).await,
            _ => anyhow::bail!("This event has no attachment"),
        }
        .map_err(sdk_error)?
        .context("This event has no attachment")?;
        ensure!(
            bytes.len() <= 32 * 1024 * 1024,
            "Attachment exceeds this device's download limit"
        );
        Ok(bytes)
    }
}
