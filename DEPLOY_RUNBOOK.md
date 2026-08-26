# Mainnet deploy runbook — Monad (chainId 143)

> **STATUS: SUPERSEDED 2026-08-10.** The executors below were redeployed so
> that execution is bound in Solidity to the post-quantum signature
> (`PQExecBinding`). The addresses in this block are the **superseded** ones,
> retained as the historical record of the 2026-07-30 deploy; the procedure
> itself is still current, and was used again for the redeploy.
>
> **Live now:**
>
> | Contract | Address | Changed? |
> |---|---|---|
> | AuditAnchorV2 | `0x8422b555DCE11913A4657C2f47C839637FC71ffd` | no — reused |
> | UniswapRoutingVault | `0xDaEa22D6DCB37FBF1462d6d08ADE40A8fAc05144` | **redeployed** |
> | MorphoSupplyAdapter | `0xE3de921790d04656F2640fA1eDD75492e911Ffa6` | **redeployed** |
> | MLDSAAttestation | `0xb0aADaFe68647578520E988b4444e556c300b4Da` | no — immutable vkey still matches the guest |
>
> **Superseded (2026-07-30 deploy), kept for provenance only:**
>
> | Contract | Superseded address |
> |---|---|
> | UniswapRoutingVault | `0x06F233062eE23590e5CC873df511024f3d981e56` |
> | MorphoSupplyAdapter | `0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E` |
>
> The 2026-08-10 redeploy cost 0.3438 MON and needed **two** constructor
> changes: both executors now take the live `MLDSAAttestation` address as
> `_pqAttestation`. `PQExecBinding` is an `internal` library, so it inlines —
> there is nothing extra to deploy or link.
>
> Anchor deploy tx `0xdb194edf208b64ce5f67b62344a3722f7c95d5983e121b17f0789340e3f20310`.
> Total cost 0.2998 MON. The deployer key is held outside this repository and
> its location is deliberately not recorded here. This repo's `.env` holds only
> the IBM Quantum token and is gitignored.

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
| Tests *(as of the 2026-07-30 deploy)* | 142 Solidity, 85 Python. Recorded as "0 skipped" — which is only ever true with the full fork env (`MONAD_RPC_URL` + `FORK_TOKEN_OUT` + `FORK_FEE`) — and that reading was wrong anyway: the fork tests returned early without an RPC endpoint and reported PASS instead of skipping, so 11 of them never ran. Fixed 2026-08-09 — **incompletely**: the sweep missed `UniswapRoutingVaultFork`, which went on reporting PASS until 2026-08-15, so the honest bare-run skip count is 12, not 11. A bare `forge test` now reports all 12 skipped, and 0 skipped requires the full fork env (`MONAD_RPC_URL` + `FORK_TOKEN_OUT` + `FORK_FEE`), not merely an RPC endpoint. |
| External env | SwapRouter02 / WMON / USDC / Morpho Blue / V3Factory all unchanged; USDC not paused |

Deployment cost *(estimate at the time — not the attest-tx gas)*: **~2,308,043 gas ≈ 0.235 MON** at 102 gwei, **≈0.466 MON** at forge's
padded 202 gwei. Either way it fits, and the deployer additionally holds
501 WMON unwrappable 1:1 if you want headroom.

Predicted addresses for that superseded run (CREATE from nonce 394 —
**verify each one matches**):

```
nonce 394  AuditAnchorV2        0x8422b555DCE11913A4657C2f47C839637FC71ffd
nonce 395  UniswapRoutingVault  0x06F233062eE23590e5CC873df511024f3d981e56   (superseded)
nonce 396  MorphoSupplyAdapter  0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E   (superseded)
```

> **Do not predict addresses when the order is signed against them.** The
> 2026-08-10 redeploy deployed FIRST and signed second, because
> `exec_commitment` covers the vault address: any stray transaction between
> prediction and broadcast shifts the CREATE address and silently invalidates
> an already-signed order. The constructors take no order data, so nothing
> forces the prediction-first ordering.

If a nonce is consumed by anything else in between, the later addresses shift.
That is harmless — the vault and adapter take the anchor's address as an
argument, so just use whatever step 1 actually printed.

---

## Step 0 — wallet

**Preferred: the encrypted keystore.** Use a forge keystore
(aes-128-ctr + scrypt) rather than a raw key. Using it keeps the key
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

## Rotating the agent key (`MLDSAAttestationV2` only)

Not applicable to the live `MLDSAAttestation` at
`0xb0aADaFe68647578520E988b4444e556c300b4Da` — its `agentPkHash` is `immutable`
with no setter, so under it a key change is a redeploy of the attestation
contract **and** both executors. `zk-mldsa/contracts/src/MLDSAAttestationV2.sol`
is what removes that; see `zk-mldsa/README.md`.

**Deploying V2 is itself the last forced redeploy.** `PQ()` is `immutable` on
both executors, so repointing them means new addresses for
`UniswapRoutingVault` and `MorphoSupplyAdapter` one final time. Use
`zk-mldsa/contracts/script/DeployMLDSAAttestationV2.s.sol`, which applies the
same fixture pre-flight as V1 plus a post-deploy assertion that the recovery
path is actually reachable. It additionally requires `GUARDIAN` to differ from
the deployer key: a guardian that is the hot key that broadcasts everything is
a strict downgrade, because one compromise then reaches both. It also refuses a
guardian with no code, no balance and no nonce, because that is a typo and the
consequence of the typo is a recovery path that does not exist — found on the
day it is needed.

### Deploying V2

**Run `zk-mldsa/contracts/deploy-v2.sh` in a real terminal window.** Not through
Claude Code's `!` prefix and not through an agent's shell tool: neither
allocates a TTY, so the keystore passphrase prompt cannot work there — and the
attempt is how a passphrase ended up in a session transcript on 2026-07-30. The
script refuses to run without a TTY rather than relying on anyone remembering
that.

```bash
cd ~/projects/quantum-portfolio/zk-mldsa/contracts
./deploy-v2.sh --dry-run    # preflight + simulation, never broadcasts
./deploy-v2.sh              # same, then asks for a typed DEPLOY before sending
```

It reads no secret, writes none, echoes none, and passes none as an argument —
the passphrase goes from your terminal straight into forge. Every parameter it
sets (`SP1_VERIFIER` `0x7DA83eC4…2abd`, `AGENT_PK_HASH` `0xac0b2aea…02ad`,
`GUARDIAN` `0x05d15996…bc7D`, `RECOVERY_DELAY` 604800) is public and overridable
by environment variable. It also refuses to proceed if `DEPLOYER_PRIVATE_KEY` is
set, unless you pass `ALLOW_ENV_KEY=1` deliberately.

Preflight, before anything is signed: chain is 143, the SP1 verifier has code,
the guardian is neither the deployer nor a dead address, the fixture's `pkHash`
equals `AGENT_PK_HASH`, and the deployer can pay. Then a simulation whose
post-deploy `isValidProof` runs the **real** Groth16 proof against the **real**
verifier in forked state — a pass there means the deployed contract will
actually attest.

### Deployed 2026-08-25

| | |
|---|---|
| `MLDSAAttestationV2` | `0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c` |
| tx | `0x66e06fb31c682e0c9d10ea602c999fdbb52562c687bc5d2ed5ce08995e5669d0` |
| block | 99109468 |
| cost | 0.226432248 MON (2 219 924 gas @ 102 gwei) |

Chain-verified after the fact, not read off the deploy log: `isAgentPk(0xac0b2aea…)`
true, `agentPkCount` 1, `guardian` `0x05d15996…bc7D`, `recoveryDelay` 604800,
`rotationNonce` 0, `pendingPkHash` zero.

**This is not yet in the execution path.** Both executors still point their
immutable `PQ()` at v1 `0xb0aADaFe68647578520E988b4444e556c300b4Da`, so until
steps 2 and 3 land, the live stack is unchanged and the rotation path is
deployed but unused.

### Steps 2 and 3, deployed 2026-08-25

| Contract | Address | Tx | Block | Cost |
|---|---|---|---|---|
| `UniswapRoutingVault` | `0xcC60db5E123Cb3150d5F11CA5526a79B4f31113F` | `0x557c4746…a1f8` | 99111464 | 0.208933434 MON |
| `MorphoSupplyAdapter` | `0x6D42fA32880aDd1d794abBF98c5Cd104Fe332D89` | `0x75ff1c5e…00ba` | 99125304 | 0.13483533 MON |

Migration total 0.570201012 MON. Chain-verified: both new executors return
`PQ() = 0xFeEf24A5…A52c`, both return `ANCHOR() = 0x8422b555…1ffd`, and the
superseded pair still returns v1 `0xb0aADaFe…` — which is the one-call proof
the gate actually moved.

**The provenance trail did NOT move with them.** All six cited proof
transactions ran against the now-retired executors under the v1 attestation.
The live contracts have not yet carried a real settlement. Either re-run the
demo loop against them (two fresh ML-DSA signatures, two fresh Groth16 proofs,
anchor, execute with real value) or say plainly in the docs which addresses the
historical evidence belongs to. Do not let a reader infer the proofs were
produced by the contracts now listed as live.

### One contract per deploy

All three deploys are separate scripts producing a single `CREATE` transaction
each. Keep it that way and run them one at a time, verifying each on Monadscan
before starting the next: Monadscan verification is per-contract, so a bundled
run just means untangling which address goes with which constructor args
afterwards. `deploy-v2.sh` prints the deployed address and a ready-to-paste
`forge verify-contract` command with the constructor arguments re-encoded from
the **live contract**, so they cannot drift from what was actually deployed. Set
`VERIFIER_URL` and `ETHERSCAN_API_KEY` and it runs the verification itself.

Per the round-1 pattern, pass no `--chain` flag — the chainid inside
`--verifier-url` is what routes it. The URL is the Etherscan V2 multichain
endpoint, and it is baked into all three deploy scripts as the `VERIFIER_URL`
default:

```
https://api.etherscan.io/v2/api?chainid=143
```

`ETHERSCAN_API_KEY` lives in `~/projects/fcempowertours/.env`, the same file as
the deployer key.

**All four live contracts are verified** (confirmed 2026-08-25 via
`module=contract&action=getsourcecode`, which returns the contract name and
source for each): `AuditAnchorV2`, `UniswapRoutingVault`, `MorphoSupplyAdapter`,
`MLDSAAttestationV2`. The two executors reported "already verified" on
submission — Monadscan matched the bytecode — so only the attestation needed an
explicit upload.

**The guardian is an EOA, not a multisig** — chain-checked 2026-08-24: no code,
nonce 2, 69.8 MON. That is a deliberate choice and the script only warns, but it
sets an operational requirement rather than removing one. A compromised guardian
still cannot revoke a key, cannot attest, and cannot act inside the delay; what
it can do is add a key after `RECOVERY_DELAY` **if nobody vetoes**. The delay is
only a defence if somebody is watching it:

```bash
# alert on this — a proposal you did not make is the signal to veto
cast logs --address $ATT 'RecoveryProposed(bytes32,uint64)' --rpc-url $RPC
```

The composite failure to avoid is guardian compromised **and** agent key lost or
unwatched. Either alone is survivable; together, after seven days, the attacker
holds an authorised key. Moving the guardian to a multisig later needs no
redeploy — `rotateSetGuardian` does it with one proof.

### Planned rotation — you still hold the old key

```bash
ATT=0x<MLDSAAttestationV2>
RPC=https://rpc.monad.xyz
NONCE=$(cast call $ATT 'rotationNonce()(uint256)' --rpc-url $RPC)

# 1. sign the statement with the CURRENTLY authorised key
python -m src.pq_rotation --action add --subject 0x<sha256 of new keys/pq.pub> \
    --contract $ATT --chain-id 143 --nonce $NONCE --keys keys/ \
    --out zk-mldsa/mldsa_input.json
# 2. prove it on a >=32 GB box — same guest, same vkey, same pipeline as an order
# 3. submit rotateAdd(newPkHash, publicValues, proofBytes)
# 4. confirm
cast call $ATT 'isAgentPk(bytes32)(bool)' 0x<new pk hash> --rpc-url $RPC   # true
cast call $ATT 'agentPkCount()(uint256)' --rpc-url $RPC                    # 2
```

Then let anything already in flight settle before step 5, because **revocation
is retroactive**: `pqAttested` resolves through the key that minted the
attestation, so revoking voids orders that were attested and not yet executed.

```bash
# 5. once nothing is in flight, revoke the old key WITH THE NEW ONE
python -m src.pq_rotation --action revoke --subject 0x<sha256 of OLD pq.pub> \
    --contract $ATT --chain-id 143 --nonce $(cast call $ATT 'rotationNonce()(uint256)' --rpc-url $RPC) \
    --keys keys/ --out zk-mldsa/mldsa_input.json
# prove, then submit rotateRevoke(oldPkHash, publicValues, proofBytes)
```

`rotateRevoke` refuses to remove the last authorised key, so no sequence of
these commands can brick the contract.

### Recovery — the key is lost

The path that exists because a PQ-authorised rotation cannot serve the case
where no valid signature can be produced any more.

```bash
# guardian proposes; this is PUBLIC and starts the veto window
cast send $ATT 'proposeRecovery(bytes32)' 0x<sha256 of new pq.pub> --rpc-url $RPC ...
cast call $ATT 'pendingEta()(uint64)' --rpc-url $RPC   # execute at or after this
# after recoveryDelay, anyone can execute
cast send $ATT 'executeRecovery()' --rpc-url $RPC ...
```

If you see a `RecoveryProposed` you did not initiate and you still hold an
authorised key, **veto it** — that is what the delay is for:

```bash
python -m src.pq_rotation --action veto --subject 0x<the pending pk hash> \
    --contract $ATT --chain-id 143 --nonce $(cast call $ATT 'rotationNonce()(uint256)' --rpc-url $RPC) \
    --keys keys/ --out zk-mldsa/mldsa_input.json
# prove, then submit vetoRecovery(publicValues, proofBytes)
```

Note the asymmetry: proposing costs the guardian one cheap `cast send`, but
vetoing costs the agent a Groth16 proof, so a guardian that re-proposes after
every veto imposes real cost. The answer is to fire it rather than keep vetoing
— one proof instead of an unbounded series, and it drops the live proposal in
the same transaction:

```bash
python -m src.pq_rotation --action set-guardian --subject 0x<new guardian address> \
    --contract $ATT --chain-id 143 --nonce $(cast call $ATT 'rotationNonce()(uint256)' --rpc-url $RPC) \
    --keys keys/ --out zk-mldsa/mldsa_input.json
# prove, then submit rotateSetGuardian(newGuardian, publicValues, proofBytes)
```

The guardian can also renounce (`setGuardian(address(0))`), which is final from
its side but not from the agent's — `rotateSetGuardian` can appoint a new one at
any time. So an outgoing guardian cannot strip a live agent of its recovery
option, only give up its own.

## Operational invariant this deployment assumes

`AuditAnchorV2` treats the commitment as opaque bytes and cannot validate the
deadline sealed inside it. The deadline check lives in
`src/monad_tx.py:validate_route_execution`, which means **all anchoring must go
through the builder**. Anchoring by hand with `cast send` bypasses it and can
burn a sequence number on a route that can no longer execute.
