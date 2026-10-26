use crate::core::connection::MatrixCore;
use anyhow::{Context, Result};
use flutter_rust_bridge::frb;

#[cfg(not(target_family = "wasm"))]
type SharedCore = std::sync::Arc<MatrixCore>;
#[cfg(target_family = "wasm")]
type SharedCore = std::rc::Rc<MatrixCore>;

#[cfg(not(target_family = "wasm"))]
fn with_registry<T>(f: impl FnOnce(&mut std::collections::HashMap<String, SharedCore>) -> T) -> T {
    static CLIENTS: std::sync::LazyLock<
        std::sync::Mutex<std::collections::HashMap<String, SharedCore>>,
    > = std::sync::LazyLock::new(Default::default);
    f(&mut CLIENTS.lock().unwrap_or_else(|e| e.into_inner()))
}
#[cfg(target_family = "wasm")]
fn with_registry<T>(f: impl FnOnce(&mut std::collections::HashMap<String, SharedCore>) -> T) -> T {
    thread_local! {
        static CLIENTS: std::cell::RefCell<std::collections::HashMap<String, SharedCore>> = Default::default();
    }
    CLIENTS.with(|clients| f(&mut clients.borrow_mut()))
}

/// Only an unguessable handle crosses the FFI boundary. On the web the actual
/// IndexedDB/crypto client stays on the browser event loop, with no Send shim.
/// All exported operations are async; none dispatch into blocking web workers.
#[frb(opaque)]
pub struct MatrixConnection {
    id: String,
}

impl MatrixConnection {
    fn core(&self) -> Result<SharedCore> {
        with_registry(|clients| clients.get(&self.id).cloned()).context("Matrix session is closed")
    }
    pub async fn open(
        homeserver: String,
        expected_user: String,
        store: String,
        store_key: String,
        session: Option<String>,
    ) -> Result<Self> {
        let core = MatrixCore::open(homeserver, expected_user, store, store_key, session).await?;
        let id = uuid::Uuid::new_v4().to_string();
        with_registry(|clients| clients.insert(id.clone(), SharedCore::new(core)));
        Ok(Self { id })
    }
    pub async fn login(&self, login_token: String) -> Result<String> {
        self.core()?.login(login_token).await
    }
    pub async fn credentials(&self) -> Result<String> {
        self.core()?.credentials().await
    }
    pub async fn sync(&self) -> Result<String> {
        self.core()?.sync().await
    }
    pub async fn rooms(&self) -> Result<String> {
        self.core()?.rooms().await
    }
    pub async fn history(&self, room: String, cursor: Option<String>) -> Result<String> {
        self.core()?.history(room, cursor).await
    }
    pub async fn thread(
        &self,
        room: String,
        event: String,
        cursor: Option<String>,
    ) -> Result<String> {
        self.core()?.thread(room, event, cursor).await
    }
    pub async fn members(&self, room: String) -> Result<String> {
        self.core()?.members(room).await
    }
    pub async fn send(
        &self,
        room: String,
        event_type: String,
        content: String,
        transaction: String,
    ) -> Result<String> {
        self.core()?
            .send(room, event_type, content, transaction)
            .await
    }
    pub async fn action(&self, payload: String) -> Result<String> {
        self.core()?.action(payload).await
    }
    pub async fn send_attachment(
        &self,
        room: String,
        name: String,
        content_type: String,
        bytes: Vec<u8>,
        transaction: String,
    ) -> Result<String> {
        self.core()?
            .send_attachment(room, name, content_type, bytes, transaction)
            .await
    }
    pub async fn download_attachment(&self, content: String) -> Result<Vec<u8>> {
        self.core()?.download_attachment(content).await
    }
    pub async fn security(&self) -> Result<String> {
        self.core()?.security().await
    }
    pub async fn setup_recovery(&self, authentication: Option<String>) -> Result<String> {
        self.core()?.setup_recovery(authentication).await
    }
    pub async fn recover(&self, recovery_key: String) -> Result<String> {
        self.core()?.recover(recovery_key).await
    }
    pub async fn request_verification(&self, device: String) -> Result<String> {
        self.core()?.request_verification(device).await
    }
    pub async fn verification_action(&self, flow: String, action: String) -> Result<String> {
        self.core()?.verification_action(flow, action).await
    }
    pub async fn verification_qr(&self, flow: String) -> Result<String> {
        self.core()?.verification_qr(flow).await
    }
    pub async fn scan_verification_image(&self, flow: String, bytes: Vec<u8>) -> Result<String> {
        self.core()?.scan_verification_image(flow, bytes).await
    }
    pub async fn close(&self, logout: bool) -> Result<()> {
        let core = with_registry(|clients| clients.remove(&self.id));
        if let Some(core) = core {
            core.close(logout).await?;
        }
        Ok(())
    }
}

impl Drop for MatrixConnection {
    fn drop(&mut self) {
        with_registry(|clients| clients.remove(&self.id));
    }
}
