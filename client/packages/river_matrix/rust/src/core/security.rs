use std::io::Cursor;

use anyhow::{Context, Result, bail, ensure};
use matrix_sdk::{
    encryption::verification::{
        QrVerificationData, Verification, VerificationRequest, VerificationRequestState,
    },
    ruma::{DeviceId, api::client::uiaa::AuthData, events::key::verification::VerificationMethod},
};
use serde_json::json;

use super::connection::{MatrixCore, sdk_error};

fn verification_methods() -> Vec<VerificationMethod> {
    vec![
        VerificationMethod::SasV1,
        VerificationMethod::QrCodeShowV1,
        VerificationMethod::QrCodeScanV1,
        VerificationMethod::ReciprocateV1,
    ]
}

impl MatrixCore {
    pub async fn security(&self) -> Result<String> {
        self.active()?;
        let encryption = self.client.encryption();
        let identity = encryption
            .request_user_identity(&self.own_user)
            .await
            .map_err(sdk_error)?;
        let devices = encryption
            .get_user_devices(&self.own_user)
            .await
            .map_err(sdk_error)?;
        let mut requests = Vec::new();
        for id in self.verification_flows.lock().await.clone() {
            if let Some(request) = encryption
                .get_verification_request(&self.own_user, &id)
                .await
            {
                let mut value = json!({"id": id, "ready": request.is_ready(),
                    "done": request.is_done(), "cancelled": request.is_cancelled(),
                    "started_here": request.we_started()});
                if request.is_passive() {
                    continue;
                }
                match request.state() {
                    VerificationRequestState::Requested {
                        other_device_data, ..
                    }
                    | VerificationRequestState::Ready {
                        other_device_data, ..
                    } => {
                        value["device_id"] = json!(other_device_data.device_id());
                    }
                    _ => {}
                }
                if let Some(verification) = encryption.get_verification(&self.own_user, &id).await {
                    value["done"] = json!(verification.is_done());
                    value["cancelled"] = json!(verification.is_cancelled());
                    match verification {
                        Verification::QrV1(qr) => {
                            value["method"] = json!("qr");
                            value["device_id"] = json!(qr.other_device().device_id());
                            value["scanned"] = json!(qr.has_been_scanned());
                        }
                        Verification::SasV1(sas) => {
                            value["method"] = json!("sas");
                            value["device_id"] = json!(sas.other_device().device_id());
                            value["numbers"] = json!(sas.decimals().map(|(a, b, c)| vec![a, b, c]));
                        }
                        _ => {}
                    }
                }
                requests.push(value);
            }
        }
        let status = encryption.cross_signing_status().await;
        let complete = status.is_some_and(|s| s.is_complete());
        Ok(json!({
            "user_id": self.own_user, "device_id": self.client.device_id(),
            "has_identity": identity.is_some(),
            "identity_verified": identity.is_some_and(|i| i.is_verified()),
            "has_private_identity": complete,
            "backup_enabled": encryption.backups().are_enabled().await,
            "recovery_state": format!("{:?}", encryption.recovery().state()),
            "devices": devices.devices().map(|device| json!({
                "device_id": device.device_id(), "name": device.display_name(),
                "verified": device.is_verified(), "cross_signed": device.is_cross_signed_by_owner(),
                "is_current": Some(device.device_id()) == self.client.device_id()
            })).collect::<Vec<_>>(),
            "requests": requests,
        })
        .to_string())
    }

    async fn own_verification(&self, flow: &str) -> Result<VerificationRequest> {
        self.active()?;
        let request = self
            .client
            .encryption()
            .get_verification_request(&self.own_user, flow)
            .await
            .context("Device verification expired. Start again.")?;
        ensure!(
            request.is_self_verification(),
            "This flow cannot transfer another account's keys"
        );
        ensure!(
            !request.is_cancelled() && !request.is_done(),
            "Device verification is no longer active"
        );
        Ok(request)
    }

    pub async fn request_verification(&self, device: String) -> Result<String> {
        self.active()?;
        let encryption = self.client.encryption();
        encryption
            .request_user_identity(&self.own_user)
            .await
            .map_err(sdk_error)?;
        let device = encryption
            .get_device(&self.own_user, <&DeviceId>::from(device.as_str()))
            .await
            .map_err(sdk_error)?
            .context("Device is no longer available")?;
        ensure!(
            Some(device.device_id()) != self.client.device_id(),
            "Choose another device"
        );
        let request = device
            .request_verification_with_methods(verification_methods())
            .await
            .map_err(sdk_error)?;
        let id = request.flow_id().to_owned();
        self.verification_flows.lock().await.push(id.clone());
        Ok(json!({"id": id}).to_string())
    }

    pub async fn verification_action(&self, flow: String, action: String) -> Result<String> {
        let request = self.own_verification(&flow).await.map_err(sdk_error)?;
        match action.as_str() {
            "accept" => request
                .accept_with_methods(verification_methods())
                .await
                .map_err(sdk_error)?,
            "cancel" => request.cancel().await.map_err(sdk_error)?,
            "sas" => {
                request
                    .start_sas()
                    .await
                    .map_err(sdk_error)?
                    .context("SAS verification is unavailable")?
                    .accept()
                    .await
                    .map_err(sdk_error)?;
            }
            "accept_sas" => {
                self.client
                    .encryption()
                    .get_verification(&self.own_user, &flow)
                    .await
                    .and_then(Verification::sas)
                    .context("SAS verification is not ready")?
                    .accept()
                    .await
                    .map_err(sdk_error)?;
            }
            "confirm_sas" => {
                let sas = self
                    .client
                    .encryption()
                    .get_verification(&self.own_user, &flow)
                    .await
                    .and_then(Verification::sas)
                    .context("SAS verification is not ready")?;
                ensure!(
                    sas.can_be_presented(),
                    "Compare the numbers on both devices first"
                );
                sas.confirm().await.map_err(sdk_error)?;
            }
            "confirm_qr" => {
                let qr = self
                    .client
                    .encryption()
                    .get_verification(&self.own_user, &flow)
                    .await
                    .and_then(Verification::qr)
                    .context("QR verification is not ready")?;
                ensure!(
                    qr.has_been_scanned(),
                    "The other device has not scanned this code"
                );
                qr.confirm().await.map_err(sdk_error)?;
            }
            _ => bail!("Unsupported verification action"),
        }
        Ok("{}".into())
    }

    pub async fn verification_qr(&self, flow: String) -> Result<String> {
        let qr = self
            .own_verification(&flow)
            .await
            .map_err(sdk_error)?
            .generate_qr_code()
            .await
            .map_err(sdk_error)?
            .context("Accept this request on both devices before showing a QR code")?;
        let code = qr.to_qr_code()?;
        let size = code.width();
        let pixels: Vec<bool> = code
            .to_colors()
            .into_iter()
            .map(|c| c.select(true, false))
            .collect();
        Ok(
            json!({"size": size, "pixels": pixels, "device_id": qr.other_device().device_id()})
                .to_string(),
        )
    }

    /// Decode the binary QR payload, not a text URL. The maintained crypto SDK
    /// checks the transaction, account, device keys and shared secret.
    pub async fn scan_verification_image(&self, flow: String, bytes: Vec<u8>) -> Result<String> {
        let request = self.own_verification(&flow).await.map_err(sdk_error)?;
        let payload = decode_qr(&bytes)?;
        let data = QrVerificationData::from_bytes(payload)?;
        request
            .scan_qr_code(data)
            .await
            .map_err(sdk_error)?
            .context("This QR code does not match this verification")?;
        Ok("{}".into())
    }

    /// This creates a new identity only when none exists. An existing identity
    /// must be recovered or verified, so setup cannot silently replace its keys.
    pub async fn setup_recovery(&self, authentication: Option<String>) -> Result<String> {
        self.active()?;
        let encryption = self.client.encryption();
        let existing = encryption
            .request_user_identity(&self.own_user)
            .await
            .map_err(sdk_error)?;
        let own_keys = encryption
            .cross_signing_status()
            .await
            .is_some_and(|s| s.is_complete());
        ensure!(
            existing.is_none() || own_keys,
            "Verify this device or enter your existing recovery key first"
        );
        let auth: Option<AuthData> = authentication
            .map(|v| serde_json::from_str(&v))
            .transpose()?;
        if !own_keys {
            if let Err(error) = encryption.bootstrap_cross_signing(auth).await {
                if let Some(uiaa) = error.as_uiaa_response() {
                    return Ok(json!({"authentication": uiaa}).to_string());
                }
                return Err(sdk_error(error));
            }
        }
        let key = encryption.recovery().enable().await.map_err(sdk_error)?;
        Ok(json!({"recovery_key": key}).to_string())
    }

    pub async fn recover(&self, recovery_key: String) -> Result<String> {
        self.active()?;
        self.client
            .encryption()
            .recovery()
            .recover(&recovery_key)
            .await
            .map_err(sdk_error)?;
        self.security().await
    }
}

fn decode_qr(bytes: &[u8]) -> Result<Vec<u8>> {
    ensure!(bytes.len() <= 16 * 1024 * 1024, "QR image is too large");
    let mut reader = image::ImageReader::new(Cursor::new(bytes)).with_guessed_format()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode()?.into_luma8();
    let mut detector = quircs::Quirc::default();
    for code in detector.identify(
        image.width() as usize,
        image.height() as usize,
        image.as_raw(),
    ) {
        let Ok(code) = code else { continue };
        if let Ok(decoded) = code.decode() {
            if decoded.payload.starts_with(b"MATRIX") {
                return Ok(decoded.payload);
            }
        }
    }
    bail!("No Matrix verification QR code was found in this image")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binary_code() -> Vec<u8> {
        let flow = b"river-test-flow";
        let mut data = b"MATRIX\x02\x01".to_vec();
        data.extend_from_slice(&(flow.len() as u16).to_be_bytes());
        data.extend_from_slice(flow);
        // Compressed Ed25519 base point, followed by a deliberately binary
        // shared secret: scanners must preserve zero and non-UTF8 bytes.
        for _ in 0..2 {
            data.push(0x58);
            data.extend_from_slice(&[0x66; 31]);
        }
        data.extend_from_slice(&[0, 0x80, 0xff, 0x42].repeat(8));
        data
    }

    #[test]
    fn binary_matrix_qr_survives_display_and_image_scan() {
        let payload = binary_code();
        let qr = QrVerificationData::from_bytes(&payload)
            .unwrap()
            .to_qr_code()
            .unwrap();
        let width = qr.width();
        let scale = 8;
        let mut image = image::GrayImage::from_pixel(
            ((width + 8) * scale) as u32,
            ((width + 8) * scale) as u32,
            image::Luma([255]),
        );
        for (index, color) in qr.to_colors().iter().enumerate() {
            if color.select(true, false) {
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
        image.write_to(&mut png, image::ImageFormat::Png).unwrap();
        assert_eq!(decode_qr(png.get_ref()).unwrap(), payload);
    }

    #[test]
    fn invalid_images_and_malformed_matrix_payloads_are_rejected() {
        assert!(decode_qr(b"https://matrix.to/#/@someone:example.org").is_err());
        assert!(decode_qr(&vec![0; 16 * 1024 * 1024 + 1]).is_err());
        let mut png = Cursor::new(Vec::new());
        image::GrayImage::from_pixel(32, 32, image::Luma([255]))
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        assert!(decode_qr(png.get_ref()).is_err());
        assert!(QrVerificationData::from_bytes(b"MATRIX\x02\x01\0\0").is_err());
        let mut payload = binary_code();
        payload[6] = 0xff;
        assert!(QrVerificationData::from_bytes(payload).is_err());
    }
}
