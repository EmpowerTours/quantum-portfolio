// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { PQBind } from "../helpers/PQBind.sol";
import { PQExecBinding } from "../../src/PQExecBinding.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 }  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";
import { RT06Morpho }          from "./RT06_V2BindingSurface.t.sol";

/// tokenOut that reenters an arbitrary target from inside `transfer`, i.e.
/// from inside the vault's routing loop, BEFORE the vault's own
/// post-conditions run. Used to attack ACROSS contracts, where the vault's
/// per-contract `nonReentrant` does not reach.
contract CrossReenterToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public fired;
    bool public succeeded;
    bytes public returndataOnFail;

    constructor() ERC20("Cross", "X") {}

    function mint(address to, uint256 a) external { _mint(to, a); }

    function arm(address _t, bytes calldata _p) external {
        target = _t; payload = _p; armed = true;
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (armed && !fired) {
            fired = true;
            (bool ok, bytes memory ret) = target.call(payload);
            succeeded = ok;
            returndataOnFail = ret;
        }
    }
}

/// The agent's own wallet, as a contract, so the reentrant call carries the
/// ANCHORER as msg.sender. Without this the reentry hits `AnchorNotFound`
/// (the token's own address has no anchors) and proves nothing.
contract AgentAccount {
    AuditAnchorV2 public immutable ANCHOR;
    UniswapRoutingVault public immutable VAULT;
    MorphoSupplyAdapter public immutable ADAPTER;

    bytes public reentryPayload;
    address public reentryTarget;
    bool public armed;
    bool public fired;
    bool public succeeded;
    bytes public lastReturndata;

    constructor(AuditAnchorV2 a, UniswapRoutingVault v, MorphoSupplyAdapter d) {
        ANCHOR = a; VAULT = v; ADAPTER = d;
    }

    receive() external payable {}

    function anchorIt(bytes32 h, bytes32 c, uint64 s) external { ANCHOR.anchor(h, c, s); }

    function approveToken(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function arm(address t, bytes calldata p) external { reentryTarget = t; reentryPayload = p; armed = true; }

    /// called by the payout token from inside the vault's routing loop
    function onTokenReceived() external {
        if (!armed || fired) return;
        fired = true;
        (bool ok, bytes memory ret) = reentryTarget.call(reentryPayload);
        succeeded = ok;
        lastReturndata = ret;
    }

    function route(
        bytes32 h,
        address[] calldata t,
        uint24[] calldata f,
        uint16[] calldata w,
        uint256[] calldata m,
        uint256 d,
        uint256 value,
        bytes calldata pre
    ) external {
        VAULT.executeAndRoute{ value: value }(h, t, f, w, m, d, pre);
    }
}

/// Router that pays out in the reentrant token.
contract ReenterRouter is IV3SwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn * 2000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

/// RED TEAM — RT-11: AuditAnchorV2's state machine, and the consumed-flag
/// interaction ACROSS the two executors (which each carry their own
/// ReentrancyGuard and their own `consumed` map, but share one anchor).
contract RT11_AnchorStateMachine is Test {
    WMON wmon;
    MockToken usdc;
    CrossReenterToken evil;
    AuditAnchorV2 anchor;
    ReenterRouter router;
    RT06Morpho morpho;
    UniswapRoutingVault vault;
    MorphoSupplyAdapter adapter;
    AgentAccount acct;

    address agent = address(0xA6E17);
    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        evil = new CrossReenterToken();
        anchor = new AuditAnchorV2();
        router = new ReenterRouter();
        morpho = new RT06Morpho();

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(evil);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(new MockPQAttestation()), approved, tiers
        );

        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market()));
        adapter = new MorphoSupplyAdapter(address(morpho), address(anchor), address(new MockPQAttestation()), approved, markets);

        evil.mint(address(router), 1_000_000 ether);
        for (uint256 i = 0; i < 6; ++i) usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 500_000 ether);
        vm.deal(agent, 1_000 ether);

        acct = new AgentAccount(anchor, vault, adapter);
        vm.deal(address(acct), 1_000 ether);
        usdc.transfer(address(acct), 5_000 ether);
        acct.approveToken(address(usdc), address(adapter));
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

    function _one(address tok)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tok;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    /// The orderHash is now DERIVED from the execution parameters — the vault
    /// requires bytes that sha256 to it and carry the matching
    /// `exec_commitment`, so a test can no longer name an order with
    /// `keccak256("literal")`. Two calls with identical parameters therefore
    /// derive the SAME hash; where this file needs two independent orders they
    /// differ in `value`.
    function _deriveRoute(
        address who,
        address[] memory t,
        uint24[]  memory f,
        uint16[]  memory w,
        uint256   value,
        uint256[] memory m,
        uint256   deadline
    ) internal view returns (bytes32 h, bytes memory pre) {
        (pre, h) = PQBind.preimage(
            keccak256(
                abi.encode(block.chainid, address(vault), who, t, f, w, value, m, deadline)
            )
        );
    }

    // =====================================================================
    // (1) storage invariants of the anchor
    // =====================================================================

    /// NEGATIVE — the three storage maps never diverge. Every successful
    /// anchor advances `nextSequence` by exactly one, sets `lastHash` to the
    /// orderHash just written, and leaves `execCommitmentOf[a][lastHash[a]]`
    /// non-zero. There is no path that writes one without the others.
    function testFuzz_RT11a_AnchorStorageInvariantsHold(bytes32[8] memory hashes, bytes32 salt)
        public
    {
        uint64 written;
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 h = hashes[i];
            bytes32 c = keccak256(abi.encode(salt, i));
            if (h == bytes32(0) || anchor.execCommitmentOf(agent, h) != bytes32(0)) continue;

            vm.prank(agent);
            anchor.anchor(h, c, written);
            written++;

            assertEq(anchor.nextSequence(agent), written, "sequence == anchors written");
            assertEq(anchor.lastHash(agent), h, "lastHash tracks the newest write");
            assertEq(anchor.execCommitmentOf(agent, h), c, "commitment stored");
            assertTrue(
                anchor.execCommitmentOf(agent, anchor.lastHash(agent)) != bytes32(0),
                "lastHash always points at a live commitment"
            );
        }
    }

    /// INFORMATIONAL — `unchecked { nextSequence = sequence + 1 }` is safe by
    /// resource exhaustion, not by a check. Reaching 2^64 requires ~1.8e19
    /// anchors; at the measured 27_098 gas per warm anchor that is ~5e23 gas,
    /// or ~3.3e15 full 150M-gas Monad blocks. Not reachable. Recorded so the
    /// reasoning is on file rather than assumed.
    function test_RT11b_SequenceOverflowIsUnreachableByCost() public pure {
        uint256 anchorsToWrap = type(uint64).max;
        uint256 gasPerAnchor  = 27_098;               // measured in RT10c
        uint256 blocks = (anchorsToWrap / 150_000_000) * gasPerAnchor;
        assertGt(blocks, 1e15, "wrapping the sequence costs >1e15 full blocks");
    }

    /// CONFIRMED (Low, NEW) — `lastHash` and `execCommitmentOf` model
    /// different things and V2 kept both. `lastHash` is a LINEAR chain
    /// (one slot, overwritten); `execCommitmentOf` is a SET (never cleared).
    /// After pipelining, `lastHash` names an order that may never execute,
    /// while orders that DID execute are invisible in it. An indexer that
    /// reconstructs provenance from the `prevHash`/`lastHash` chain — which is
    /// what V1's ABI taught it to do, and what the field is still named for —
    /// will not see execution state at all.
    ///
    /// Not exploitable on chain (executors read `execCommitmentOf`), but the
    /// audit trail is the product here, so it is worth stating plainly:
    /// `lastHash` is now decorative and its name implies an authority it no
    /// longer has.
    function test_RT11c_LastHashAndCommitmentSetDiverge() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));

        // Two INDEPENDENT orders. They must differ in at least one execution
        // parameter or they would derive the same orderHash; the deposit size
        // is what distinguishes them (1 MON vs 2 MON), as it already did.
        (bytes32 h1, bytes memory pre1) = _deriveRoute(agent, t, f, w, 1 ether, m, FUTURE);
        (bytes32 h2, )                  = _deriveRoute(agent, t, f, w, 2 ether, m, FUTURE);
        assertTrue(h1 != h2, "two distinct orders");
        bytes32 c1 = vault.routeCommitment(h1, agent, t, f, w, 1 ether, m, FUTURE);
        bytes32 c2 = vault.routeCommitment(h2, agent, t, f, w, 2 ether, m, FUTURE);

        vm.startPrank(agent);
        anchor.anchor(h1, c1, 0);
        anchor.anchor(h2, c2, 1);
        vm.stopPrank();

        // execute the OLDER order only
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(h1, t, f, w, m, FUTURE, pre1);

        assertEq(anchor.lastHash(agent), h2, "chain head is the UNexecuted order");
        assertTrue(vault.consumed(agent, h1), "the executed order is not the chain head");
        assertFalse(vault.consumed(agent, h2));
        // and both commitments remain live in the anchor forever
        assertEq(anchor.execCommitmentOf(agent, h1), c1, "spent, yet still 'anchored'");
        assertEq(anchor.execCommitmentOf(agent, h2), c2);
    }

    /// CONFIRMED (Low/Medium, NEW) — putting `deadline` inside the commitment
    /// (the M-7 fix) made the ANCHORING transaction deadline-sensitive, and
    /// `anchor()` does not validate it. If the anchor tx lands after the
    /// order's deadline — mempool congestion, a nonce gap, a reorg, a stuck
    /// relayer — the order is dead on arrival: it can never execute, it can
    /// never be re-anchored (AlreadyAnchored), and it has burned a sequence
    /// number in the audit chain. This is a routine production event, not an
    /// adversarial one.
    ///
    /// FIX: reject `deadline < block.timestamp` in `anchor()` — which requires
    /// the deadline as an explicit argument — or, better, drop `deadline` from
    /// the commitment and bind a signed validity window instead.
    function test_RT11d_AnchoringLateOfTheDeadlineBricksTheOrderPermanently() public {
        vm.warp(1_000_000);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));
        // Literal timestamps, deliberately. `uint256 deadline = block.timestamp
        // + 60` is not safe here: TIMESTAMP is a movable instruction, so under
        // via_ir the optimiser rematerialises the expression at each use and it
        // silently follows `vm.warp` forward — the deadline then never passes
        // and this test reports a binding failure instead of the brick it is
        // about. (Observed exactly that during this migration.)
        uint256 deadline = 1_000_060;                 // PQ-signed: valid 60s
        (bytes32 h, bytes memory pre) = _deriveRoute(agent, t, f, w, 1 ether, m, deadline);
        bytes32 c = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, deadline);

        // the anchoring tx is delayed and lands 10 minutes late
        vm.warp(1_000_600);
        vm.prank(agent);
        anchor.anchor(h, c, 0);                       // accepted, no complaint

        // the order is unexecutable...
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.DeadlinePassed.selector, deadline, block.timestamp
            )
        );
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, deadline, pre);

        // ...and unrepairable.
        bytes32 fresh = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, block.timestamp + 60);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AuditAnchorV2.AlreadyAnchored.selector, h));
        anchor.anchor(h, fresh, 1);

        assertEq(anchor.nextSequence(agent), 1, "a sequence was burned on a dead order");
    }

    // =====================================================================
    // (2) the consumed flag ACROSS both executors, under reentrancy
    // =====================================================================

    /// NEGATIVE (the question asked, answered directly) — the vault and the
    /// adapter keep SEPARATE `consumed` maps and SEPARATE ReentrancyGuards,
    /// so a vault -> adapter reentry is blocked by NEITHER guard. What blocks
    /// it is the commitment: `execCommitmentOf[user][orderHash]` holds ONE
    /// value, and a route commitment can never equal a supply commitment
    /// (RT08c), so the adapter rejects it.
    ///
    /// Proved from INSIDE the vault's routing loop, mid-transaction, with the
    /// vault's own `consumed[acct][h]` already set to true, and with the
    /// reentrant call carrying the ANCHORER as msg.sender (an EOA-shaped
    /// prank cannot reach here, which is why the agent is a contract).
    ///
    /// POST-RT12 NOTE. The rejection now happens one layer EARLIER than it did.
    /// The reentry can only carry the one preimage that exists for `h` — the
    /// ROUTE order — and the adapter's `PQExecBinding` check runs before the
    /// anchor lookup, so it fires `ExecCommitmentMismatch` first. That is not a
    /// weaker result: `ExecutionNotAnchored` is now UNREACHABLE for a
    /// cross-executor reentry, because a single orderHash can no longer be made
    /// to bind two executors at all (the executor's address is inside the
    /// commitment the preimage carries — RT08c). The original property is
    /// therefore asserted directly below as well, against the anchor's own
    /// storage, rather than being inferred from a revert selector.
    function test_RT11e_CrossExecutorReentryOnOneAnchorIsRejectedByTheCommitment() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(evil));
        (bytes32 h, bytes memory pre) =
            _deriveRoute(address(acct), t, f, w, 1 ether, m, FUTURE);
        bytes32 c = vault.routeCommitment(h, address(acct), t, f, w, 1 ether, m, FUTURE);
        acct.anchorIt(h, c, 0);

        // the reentry the anchor would have to authorise. It carries the route
        // order's preimage because that is the only preimage that hashes to `h`.
        acct.arm(
            address(adapter),
            abi.encodeCall(MorphoSupplyAdapter.supply, (h, _market(), 1 ether, 1 ether, pre))
        );
        evil.arm(address(acct), abi.encodeCall(AgentAccount.onTokenReceived, ()));

        acct.route(h, t, f, w, m, FUTURE, 1 ether, pre);

        assertTrue(acct.fired(), "the cross-executor reentry actually happened");
        assertFalse(acct.succeeded(), "and it was rejected");
        assertFalse(adapter.consumed(address(acct), h), "anchor NOT spent on the adapter");
        assertTrue(vault.consumed(address(acct), h), "only the vault leg consumed it");

        // ...and rejected by the BINDING, not by a guard that happened to be
        // in the way. This is the load-bearing assertion: nonReentrant does
        // not span the two contracts.
        assertEq(
            bytes4(acct.lastReturndata()),
            PQExecBinding.ExecCommitmentMismatch.selector,
            "rejected by the PQ execution binding"
        );

        // The original RT11e claim, asserted against state instead of a
        // selector: the anchor slot for `h` holds a ROUTE commitment, and that
        // is not the commitment the adapter would have required, so
        // `ExecutionNotAnchored` was the very next thing in its path.
        assertEq(anchor.execCommitmentOf(address(acct), h), c, "the one slot holds the route commitment");
        assertTrue(
            c != adapter.supplyCommitment(h, address(acct), _market(), 1 ether),
            "a route commitment can never satisfy the adapter"
        );
    }

    /// NEGATIVE — reentering the SAME executor with the same anchor is caught
    /// by `nonReentrant`, and would be caught by `consumed` anyway (which is
    /// written before any external call).
    function test_RT11f_SameExecutorReentryIsCaughtByTheGuard() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(evil));
        (bytes32 h, bytes memory pre) =
            _deriveRoute(address(acct), t, f, w, 1 ether, m, FUTURE);
        bytes32 c = vault.routeCommitment(h, address(acct), t, f, w, 1 ether, m, FUTURE);
        acct.anchorIt(h, c, 0);

        // The reentry replays the identical call, preimage included, so it is
        // fully PQ-bound and would pass every authorisation check. Only
        // `nonReentrant` stops it — which is exactly what this test asserts.
        acct.arm(
            address(vault),
            abi.encodeCall(UniswapRoutingVault.executeAndRoute, (h, t, f, w, m, FUTURE, pre))
        );
        evil.arm(address(acct), abi.encodeCall(AgentAccount.onTokenReceived, ()));

        acct.route(h, t, f, w, m, FUTURE, 1 ether, pre);
        assertTrue(acct.fired());
        assertFalse(acct.succeeded(), "reentry rejected");
    }
}
