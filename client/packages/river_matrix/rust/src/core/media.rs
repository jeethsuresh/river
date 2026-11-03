use anyhow::{Context, Result, ensure};
use matrix_sdk::{
    attachment::AttachmentConfig,
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    ruma::{
        OwnedMxcUri,
        events::room::{
            MediaSource,
            message::{MessageType, RoomMessageEventContent},
        },
        serde::Base64,
    },
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
        let room = self.writable_room(&room)?;
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

    /// Avatars use the authenticated SDK media cache on web and native. Keep
    /// access tokens out of image URLs and request a small, static thumbnail.
    pub(crate) async fn avatar(&self, url: &str) -> Result<String> {
        self.active()?;
        let url: OwnedMxcUri = url.into();
        url.validate()?;
        let source = MediaSource::Plain(url);
        let media = self.client.media();
        let work = async {
            let thumbnail = media
                .get_media_content(
                    &MediaRequestParameters {
                        source: source.clone(),
                        format: MediaFormat::Thumbnail(MediaThumbnailSettings::new(
                            96u32.into(),
                            96u32.into(),
                        )),
                    },
                    true,
                )
                .await;
            let bytes = match thumbnail {
                Ok(bytes) => bytes,
                // Some homeservers only provide the original. This also uses
                // authenticated SDK media access and its persistent cache.
                Err(_) => media
                    .get_media_content(
                        &MediaRequestParameters {
                            source,
                            format: MediaFormat::File,
                        },
                        true,
                    )
                    .await
                    .map_err(sdk_error)?,
            };
            ensure!(
                bytes.len() <= 2 * 1024 * 1024,
                "Avatar exceeds this device's download limit"
            );
            Ok::<_, anyhow::Error>(bytes)
        };
        let bytes =
            matrix_sdk_common::timeout::timeout(work, std::time::Duration::from_secs(15)).await??;
        self.active()?;
        let data: Base64 = Base64::new(bytes);
        Ok(json!({"data": data}).to_string())
    }
}
