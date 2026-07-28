# Security Audit — Round 2 (pre-redeploy)

**Date**: 2026-07-28
**Predecessor**: [`AUDIT_2026-07-28.md`](AUDIT_2026-07-28.md) (round 1)
**Trigger**: fixes applied for round-1 findings H-1 and H-2; re-audit requested before redeploying
to Monad mainnet.
**Scope**: the H-1/H-2 patches and any risk they introduce, the deploy scripts that are about to be
executed, a bug-class sweep for the same defect elsewhere, and re-verification of standing findings.

---

## Verdict

**H-1 and H-2 are fixed and the fixes are verified.** The patched invariant preserves the property
that mattered (the full deposit must be deployed) while making donated dust inert, and — critically
— tolerating dust does **not** make it stealable. Both claims are backed by passing tests, not
reasoning alone.

**53/53 unit tests pass. All 3 mainnet fork tests pass against live Monad state**, including a real
routed swap through the WMON/USDC pool and a real supply into the live Morpho Blue market.

Blocking item before redeploy: **N-1** below — the deploy scripts do not validate their
constructor inputs, and every constructor argument is `immutable`. A typo'd env var produces a
permanently broken contract. That is a one-line fix per script and it protects an irreversible
action.

| Round-2 finding | Severity |
|---|---|
| N-1 Deploy scripts don't validate constructor addresses | MEDIUM (pre-redeploy blocker) |
| N-2 Identical dust bug still present in deprecated `RoutingVault` | LOW |
| N-3 Donated dust is now permanently locked | INFO (accepted) |
| N-4 Strict-equality invariant is incompatible with fee-on-transfer / rebasing tokens | INFO |

Standing round-1 findings **H-3, M-1, M-2, M-3, M-4 remain open and unchanged** — they were out of
scope for this patch. H-3 in particular still misstates what the ZK circuit proves.

---

## Verification of the H-1 / H-2 fixes

### What changed

Both contracts now snapshot their balance on entry and assert the balance is *unchanged* at exit,
instead of asserting it is *zero*:

```solidity
// UniswapRoutingVault.sol:133 / :169
uint256 balBefore = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
...
uint256 balAfter = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
if (balAfter != balBefore) {
    revert WMonDustResidual(balAfter > balBefore ? balAfter - balBefore : balBefore - balAfter);
}
```

`MorphoSupplyAdapter.sol:89 / :100` mirrors this exactly. The two-sided ternary means the revert
data reports the true delta and the expression can never underflow-panic, so callers always get a
clean custom error rather than `Panic(0x11)`.

### Evidence

New regression suite: `contracts/test/AuditPoC_DustDoS.t.sol` — 8 tests, all passing.

| Test | Proves |
|---|---|
| `test_H1_DonatedWMonDustDoesNotBrickVault` | 1-wei donation no longer bricks the vault; two independent orders both route; dust untouched |
| `testFuzz_H1_AnyDonationAmountIsInert` (256 runs) | inertness holds for donations from 1 wei to 5 MON |
| `test_H2_DonatedTokenDustDoesNotBrickAdapter` | same for the adapter; two supplies succeed with dust present |
| `test_H1_UnroutedDepositStillReverts` | the **real** invariant still fires — a router that strands 1 wei reverts with `WMonDustResidual(1)` **despite 7 wei of pre-existing dust**, proving the check measures the delta and not the balance |
| `test_H2_UnsuppliedAssetsStillRevert` | same for the adapter — reverts with `DustResidual(1)` despite 9 units of pre-existing dust |
| `test_H1Fix_DonatedDustIsNotStealableByGreedyRouter` | **new-risk check** (below) |
| `test_H2Fix_DonatedDustIsNotStealableByGreedyMorpho` | **new-risk check** (below) |
| `test_VaultWorksWithNoDust` | no regression on the clean path |

### New-risk analysis: is tolerated dust now stealable?

This is the question the fix creates. Before, dust caused a revert — annoying, but it meant nobody
could take it. Now dust sits in the contract across calls, so it must be unreachable.

It is. The allowance handed to the counterparty is exactly the amount being deployed
(`forceApprove(ROUTER, msg.value)` / `forceApprove(MORPHO, assets)`), and it is reset to zero
immediately after. The swap loop's per-leg `amountIn` sums to exactly `msg.value`, so there is no
allowance headroom to reach the dust. A counterparty that tries to pull more exceeds its allowance
and the whole call reverts.

I verified this adversarially rather than by argument: `GreedyRouter` and `GreedyMorpho` are mocks
that attempt `transferFrom(vault, balanceOf(vault))` — sweeping the entire balance, dust included.
Both revert, and the donated dust (3 MON and 500 USDC respectively in the tests) is asserted intact
afterwards.

### Fork tests against live mainnet

```
[PASS] test_RoutesNativeMonThroughLiveUniswapPool      0.1 MON -> 2118 USDC micro-units
[PASS] test_SuppliesUsdcIntoLiveMorphoMarket
[PASS] test_RevertsWithoutAnchor
```

(The 2118 vs. the 2271 recorded in July is ordinary MON/USDC price movement, not a regression.)

---

## N-1 — Deploy scripts do not validate constructor addresses *(pre-redeploy blocker)*

**Files**: `contracts/script/DeployUniswapRoutingVault.s.sol:36-45`,
`contracts/script/DeployMorphoSupplyAdapter.s.sol:21-27`

Both scripts read `AUDIT_ANCHOR_ADDR` and `APPROVED_TOKENS` from the environment and pass them
straight into constructors that store them as `immutable` / in a frozen mapping. Nothing checks
that those addresses contain code.

A mistyped or stale `AUDIT_ANCHOR_ADDR` yields a vault whose `ANCHOR.lastHash(...)` call reverts on
every invocation — a contract that is dead on arrival and, because the field is immutable,
unfixable. A mistyped entry in `APPROVED_TOKENS` silently allowlists an address that isn't a token.
This is exactly the class of error that costs a redeploy, and you are about to run these scripts
against mainnet with real MON.

The existing `require(block.chainid == 143)` guard shows the right instinct; it just doesn't extend
to the addresses.

**Fix** (both scripts, before `startBroadcast`):

```solidity
require(anchor.code.length > 0, "AUDIT_ANCHOR_ADDR has no code");
for (uint256 i = 0; i < approved.length; ++i) {
    require(approved[i].code.length > 0, "APPROVED_TOKENS entry has no code");
}
```

For the vault, also assert the anchor is the expected one rather than merely code-bearing:

```solidity
require(anchor == 0x4cB79cC36b367a6FD7363bC6a8553a7a270dA27c, "unexpected AuditAnchor");
```

## N-2 — The identical bug still exists in the deprecated `RoutingVault`

**File**: `contracts/src/RoutingVault.sol:134`

```solidity
uint256 residual = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
if (residual != 0) revert WMonDustResidual(residual);
```

Byte-for-byte the round-1 H-1 defect. `RoutingVault` is the MiniAMM-era predecessor, superseded by
`UniswapRoutingVault` and deployed only to testnet (chainId 10143) — so there is no live mainnet
exposure. But it remains in `contracts/src/`, it is buildable, and a deploy script exists.

**Fix**: delete it (and `dex/MiniAMM.sol`, `dex/MockToken.sol` if unused outside tests), or apply
the same balance-delta patch. Leaving a known-vulnerable contract in the source tree of a
submission is a bad look for a reviewer who greps for the pattern.

A sweep of `grep -rn "balanceOf(address(this))" contracts/src/` found no other instances of the
defect. `MiniAMM`'s balance reads are Uniswap-V2-style reserve accounting, which is correct by
design and already has a `skim()` escape hatch.

## N-3 — Donated dust is now permanently locked *(accepted)*

Neither contract has a sweep function, so donated dust stays forever. This is the deliberate
trade-off: the donor burns their own tokens, no user is harmed, and adding a sweep would introduce
a privileged role into contracts that currently have none. Documented here so it is a recorded
decision rather than an oversight. If you would rather not strand it, a permissionless
`sweepDust(address to)` that forwards `balanceOf(this)` to a fixed burn address is the minimal
non-privileged option.

## N-4 — Strict equality is incompatible with fee-on-transfer and rebasing tokens *(informational)*

`balAfter != balBefore` assumes the token moves exactly the amounts requested. A fee-on-transfer
token would leave a shortfall and a positive-rebasing token a surplus; either reverts. That is
fail-closed and therefore safe, but it means such a token can never be added to the allowlist.

No impact today: the allowlist on both live deployments is `[USDC]`, which is a plain ERC-20. Record
this as a constraint on future allowlist additions.

---

## Standing findings from round 1 — status

| ID | Finding | Status |
|---|---|---|
| H-3 | ZK guest doesn't bind the signing key; any `orderHash` can be attested | **OPEN** — unchanged |
| M-1 | Python verifier trusts the public key embedded in the artifact | **OPEN** — unchanged |
| M-2 | Anchor "provenance gate" is not authorization | **OPEN** — unchanged |
| M-3 | 30+ CVEs in Streamlit transitive deps | **OPEN** — unchanged |
| M-4 | `MorphoSupplyAdapter` doesn't validate the target market | **OPEN** — unchanged |

H-3 and M-1 do not block this redeploy (neither contract reads `pqAttested`), but H-3 is the one
that will draw a technical reviewer's eye, because the circuit proves a strictly weaker statement
than the writeup claims. M-4 is worth folding into *this* redeploy if you are touching the adapter
anyway — adding a market allowlist costs one mapping and one check, and doing it now avoids a third
deployment.

---

## Redeploy checklist

1. **Apply N-1** to both deploy scripts. One-line guards; protects an irreversible action.
2. **Consider folding in M-4** (market allowlist) — you are already redeploying the adapter, so this
   is free now and costs another deployment later.
3. **Reuse the existing `AuditAnchor`** at `0x4cB79cC36b367a6FD7363bC6a8553a7a270dA27c`. It is
   unchanged and must **not** be redeployed — its `lastHash`/`nextSequence` state is what the
   historical proof transactions in `SUBMISSION.md` depend on. Verified still live, and the
   deployer's `lastHash` is still `0xf9e798a1…d3c3`, so the existing anchored order will satisfy the
   gate on the new vault without re-anchoring.
4. **Gas**: deployer `0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1` holds **0.989 MON**. Enough for
   both deployments and verification, but tight if you also intend to re-run the full
   anchor → swap → supply demo loop with real value. Top up first if you want fresh proof TXs.
5. **After deploying**, re-verify on Monadscan with the round-1 command pattern (omit `--chain 143`;
   the chainid in `--verifier-url` is what routes it), and re-run the constructor-args encoding for
   the vault — `(WMON, ROUTER, anchor, [USDC])`.
6. **Update `SUBMISSION.md`** and the project memory with the new addresses, and mark the old
   `0xe2fcada0…` / `0xB1a43414…` as deprecated. Both currently hold zero balance (re-verified) and
   are non-custodial, so nothing needs migrating — but the old ones remain brickable, and a reviewer
   following a stale address should not land on the vulnerable version.
7. **Re-run the demo loop** against the new contracts if you want the provenance trail in
   `SUBMISSION.md` to cite live, current addresses.

---

## Confidence

**HIGH** that H-1/H-2 are fixed — verified by 8 targeted tests including adversarial greedy-
counterparty mocks and a 256-run fuzz, plus 3 live-mainnet fork tests.
**HIGH** for N-1, N-2 — read directly from the source that is about to be executed.
**MEDIUM** for N-4 — reasoned from the token semantics; not exercised with an actual fee-on-transfer
token, since none can reach the allowlist.
**Not re-covered this round** (unchanged since round 1): the Python pipeline beyond the standing
findings, `app.py` UI logic, QAOA/forecasting numerics, and Rust dependency CVEs (`cargo-audit`
still not installed).
