//! A real SDK token rotation must wake a blocked sync, not wait for its HTTP
//! response. All traffic is confined to this disposable loopback HTTP peer.
use super::connection::MatrixCore;
use anyhow::{Context, Result};
use matrix_sdk::Client;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

struct Peer {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    sync_seen: Arc<AtomicBool>,
    release_sync: Arc<(Mutex<bool>, Condvar)>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Peer {
    fn start() -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let sync_seen = Arc::new(AtomicBool::new(false));
        let release_sync = Arc::new((Mutex::new(false), Condvar::new()));
        let (stopped, seen, gate) = (stop.clone(), sync_seen.clone(), release_sync.clone());
        let task = thread::spawn(move || {
            let mut requests = Vec::new();
            while !stopped.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let (seen, gate) = (seen.clone(), gate.clone());
                        requests.push(thread::spawn(move || {
                            let _ = serve(stream, seen, gate);
                        }));
                    }
                    Err(_) => thread::sleep(Duration::from_millis(2)),
                }
            }
            for task in requests {
                let _ = task.join();
            }
        });
        Ok(Self {
            address,
            stop,
            sync_seen,
            release_sync,
            thread: Some(task),
        })
    }
    fn release(&self) {
        *self.release_sync.0.lock().unwrap() = true;
        self.release_sync.1.notify_all();
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.release();
        if let Some(task) = self.thread.take() {
            let _ = task.join();
        }
    }
}

fn serve(
    mut stream: TcpStream,
    seen: Arc<AtomicBool>,
    gate: Arc<(Mutex<bool>, Condvar)>,
) -> Result<()> {
    // Accepted sockets can inherit the listener's nonblocking mode on Windows.
    // This fixture serves each connection on its own blocking thread.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut bytes = Vec::new();
    let mut part = [0u8; 8192];
    let header_end = loop {
        let count = stream.read(&mut part)?;
        if count == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&part[..count]);
        if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
            break end + 4;
        }
        anyhow::ensure!(bytes.len() < 1024 * 1024, "oversized fixture request");
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
        anyhow::ensure!(count != 0, "truncated fixture request");
        bytes.extend_from_slice(&part[..count]);
    }
    let path = header
        .split_whitespace()
        .nth(1)
        .context("request path")?
        .split('?')
        .next()
        .unwrap();
    let body = if path.ends_with("/versions") {
        json!({"versions":["v1.11"],"unstable_features":{}})
    } else if path.ends_with("/login") {
        json!({"user_id":"@alice:example.test","device_id":"CREDENTIALS","access_token":"original-access","refresh_token":"original-refresh","expires_in_ms":3600000})
    } else if path.ends_with("/refresh") {
        let request: Value = serde_json::from_slice(&bytes[header_end..header_end+length])?;
        anyhow::ensure!(request["refresh_token"] == "original-refresh", "wrong refresh token");
        json!({"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in_ms":3600000})
    } else if path.ends_with("/sync") {
        seen.store(true, Ordering::SeqCst);
        let mut released = gate.0.lock().unwrap();
        while !*released { released = gate.1.wait(released).unwrap(); }
        json!({"next_batch":"next","rooms":{},"device_one_time_keys_count":{"signed_curve25519":50}})
    } else if path.ends_with("/keys/upload") {
        json!({"one_time_key_counts":{"signed_curve25519":50}})
    } else if path.ends_with("/keys/query") {
        json!({"device_keys":{},"failures":{}})
    } else {
        json!({})
    }.to_string();
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )?;
    Ok(())
}

#[tokio::test]
async fn sdk_refresh_wakes_sync_before_the_http_poll_finishes() -> Result<()> {
    let peer = Peer::start()?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = Client::builder()
        .homeserver_url(format!("http://{}", peer.address))
        .respect_login_well_known(false)
        .handle_refresh_tokens()
        .build()
        .await?;
    client
        .matrix_auth()
        .login_username("alice", "fixture-password")
        .device_id("CREDENTIALS")
        .request_refresh_token()
        .send()
        .await?;
    let core = Arc::new(MatrixCore::from_client(
        client.clone(),
        client.user_id().unwrap().to_owned(),
        uuid::Uuid::new_v4().to_string(),
    ));
    let polling = core.clone();
    let task = tokio::spawn(async move { polling.sync().await });
    tokio::time::timeout(Duration::from_secs(5), async {
        while !peer.sync_seen.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .context("SDK never started its sync request")?;
    client.matrix_auth().refresh_access_token().await?;
    let snapshot = tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .context("token persistence was blocked behind the HTTP sync")???;
    let snapshot: Value = serde_json::from_str(&snapshot)?;
    assert_eq!(snapshot["credentials_changed"], true);
    assert!(
        !*peer.release_sync.0.lock().unwrap(),
        "HTTP poll must still be blocked"
    );
    let session: Value = serde_json::from_str(&core.credentials().await?)?;
    assert_eq!(session["refresh_token"], "rotated-refresh");
    peer.release();
    core.close(false).await?;
    Ok(())
}
