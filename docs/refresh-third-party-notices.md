# Third-party components

- SideSign: https://github.com/SideStore/SideSign at
  `752d1ef602aa792a432ffa1e71646dc1ecf7363c`. Consumed as an upstream Swift
  package; its copyright notices and transitive packages remain intact. The
  checked revision has no repository-level LICENSE file; do not infer a license
  grant for distribution from repository visibility.
- DeviceGateway and MinimuxerCommon: source subset from
  https://github.com/SideStore/minimuxer at
  `12be70dc2627307a16bfd2dc7a009080d5bec909`, AGPL-3.0. The full license is
  `Vendor/DeviceGateway/LICENSE`. Changes are recorded in UPSTREAM.md.
- IDevice: pinned SideStore idevice release `v0.1.68-ss-3e55c84`, downloaded and
  checksum-verified by `scripts/bootstrap_code_refresh.py`. The wrapper changes
  framework packaging, not the compiled archive contents. Source and upstream
  licensing: https://github.com/SideStore/idevice.
- SideSign's dependencies include CodeSignKit, GSACryptoKit, AnisetteKit,
  libdeflate, swift-crypto, swift-asn1, OpenSSL and Unicorn. SwiftPM retains the
  upstream notices and the exact resolved revisions. Those licenses continue
  to apply independently; this file does not relicense any component.
