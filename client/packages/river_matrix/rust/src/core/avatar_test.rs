//! Test real SDK room/member profiles and authenticated media against a private
//! loopback peer. No production account, public media relay or credentials.
use super::connection::MatrixCore;
use anyhow::{Context, Result, ensure};
use matrix_sdk::{
    Client,
    authentication::matrix::MatrixSession,
    config::{RequestConfig, SyncSettings},
};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

struct Peer {
    address: SocketAddr,
    requests: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Peer {
    fn start() -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        listener.set_nonblocking(true)?;
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (seen, stopped) = (requests.clone(), stop.clone());
        let thread = thread::spawn(move || {
            while !stopped.load(Ordering::SeqCst) {
                if let Ok((stream, _)) = listener.accept() {
                    let _ = serve(stream, &seen);
                } else {
                    thread::sleep(Duration::from_millis(2));
                }
            }
        });
        Ok(Self {
            address,
            requests,
            stop,
            thread: Some(thread),
        })
    }
    async fn core(&self) -> Result<MatrixCore> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = Client::builder()
            .homeserver_url(format!("http://{}", self.address))
            .respect_login_well_known(false)
            .request_config(RequestConfig::default().retry_limit(0))
            .build()
            .await?;
        let session: MatrixSession = serde_json::from_value(
            json!({"user_id":"@alice:test", "device_id":"AVATARS", "access_token":"fixture-only"}),
        )?;
        client
            .matrix_auth()
            .restore_session(session, Default::default())
            .await?;
        Ok(MatrixCore::from_client(
            client,
            "@alice:test".try_into()?,
            uuid::Uuid::new_v4().to_string(),
        ))
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(task) = self.thread.take() {
            let _ = task.join();
        }
    }
}
fn member(user: &str, avatar: Option<&str>) -> Value {
    json!({"type":"m.room.member", "state_key":user, "sender":user, "event_id":format!("$member-{user}"), "origin_server_ts":1, "content":{"membership":"join", "displayname":user, "avatar_url":avatar}})
}
fn room(space: bool) -> Value {
    let mut events = vec![
        json!({"type":"m.room.create", "state_key":"", "sender":"@alice:test", "event_id":format!("$create-{space}"), "origin_server_ts":1, "content":{"creator":"@alice:test", "room_version":"10", "type":if space {Some("m.space")} else {None}}}),
        member("@alice:test", None),
        member("@bob:test", Some("mxc://remote.test/contact")),
    ];
    if space {
        events.push(json!({"type":"m.room.avatar", "state_key":"", "sender":"@alice:test", "event_id":"$space-avatar", "origin_server_ts":1, "content":{"url":"mxc://remote.test/space"}}));
    }
    json!({"state":{"events":events}, "timeline":{"events":[], "limited":false}, "ephemeral":{"events":[]}, "account_data":{"events":[]}, "summary":{"m.heroes":["@bob:test"], "m.joined_member_count":2, "m.invited_member_count":0}})
}
fn serve(mut stream: TcpStream, requests: &Mutex<Vec<String>>) -> Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    let mut bytes = Vec::new();
    let mut part = [0; 8192];
    loop {
        let count = stream.read(&mut part)?;
        if count == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&part[..count]);
        if bytes.windows(4).any(|v| v == b"\r\n\r\n") {
            break;
        }
        ensure!(bytes.len() < 1024 * 1024, "oversized fixture request");
    }
    let header = String::from_utf8_lossy(&bytes);
    let path = header.split_whitespace().nth(1).context("request path")?;
    requests.lock().unwrap().push(header.to_string());
    let mut status = 200;
    let mut content_type = "application/json";
    let body = if path.ends_with("/versions") {
        json!({"versions":["v1.11"]}).to_string().into_bytes()
    } else if path.contains("/sync") {
        json!({"next_batch":"avatars", "rooms":{"join":{"!direct:test":room(false), "!space:test":room(true)}}, "account_data":{"events":[{"type":"m.direct", "content":{"@bob:test":["!direct:test"]}}]}, "to_device":{"events":[]}}).to_string().into_bytes()
    } else if path.contains("/members") {
        json!({"chunk":[member("@alice:test", None), member("@bob:test", Some("mxc://remote.test/contact"))]}).to_string().into_bytes()
    } else if path.contains("/thumbnail/") || path.contains("/download/") {
        ensure!(
            header
                .to_ascii_lowercase()
                .contains("authorization: bearer fixture-only"),
            "media request must authenticate"
        );
        if path.contains("/missing") || (path.contains("/thumbnail/") && path.contains("/space")) {
            status = 404;
            json!({"errcode":"M_NOT_FOUND", "error":"No thumbnail"})
                .to_string()
                .into_bytes()
        } else {
            content_type = "image/png";
            b"avatar-bytes".to_vec()
        }
    } else if path.ends_with("/keys/upload") {
        json!({"one_time_key_counts":{"signed_curve25519":50}})
            .to_string()
            .into_bytes()
    } else {
        b"{}".to_vec()
    };
    write!(
        stream,
        "HTTP/1.1 {status} OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(&body)?;
    Ok(())
}
async fn picture(core: &MatrixCore, url: &str) -> Result<Vec<u8>> {
    let response: Value = serde_json::from_str(
        &core
            .action(json!({"action":"avatar", "url":url}).to_string())
            .await?,
    )?;
    let data: matrix_sdk::ruma::serde::Base64 =
        matrix_sdk::ruma::serde::Base64::parse(response["data"].as_str().context("avatar data")?)?;
    Ok(data.into_inner())
}

#[tokio::test]
async fn matrix_avatars_use_profiles_authenticated_media_and_the_sdk_cache() -> Result<()> {
    let peer = Peer::start()?;
    let core = peer.core().await?;
    core.client
        .sync_once(SyncSettings::default().timeout(Duration::from_millis(1)))
        .await?;
    let snapshot: Value = serde_json::from_str(&core.rooms().await?)?;
    let rooms = snapshot["rooms"].as_array().unwrap();
    let direct = rooms
        .iter()
        .find(|r| r["room_id"] == "!direct:test")
        .context("direct room")?;
    let space = rooms
        .iter()
        .find(|r| r["room_id"] == "!space:test")
        .context("space")?;
    assert_eq!(direct["avatar_url"], "mxc://remote.test/contact");
    assert_eq!(space["avatar_url"], "mxc://remote.test/space");
    let roster: Value = serde_json::from_str(&core.members("!direct:test".into()).await?)?;
    assert!(
        roster["members"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["user_id"] == "@bob:test" && m["avatar_url"] == "mxc://remote.test/contact")
    );
    assert_eq!(
        picture(&core, "mxc://remote.test/contact").await?,
        b"avatar-bytes"
    );
    assert_eq!(
        picture(&core, "mxc://remote.test/contact").await?,
        b"avatar-bytes"
    );
    assert_eq!(
        picture(&core, "mxc://remote.test/space").await?,
        b"avatar-bytes"
    );
    assert!(picture(&core, "mxc://remote.test/missing").await.is_err());
    let requests = peer.requests.lock().unwrap();
    let thumbnails = requests
        .iter()
        .filter(|r| r.contains("/thumbnail/remote.test/contact"))
        .collect::<Vec<_>>();
    assert_eq!(
        thumbnails.len(),
        1,
        "SDK must cache the authenticated thumbnail"
    );
    assert!(thumbnails[0].contains("width=96") && thumbnails[0].contains("height=96"));
    assert!(
        requests
            .iter()
            .any(|r| r.contains("/download/remote.test/space")),
        "original avatar fallback"
    );
    Ok(())
}
