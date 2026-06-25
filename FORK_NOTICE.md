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

## TODO before shipping

- [ ] Rename the product/command surface away from "Mole"/"mo" (upstream added a trademark
      policy — do not ship under the upstream name). Target: `burrow-engine`.
- [ ] Clean-room any desired post-V1.42 features (Windows `--json`, new cache paths).
- [ ] Wire as the cleaning engine behind `burrow-cli`; repoint Burrow GUI installer here.
