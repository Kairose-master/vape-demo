# Source provenance

- Integrated native L1 + Apple + Besu source: `299dbfd3` (`unified-apple-ledger`).
- Portable baseline reused: `3a622b977255bd56739a7898431ad1b74fc7a347`.

- Presentation/native Apple base: `fac6bc302b1b68213d76438a44231346b2016b95`.
- Apple inference implementation base: `b48b3c1081142e4627c70f5b564f64cded67864a`.
- Optional isolated secure Cloud UI source: `3594e5e1` (only `native/ReadyCloud/` source copied; no runtime or keys).
- Shared native minimum macOS 13 build settings inherited from native compatibility work. Real Apple inference remains separately gated by macOS 26 and runtime availability.

No previous machine evidence, absolute home paths, credentials, config bundles, chain state, installed tools, screenshots or binaries are distributed. This package is a curated source export; it does not include Git metadata or unrelated historical documentation. This export contains reviewed source only and starts a new Git history. Verify the destination repository is private before publishing.

- Release portability fix: shell-quote each JVM property in Besu options; reproduced with a clean extraction path containing spaces, without weakening chain/evidence checks.

- Source-only GitHub release base: `b12b6120926eb828f2daab5a90a37b3486810b53`; no ancestral Git objects exported.
