//! Exercise River's actual SDK polling against a disposable sliding-sync peer.
use super::connection::MatrixCore;
use anyhow::{Context, Result, ensure};
use matrix_sdk::{Client, authentication::matrix::MatrixSession};
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
    requests: Arc<Mutex<Vec<Value>>>,
    stop: Arc<AtomicBool>,
    task: Option<thread::JoinHandle<()>>,
}

impl Peer {
    fn start(failures: Vec<Option<&'static str>>) -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        listener.set_nonblocking(true)?;
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (seen, stopped) = (requests.clone(), stop.clone());
        let task = thread::spawn(move || {
            while !stopped.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = serve(stream, &seen, &failures);
                    }
                    Err(_) => thread::sleep(Duration::from_millis(2)),
                }
            }
        });
        Ok(Self {
            address,
            requests,
            stop,
            task: Some(task),
        })
    }

    async fn core(&self) -> Result<MatrixCore> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = Client::builder()
            .homeserver_url(format!("http://{}", self.address))
            .respect_login_well_known(false)
            .build()
            .await?;
        let session: MatrixSession = serde_json::from_value(json!({
            "user_id":"@alice:example.test", "device_id":"RECOVERY", "access_token":"fixture-only"
        }))?;
        client
            .matrix_auth()
            .restore_session(session, Default::default())
            .await?;
        Ok(MatrixCore::from_client(
            client,
            "@alice:example.test".try_into()?,
            uuid::Uuid::new_v4().to_string(),
        ))
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(task) = self.task.take() {
            let _ = task.join();
        }
    }
}

fn serve(
    mut stream: TcpStream,
    requests: &Mutex<Vec<Value>>,
    failures: &[Option<&str>],
) -> Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut bytes = Vec::new();
    let mut part = [0; 8192];
    let header_end = loop {
        let count = stream.read(&mut part)?;
        if count == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&part[..count]);
        if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
            break end + 4;
        }
        ensure!(bytes.len() < 1024 * 1024, "oversized fixture request");
    };
    let header = String::from_utf8_lossy(&bytes[..header_end]).to_string();
    let length = header
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("content-length:")
                .map(|n| n.trim().parse::<usize>().unwrap())
        })
        .unwrap_or(0);
    while bytes.len() < header_end + length {
        let count = stream.read(&mut part)?;
        ensure!(count != 0, "truncated fixture request");
        bytes.extend_from_slice(&part[..count]);
    }
    let path = header.split_whitespace().nth(1).context("request path")?;
    let mut status = 200;
    let body = if path.ends_with("/versions") {
        json!({"versions":["v1.11"], "unstable_features":{"org.matrix.simplified_msc3575":true}})
    } else if path.contains("/sync") {
        let request: Value = serde_json::from_slice(&bytes[header_end..header_end + length])?;
        let mut requests = requests.lock().unwrap();
        let index = requests.len();
        requests.push(json!({"path":path,"body":request}));
        if let Some(Some(code)) = failures.get(index) {
            status = if *code == "M_FORBIDDEN" { 403 } else { 400 };
            json!({"errcode":code,"error":"fixture sync failure"})
        } else {
            let room = if index == 0 { "!existing:example.test" } else { "!new:example.test" };
            json!({"pos":format!("position-{index}"),"lists":{},"rooms":{
                room:{"name":"Conversation", "initial":true, "required_state":[
                    {"type":"m.room.create", "state_key":"", "sender":"@alice:example.test", "event_id":format!("$create-{index}"), "origin_server_ts":1, "content":{"creator":"@alice:example.test","room_version":"10"}},
                    {"type":"m.room.member", "state_key":"@alice:example.test", "sender":"@alice:example.test", "event_id":format!("$join-{index}"), "origin_server_ts":1, "content":{"membership":"join"}}
                ]}
            },"extensions":{}})
        }
    } else if path.ends_with("/keys/upload") {
        json!({"one_time_key_counts":{"signed_curve25519":50}})
    } else if path.ends_with("/keys/query") {
        json!({"device_keys":{},"failures":{}})
    } else {
        json!({})
    }
    .to_string();
    write!(
        stream,
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    Ok(())
}

#[tokio::test]
async fn expired_position_recovers_inside_the_same_sync_and_preserves_device() -> Result<()> {
    let peer = Peer::start(vec![None, Some("M_UNKNOWN_POS"), None])?;
    let core = peer.core().await?;
    let credentials = core.credentials().await?;
    core.sync().await?;
    let recovered: Value = serde_json::from_str(
        &core
            .sync()
            .await
            .context("expired sync should recover without a foreground error")?,
    )?;
    for room_id in ["!existing:example.test", "!new:example.test"] {
        assert!(
            recovered["rooms"]
                .as_array()
                .unwrap()
                .iter()
                .any(|room| room["room_id"] == room_id && room["membership"] == "join")
        );
    }
    core.sync().await?;
    let requests = peer.requests.lock().unwrap().clone();
    assert_eq!(requests.len(), 4);
    assert!(!requests[0]["path"].as_str().unwrap().contains("pos="));
    assert!(
        requests[1]["path"]
            .as_str()
            .unwrap()
            .contains("pos=position-0")
    );
    assert!(!requests[2]["path"].as_str().unwrap().contains("pos="));
    assert!(
        requests[3]["path"]
            .as_str()
            .unwrap()
            .contains("pos=position-2")
    );
    assert_eq!(
        requests[0]["body"]["conn_id"],
        requests[2]["body"]["conn_id"]
    );
    assert!(requests[2]["body"]["lists"]["rooms"].is_object());
    assert_eq!(core.credentials().await?, credentials);
    core.close(false).await?;
    Ok(())
}

#[tokio::test]
async fn repeated_expiration_is_bounded_and_the_next_call_can_recover() -> Result<()> {
    let peer = Peer::start(vec![
        None,
        Some("M_UNKNOWN_POS"),
        Some("M_UNKNOWN_POS"),
        None,
    ])?;
    let core = peer.core().await?;
    core.sync().await?;
    let failed = tokio::time::timeout(Duration::from_secs(5), core.sync()).await?;
    assert!(failed.is_err());
    assert_eq!(peer.requests.lock().unwrap().len(), 3);
    core.sync().await?;
    assert!(
        !peer.requests.lock().unwrap()[3]["path"]
            .as_str()
            .unwrap()
            .contains("pos=")
    );
    core.close(false).await?;
    Ok(())
}

#[tokio::test]
async fn permission_failure_is_not_retried_as_an_expired_position() -> Result<()> {
    let peer = Peer::start(vec![Some("M_FORBIDDEN")])?;
    let core = peer.core().await?;
    assert!(core.sync().await.is_err());
    assert_eq!(peer.requests.lock().unwrap().len(), 1);
    core.close(false).await?;
    Ok(())
}
