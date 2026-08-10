// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { PQBind } from "../helpers/PQBind.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchor }         from "../../src/AuditAnchor.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";
import { IWrappedNative }      from "../../src/interfaces/IWrappedNative.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";
import { RT06Morpho }          from "./RT06_V2BindingSurface.t.sol";

/// RED TEAM — RT-09: the deploy scripts, which are the thing that actually runs
/// with real MON. Every constructor argument is immutable, so a guard that does
/// not fire produces a permanently broken contract with no repair path and no
/// rescue function.
///
/// ORIGINAL FINDINGS (both now FIXED; the tests below are those exploits,
/// inverted):
///
///   RT09-1. The "reject the V1 anchor" guard was `anchor != ANCHOR_MAINNET`,
///           which rejects ONE ADDRESS, not the V1 CONTRACT — and the repo's
///           only anchor deploy script (`script/Deploy.s.sol`) deploys V1, with
///           no chainId guard at all. Every remaining guard passed for a fresh
///           V1, or for literally any code-bearing address; the vault deployed
///           and verified, and every `executeAndRoute` reverted forever inside
///           `ANCHOR.execCommitmentOf`. Found by RUNNING the real script against
///           Monad mainnet state rather than reading it: with AUDIT_ANCHOR_ADDR
///           pointed at WMON the script printed
///           "Script ran successfully. UniswapRoutingVault: 0x82BB...".
///
///   RT09-2. `require(feeRaw[i] > 0 && feeRaw[i] <= type(uint24).max)` is a TYPE
///           check, not a safety check: it accepted every value in
///           [1, 16_777_215], including tier 100 — the pool the vault's own
///           NatSpec calls a near-total loss, and whose only mitigation (H-3) is
///           this immutable allowlist. Verified live: `APPROVED_FEE_TIERS=100`
///           and `=7777` both deployed cleanly.
///
/// FIXES in tree: `script/DeployAuditAnchorV2.s.sol` now exists (chainId guard +
/// post-deploy capability self-check); both executor scripts identify the anchor
/// by staticcalling `execCommitmentOf(address,bytes32)` and requiring 32 bytes
/// back; fee tiers must be in {500, 3000, 10000}; duplicate tiers/tokens/markets
/// and WMON-as-output are rejected; each APPROVED_MARKETS id is resolved via
/// `idToMarketParams` on Morpho with its loan token required to be in
/// APPROVED_TOKENS; `script/Deploy.s.sol` refuses to run without
/// DEPLOY_LEGACY_V1_ANCHOR=true.
contract RT09_DeployGuards is Test {
    address constant ANCHOR_V1_MAINNET = 0x4cB79cc36b367A6fd7363BC6a8553a7A270DA27c;

    WMON wmon;
    MockToken usdc;
    FaithfulRouter router;
    RT06Morpho morpho;

    address agent = address(0xA6E17);
    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        router = new FaithfulRouter();
        morpho = new RT06Morpho();
        for (uint256 i = 0; i < 3; ++i) usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 200_000 ether);
        vm.deal(agent, 100 ether);
    }

    /// The anchor-identification guard as both executor scripts now implement
    /// it, so the test and the script cannot drift apart in shape — except for
    /// the probe SUBJECT, which the scripts pass as `address(this)` and this
    /// helper passes as `address(0)`. See RT09i: that difference is why the
    /// scripts currently cannot run at all.
    function _anchorProbePasses(address anchor) internal view returns (bool) {
        return _anchorProbePassesAs(anchor, address(0));
    }

    function _anchorProbePassesAs(address anchor, address subject)
        internal
        view
        returns (bool)
    {
        if (anchor.code.length == 0) return false;
        (bool ok, bytes memory ret) = anchor.staticcall(
            abi.encodeWithSignature("execCommitmentOf(address,bytes32)", subject, bytes32(0))
        );
        return ok && ret.length == 32;
    }

    // =====================================================================
    // RT09-1, inverted
    // =====================================================================

    /// INVERTED (was CONFIRMED, now FIXED) — a fresh V1 anchor used to pass
    /// every guard (`!= ANCHOR_MAINNET` is trivially true for a new address,
    /// `.code.length > 0` is true because V1 is a real contract) and yield an
    /// immutable, unrecoverable brick. The capability probe rejects it, because
    /// V1 has no `execCommitmentOf` and no fallback to fake one.
    function test_RT09a_FreshV1AnchorIsNowRejectedByTheCapabilityProbe() public {
        AuditAnchor v1 = new AuditAnchor();     // what script/Deploy.s.sol produces

        // the two guards the OLD script had — both still pass, which is the point
        assertTrue(address(v1) != ANCHOR_V1_MAINNET, "old guard 1 passes: not the known address");
        assertTrue(address(v1).code.length > 0,      "old guard 2 passes: it has code");

        // the guard that replaced them
        assertFalse(_anchorProbePasses(address(v1)), "probe REJECTS a V1 anchor");
        assertTrue(_anchorProbePasses(address(new AuditAnchorV2())), "probe ACCEPTS a V2 anchor");
    }

    /// INVERTED — the generalised version, which is what actually bit: the old
    /// blacklist let ANY code-bearing address through. Reproduced originally by
    /// running the real script with AUDIT_ANCHOR_ADDR=WMON against mainnet.
    function test_RT09b_ArbitraryCodeBearingAddressesAreNowRejected() public view {
        assertFalse(_anchorProbePasses(address(wmon)),   "WMON is not an anchor");
        assertFalse(_anchorProbePasses(address(router)), "the router is not an anchor");
        assertFalse(_anchorProbePasses(address(usdc)),   "a token is not an anchor");
        assertFalse(_anchorProbePasses(address(0)),      "no code");
        assertFalse(_anchorProbePasses(address(0xDEADBEEF)), "typo'd EOA-shaped address");
    }

    /// The consequence the probe now prevents, kept as the reason it matters:
    /// wiring a non-V2 anchor produces a live, verified, permanently dead
    /// contract. Nothing in the CONTRACT stops this — the defence is entirely in
    /// the script, which is why the script is the security boundary here.
    function test_RT09c_WhyItMatters_NonV2AnchorStillBricksTheVaultIfItGetsThrough() public {
        AuditAnchor v1 = new AuditAnchor();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        UniswapRoutingVault dead = new UniswapRoutingVault(
            address(wmon), address(router), address(v1), address(new MockPQAttestation()), approved, tiers
        );

        address[] memory t = new address[](1); t[0] = address(usdc);
        uint24[]  memory f = new uint24[](1);  f[0] = FEE;
        uint16[]  memory w = new uint16[](1);  w[0] = 10_000;
        uint256[] memory m = new uint256[](1); m[0] = 1;

        // The orderHash is DERIVED from the execution parameters, so the
        // PQ-binding check passes and the call dies where this test says it
        // does — inside `ANCHOR.execCommitmentOf`. An invented hash would
        // revert one layer earlier and prove nothing about the anchor.
        (bytes memory pre, bytes32 h) = PQBind.preimage(
            keccak256(
                abi.encode(
                    block.chainid, address(dead), agent, t, f, w,
                    uint256(1 ether), m, FUTURE
                )
            )
        );

        vm.prank(agent);
        v1.anchor(h, 0);                          // anchoring "works" on V1

        vm.prank(agent);
        vm.expectRevert();                        // no execCommitmentOf, no fallback
        dead.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE, pre);

        assertEq(address(dead.ANCHOR()), address(v1), "immutable: no owner, no setter, no rescue");
    }

    /// Same, on the adapter.
    function test_RT09d_NonV2AnchorAlsoBricksTheMorphoAdapter() public {
        AuditAnchor v1 = new AuditAnchor();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market()));
        MorphoSupplyAdapter dead =
            new MorphoSupplyAdapter(address(morpho), address(v1), address(new MockPQAttestation()), approved, markets);

        // Same as RT09c: derive the orderHash so the binding is satisfied and
        // the revert is genuinely the V1 anchor's missing `execCommitmentOf`.
        MarketParams memory p = _market();
        (bytes memory pre, bytes32 h) = PQBind.preimage(
            keccak256(
                abi.encode(
                    block.chainid, address(dead), agent, p.loanToken,
                    p.collateralToken, p.oracle, p.irm, p.lltv, uint256(1 ether)
                )
            )
        );

        vm.startPrank(agent);
        usdc.faucet(10 ether);
        usdc.approve(address(dead), type(uint256).max);
        vm.expectRevert();
        dead.supply(h, p, 1 ether, 1 ether, pre);
        vm.stopPrank();
    }

    // =====================================================================
    // RT09-2, inverted
    // =====================================================================

    /// The fee-tier guard as the script now implements it.
    function _feeTierAccepted(uint256 raw) internal pure returns (bool) {
        return raw == 500 || raw == 3000 || raw == 10000;
    }

    /// INVERTED (was CONFIRMED, now FIXED) — the old guard accepted every
    /// uint24. Fuzzed over that whole range: everything outside
    /// {500, 3000, 10000} is now refused, tier 100 included — and tier 100 is a
    /// REAL Uniswap tier, which is exactly why a range check could never have
    /// been the H-3 mitigation.
    function testFuzz_RT09e_OnlyCanonicalDeepTiersAreAccepted(uint256 raw) public pure {
        uint256 v = bound(raw, 1, uint256(type(uint24).max));
        assertTrue(v > 0 && v <= type(uint24).max, "the old guard accepted this");
        if (v != 500 && v != 3000 && v != 10000) {
            assertFalse(_feeTierAccepted(v), "the new guard refuses it");
        } else {
            assertTrue(_feeTierAccepted(v));
        }
    }

    /// The specific typos that used to deploy a permanently mis-routed vault.
    function test_RT09f_TheSpecificTyposThatUsedToDeploy() public pure {
        assertFalse(_feeTierAccepted(100),   "the 0.01% dust pool - the H-3 hazard");
        assertFalse(_feeTierAccepted(7777),  "not a tier at all");
        assertFalse(_feeTierAccepted(30000), "an extra digit on 3000");
        assertFalse(_feeTierAccepted(50),    "a dropped digit on 500");
        assertFalse(_feeTierAccepted(1),     "the old lower bound");
        assertTrue(_feeTierAccepted(500));
        assertTrue(_feeTierAccepted(3000));
        assertTrue(_feeTierAccepted(10000));
    }

    /// NEGATIVE — the contract itself still has no fee-tier opinion, so the
    /// script remains the only line of defence. Recorded so nobody mistakes the
    /// fix for a contract-level invariant: a future deploy path that bypasses
    /// the script re-opens H-3 in full.
    function test_RT09g_TheVaultItselfStillAcceptsAnyTier() public {
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = 100;
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        UniswapRoutingVault v = new UniswapRoutingVault(
            address(wmon), address(router), address(new AuditAnchorV2()), address(new MockPQAttestation()), approved, tiers
        );
        assertTrue(v.isApprovedFeeTier(100), "the constructor takes what it is given");
        assertFalse(_feeTierAccepted(100),   "only the script stops it reaching here");
    }

    // =====================================================================
    // RT09-3 — NEW, introduced BY the RT09-1 fix. HARD BLOCKER.
    // =====================================================================

    /// CONFIRMED (Critical for the deploy gate, NEW) — all three deploy scripts
    /// are currently NON-FUNCTIONAL. The capability probe passes
    /// `address(this)` as the probe subject:
    ///
    ///   DeployUniswapRoutingVault.s.sol:76
    ///   DeployMorphoSupplyAdapter.s.sol:47
    ///   DeployAuditAnchorV2.s.sol:43
    ///
    /// and forge refuses to evaluate `address(this)` inside a script contract:
    ///
    ///   [Revert] Usage of `address(this)` detected in script contract. Script
    ///   contracts are ephemeral and their addresses should not be relied upon.
    ///
    /// Reproduced against Monad mainnet state, on the HAPPY path, with nothing
    /// else to get wrong:
    ///
    ///   DEPLOYER_PRIVATE_KEY=... forge script script/DeployAuditAnchorV2.s.sol \
    ///     --rpc-url https://rpc.monad.xyz
    ///   -> [Revert] Usage of `address(this)` detected in script contract.
    ///
    /// So the anchor cannot be deployed, and neither executor can be deployed.
    /// This is my own suggested fix, mis-landed: I proposed the probe and did
    /// not specify the subject.
    ///
    /// FIX: one word per site — pass any constant instead. The probe's strength
    /// does not depend on the subject at all: `execCommitmentOf` is a plain
    /// two-key mapping getter, so what is being tested is whether the SELECTOR
    /// resolves and returns 32 bytes. This test proves the equivalence over
    /// arbitrary subjects.
    function testFuzz_RT09i_ProbeIsIndependentOfItsSubjectSoAddressThisIsUnnecessary(
        address subject
    ) public {
        AuditAnchorV2 v2 = new AuditAnchorV2();
        AuditAnchor   v1 = new AuditAnchor();

        assertTrue(
            _anchorProbePassesAs(address(v2), subject),
            "V2 accepted for every subject, including address(0)"
        );
        assertFalse(
            _anchorProbePassesAs(address(v1), subject),
            "V1 rejected for every subject"
        );
        assertFalse(_anchorProbePassesAs(address(wmon), subject), "non-anchor rejected");

        // and the value returned is bytes32(0) for any unused slot, which is
        // what DeployAuditAnchorV2's `== bytes32(0)` self-check asserts
        assertEq(v2.execCommitmentOf(subject, bytes32(0)), bytes32(0));
    }

    function _market() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xC0),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: 86e16
        });
    }
}

/// RT-09 fork leg — quantify the H-3 hazard the old fee-tier guard let through,
/// against live Monad mainnet pools. Kept after the fix as the standing
/// justification for the allowlist, and because the magnitude moves.
contract RT09_ThinTierFork is Test {
    address constant WMON_MAINNET = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;

    address trader = address(0x7AAD);
    address tokenOut;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == 143, "fork is not Monad mainnet");
        forked = true;
        tokenOut = vm.envAddress("FORK_TOKEN_OUT");
        vm.deal(trader, 1_000 ether);
    }

    function _quote(uint24 fee, uint256 amountIn) internal returns (bool ok, uint256 out) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(trader);
        IWrappedNative(WMON_MAINNET).deposit{ value: amountIn }();
        IERC20(WMON_MAINNET).approve(ROUTER, amountIn);
        try IV3SwapRouter(ROUTER).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: WMON_MAINNET,
                tokenOut: tokenOut,
                fee: fee,
                recipient: trader,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 got) {
            ok = true;
            out = got;
        } catch {
            ok = false;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// MEASUREMENT — routing 1 MON through the tiers the old script accepted.
    /// The spread is the loss an operator's typo in APPROVED_FEE_TIERS would
    /// have locked into an immutable contract.
    function test_RT09h_ForkMeasuresTheThinTierLoss() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        (bool ok3000, uint256 out3000) = _quote(3000, 1 ether);
        (bool ok500,  uint256 out500)  = _quote(500,  1 ether);
        (bool ok100,  uint256 out100)  = _quote(100,  1 ether);

        emit log_named_uint("1 MON via fee=3000 ->", ok3000 ? out3000 : 0);
        emit log_named_uint("1 MON via fee=500  ->", ok500  ? out500  : 0);
        emit log_named_uint("1 MON via fee=100  ->", ok100  ? out100  : 0);

        assertTrue(ok3000 && out3000 > 0, "the reference tier quotes");

        uint256 best = out3000;
        if (ok500 && out500 > best) best = out500;
        if (ok100 && out100 > best) best = out100;

        if (ok100) emit log_named_uint("fee=100 shortfall vs best, bps", _bps(out100, best));
        else       emit log("fee=100 pool is unusable at 1 MON (reverts) - a bricked route");
        if (ok500) emit log_named_uint("fee=500 shortfall vs best, bps", _bps(out500, best));
        else       emit log("fee=500 pool is unusable at 1 MON (reverts)");
        emit log_named_uint("fee=3000 shortfall vs best, bps", _bps(out3000, best));

        // MEASURED FACT, recorded so it can be re-checked before deploy: the
        // NatSpec's H-3 numbers (0.19 USDC in the 0.01% pool vs 447k in the
        // 0.3% pool, "an 88-99% loss") no longer describe the live chain; the
        // observed spread is a few hundred bps. The hazard is real but its
        // magnitude is a moving target, which is precisely the argument for an
        // allowlist validated at deploy time rather than typed into an env var.
        //
        // Note the script now REFUSES tier 100 even though it currently quotes
        // within a few hundred bps of the best pool. That is the right call: the
        // allowlist is immutable and liquidity is not.
        assertGt(best, 0, "at least one tier is routable");
    }

    function _bps(uint256 got, uint256 best) internal pure returns (uint256) {
        if (got >= best) return 0;
        return ((best - got) * 10_000) / best;
    }
}
