# Archived order artefacts

PQ-signed orders that were anchored, attested and executed on Monad mainnet and
have since been replaced. They are kept because **the proof transactions they
correspond to are still on chain, and recompute against these files and nothing
else.**

| File | orderHash | Superseded because |
|---|---|---|
| `signed_orders_0xaee5fdf0.json` | `0xaee5fdf0…3ee9` | executed against `UniswapRoutingVault` `0xDaEa22D6…5144`, retired 2026-08-25 |
| `mainnet_supply_order_0x051a10f5.json` | `0x051a10f5…348c` | executed against `MorphoSupplyAdapter` `0xE3de9217…Ffa6`, retired 2026-08-25 |
| `signed_orders_0x8fdc0057.json` | `0x8fdc0057…d3de` | carried `deadline 1788298709` (2026-09-01). The vault checks `DeadlinePassed` BEFORE the commitment check, so on expiry both arms of the tamper-evidence replay would have returned the same revert and the demonstration would have proved nothing. Replaced 2026-08-30 by an order valid to 2031-12-31 |

The 2026-08-11 pair could not be replayed against the executors that replaced
them: `exec_commitment` hashes the executor ADDRESS along with the route
parameters, so an order naming a retired vault produces a commitment the new
vault will never recompute — it reverts `ExecCommitmentMismatch`. That is the
binding working as designed, and it is why the 2026-08-25 migration needed
freshly signed orders and freshly generated Groth16 proofs rather than a replay.

`signed_orders_0x8fdc0057.json` names the CURRENT vault and is still perfectly
valid cryptographically. It was replaced for a reason that has nothing to do
with the contracts: a signed order carries an expiry, and a demonstration built
on one inherits it.

The live equivalents are at the canonical paths `outputs/signed_orders.json`
and `outputs/mainnet_supply_order.json`, and describe the current contracts.
