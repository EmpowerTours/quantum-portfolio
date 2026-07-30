# Mainnet deploy runbook — Monad (chainId 143)

Deploys the three core contracts. **The ZK attestation leg is deliberately not
included** — its Groth16 fixture is stale (see `zk-mldsa/README.md`), and
nothing in the core pipeline references `MLDSAAttestation`, so it can be added
later without touching anything deployed here.

Pre-flight verified 2026-07-30 at block 91684549:

| | |
|---|---|
| Deployer | `0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1` |
| Balance | 0.989160532 MON |
| Nonce | 394 |
| Gas price | 102 gwei (forge pads its estimate to ~202) |
| Tests | 142 Solidity, 85 Python, 0 skipped |
| External env | SwapRouter02 / WMON / USDC / Morpho Blue / V3Factory all unchanged; USDC not paused |

Cost: **~2,308,043 gas ≈ 0.235 MON** at 102 gwei, **≈0.466 MON** at forge's
padded 202 gwei. Either way it fits, and the deployer additionally holds
501 WMON unwrappable 1:1 if you want headroom.

Predicted addresses (CREATE from nonce 394 — **verify each one matches**):

```
nonce 394  AuditAnchorV2        0x8422b555DCE11913A4657C2f47C839637FC71ffd
nonce 395  UniswapRoutingVault  0x06F233062eE23590e5CC873df511024f3d981e56
nonce 396  MorphoSupplyAdapter  0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E
```

If a nonce is consumed by anything else in between, the later addresses shift.
That is harmless — the vault and adapter take the anchor's address as an
argument, so just use whatever step 1 actually printed.

---

## Step 0 — wallet

**Preferred: the encrypted keystore.** There is already one named `deployer`
(`~/.foundry/keystores/deployer`, aes-128-ctr + scrypt). Using it keeps the key
out of the process environment entirely — forge prompts for the passphrase and
holds the key only in memory. Confirm it is the right account first:

```bash
cast wallet address --account deployer
# must print 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

Then add these to every deploy command below:

```
--account deployer --sender 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

**Fallback: an environment variable**, if the keystore holds a different
account. The key must never be written into a file in this repo.

```bash
read -rs DEPLOYER_PRIVATE_KEY && export DEPLOYER_PRIVATE_KEY
cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY"
# must print 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

The scripts accept either: they read `DEPLOYER_PRIVATE_KEY` when it is set and
otherwise fall through to whatever wallet the CLI supplied. With neither, forge
refuses rather than falling back to its default sender — verified on a fork.

## Step 1 — AuditAnchorV2

The vault and adapter both refuse to deploy against anything that is not a V2
anchor, so this must land first.

```bash
cd contracts
forge script script/DeployAuditAnchorV2.s.sol \
  --rpc-url https://rpc.monad.xyz --broadcast \
  --account deployer --sender 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

Record the printed address, then confirm the capability the executors probe for:

```bash
export AUDIT_ANCHOR_ADDR=<address from above>
cast call "$AUDIT_ANCHOR_ADDR" \
  "execCommitmentOf(address,bytes32)(bytes32)" \
  0x0000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --rpc-url https://rpc.monad.xyz
# must return 0x0000...0000 (32 bytes). If it REVERTS you deployed V1 — stop.
```

## Step 2 — UniswapRoutingVault

```bash
export APPROVED_TOKENS=0x754704Bc059F8C67012fEd69BC8A327a5aafb603   # USDC
export APPROVED_FEE_TIERS=3000                                      # the only liquid WMON/USDC pool

forge script script/DeployUniswapRoutingVault.s.sol \
  --rpc-url https://rpc.monad.xyz --broadcast \
  --account deployer --sender 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

Only tier 3000 is allowlisted on purpose: the sibling pools hold 0.19 and 2.93
USDC against ~447k in the 0.3% pool, so routing through them is a near-total
loss (audit H-3).

## Step 3 — MorphoSupplyAdapter

```bash
export APPROVED_MARKETS=0xe35c5abc6418b6319b014e07aa3c86163a870a957284128f03cf7a9e414f8899

forge script script/DeployMorphoSupplyAdapter.s.sol \
  --rpc-url https://rpc.monad.xyz --broadcast \
  --account deployer --sender 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1
```

The script resolves that market id against Morpho itself and requires its loan
token to be in `APPROVED_TOKENS`, so a typo fails closed rather than deploying
a permanently unusable adapter.

## Step 4 — post-deploy verification

```bash
cast call <vault>   "ANCHOR()(address)"  --rpc-url https://rpc.monad.xyz
cast call <adapter> "ANCHOR()(address)"  --rpc-url https://rpc.monad.xyz
# both must equal the step-1 anchor address
```

Then update `.env` / deployment notes with the three addresses, and verify on
Monadscan.

---

## What is deliberately NOT in this runbook

* **`MLDSAAttestation`** — blocked on regenerating the Groth16 proof on a
  ≥32 GB box. `zk-mldsa/contracts/script/DeployMLDSAAttestation.s.sol` will
  refuse a stale fixture, so it is safe to run once the proof exists.
* **Retiring the old contracts** — all four hold zero of every asset and the
  deployer has zero allowance to them, so there is nothing to migrate. Note
  the audit could not prove no *third party* holds a stale approval to the old
  adapter (Monad's RPC caps `eth_getLogs` at 100 blocks); risk assessed as very
  low but asserted, not proven.
* **Anything that spends the 501 WMON.** Leave it wrapped unless you need it.

## Operational invariant this deployment assumes

`AuditAnchorV2` treats the commitment as opaque bytes and cannot validate the
deadline sealed inside it. The deadline check lives in
`src/monad_tx.py:validate_route_execution`, which means **all anchoring must go
through the builder**. Anchoring by hand with `cast send` bypasses it and can
burn a sequence number on a route that can no longer execute.
