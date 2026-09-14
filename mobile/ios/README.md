# mobile/ios/ (not started)

Foreground-only node: no background daemon (iOS background execution is too restricted for an always-on P2P socket). On app open/foreground, broadcasts presence, reconciles history with any reachable peer, and syncs the local clipboard. See `../../docs/architecture.md`.
