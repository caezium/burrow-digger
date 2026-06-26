# burrow-engine — fork provenance

`burrow-engine` is a fork of [tw93/Mole](https://github.com/tw93/Mole) taken at its
**last MIT-licensed commit**, immediately before the project relicensed to GPL-3.0.

| | |
|---|---|
| Upstream | github.com/tw93/Mole |
| Fork commit | `9daf936ea5fd1a0648579434c76000cd9cfa1253` |
| Upstream version | V1.42.0 (2026-06-08) — last MIT release |
| LICENSE at fork | MIT © 2025 tw93 (verified) |
| Reason | Upstream relicensed MIT → AGPL-3.0 → GPL-3.0 on 2026-06-11 and added a trademark policy. This snapshot preserves the permissively-licensed code for downstream commercial use. |

## License

This snapshot is under the **MIT License** (see `LICENSE`, © 2025 tw93). MIT permits use,
modification, and sublicensing provided the original copyright + permission notice are
preserved — they are. Modifications in this fork are © 2026 caezium under the same MIT
terms unless a file states otherwise.

## Do not pull from upstream

Every commit after `9daf936` is GPL-3.0 and incompatible with downstream commercial/closed
use. There is intentionally **no upstream git remote**. New work is authored here or
clean-roomed — never copied from GPL upstream.

## Clean-room additions (post-V1.42 features reimplemented, NOT copied from GPL upstream)

- **`status --watch` (NDJSON streaming)** — 2026-06-26. Contract learned from mo's V1.44
  *release notes* ("newline-delimited JSON status streaming"), implemented fresh in
  `cmd/status/main.go` (`runWatchMode`) around the engine's existing V1.42 collector. No mo
  V1.43+ (GPL) source was read or copied. Backward-compatible: one-shot `status --json` is
  unchanged; `--watch` adds a loop emitting one compact JSON object per line until interrupted.

## TODO before shipping

- [x] Rename product/command surface away from "Mole"/"mo" (identity string + Go module done).
- [ ] Clean-room remaining desired post-V1.42 features as needed (new cache paths, etc.).
- [ ] Wire as the cleaning engine behind `burrow-cli`; repoint Burrow GUI installer here.
