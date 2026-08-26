# Archived order artefacts — the 2026-08-11 mainnet run

These are the PQ-signed orders whose SHA-256 hashes were anchored, attested and
executed on Monad mainnet on 2026-08-11, against the executors live at that
time. They are kept because **the six proof transactions cited in SUBMISSION.md
recompute against these files and nothing else.**

| File | orderHash | Executed against |
|---|---|---|
| `signed_orders_0xaee5fdf0.json` | `0xaee5fdf0…3ee9` | `UniswapRoutingVault` `0xDaEa22D6…5144` (retired 2026-08-25) |
| `mainnet_supply_order_0x051a10f5.json` | `0x051a10f5…348c` | `MorphoSupplyAdapter` `0xE3de9217…Ffa6` (retired 2026-08-25) |

They cannot be replayed against the current executors. `exec_commitment` hashes
the executor ADDRESS along with the route parameters, so an order naming the
retired vault produces a commitment the new vault will never recompute — it
reverts `ExecCommitmentMismatch`. That is the binding working as designed, and
it is why the 2026-08-25 migration needed freshly signed orders and freshly
generated Groth16 proofs rather than a replay.

The live equivalents are at the canonical paths `outputs/signed_orders.json`
and `outputs/mainnet_supply_order.json`, and describe the current contracts.
