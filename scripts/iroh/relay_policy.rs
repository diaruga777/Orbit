use iroh::endpoint::presets;
use iroh::{Endpoint, RelayMode};
use iroh_relay::tls::CaTlsConfig;
use std::time::Duration;
use tokio::time::timeout;

const ALPN: &[u8] = b"luna-orbit/relay-policy-test";

#[tokio::test]
async fn handshakes_succeed_without_forwarding_streams_or_datagrams_on_relay() {
    let (relay_map, _, _relay) = iroh::test_utils::run_relay_server().await.unwrap();
    let bind = || async {
        Endpoint::builder(presets::Minimal)
            .alpns(vec![ALPN.to_vec()])
            .ca_tls_config(CaTlsConfig::insecure_skip_verify())
            .relay_mode(RelayMode::Custom(relay_map.clone()))
            .clear_ip_transports()
            .bind()
            .await
            .unwrap()
    };
    let (server, client) = tokio::join!(bind(), bind());
    timeout(Duration::from_secs(10), server.online()).await.unwrap();
    let server_addr = server.addr();
    let (accepted, connected) = timeout(Duration::from_secs(10), async {
        tokio::join!(async { server.accept().await.unwrap().await.unwrap() }, async {
            client.connect(server_addr, ALPN).await.unwrap()
        })
    }).await.unwrap();
    assert!(connected.paths().iter().any(|path| path.is_relay()));
    assert!(!connected.paths().iter().any(|path| path.is_ip()));

    let mut client_send = connected.open_uni().await.unwrap();
    let mut server_send = accepted.open_uni().await.unwrap();
    client_send.write_all(b"phone file data").await.unwrap();
    server_send.write_all(b"mac file data").await.unwrap();
    connected.send_datagram(b"phone datagram".to_vec().into()).unwrap();
    accepted.send_datagram(b"mac datagram".to_vec().into()).unwrap();
    let window = Duration::from_secs(1);
    let (at_server, at_client, server_datagram, client_datagram) = tokio::join!(
        timeout(window, accepted.accept_uni()), timeout(window, connected.accept_uni()),
        timeout(window, accepted.read_datagram()), timeout(window, connected.read_datagram())
    );
    assert!(at_server.is_err() && at_client.is_err());
    assert!(server_datagram.is_err() && client_datagram.is_err());
    assert!(accepted.close_reason().is_none() && connected.close_reason().is_none());
    tokio::join!(server.close(), client.close());
}
