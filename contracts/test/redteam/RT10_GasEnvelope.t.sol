// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";

/// RED TEAM — RT-10: gas / DoS envelope of the V2 authorisation layer.
///
/// Two questions:
///   1. `routeCommitment` takes `memory` and is invoked from `executeAndRoute`
///      with `calldata` arrays, forcing a full calldata->memory copy plus a
///      second abi.encode of everything. What does the binding actually cost?
///   2. Do the added checks push realistic orders anywhere near Monad
///      mainnet's block gas limit (150_000_000, read from the chain
///      2026-07-28)?
///
/// Answer measured below (against the DOMAIN-SEPARATED commitment, i.e. with
/// `block.chainid` and `address(this)` added to both preimages): the binding
/// costs a few thousand gas at realistic leg counts, and a 32-leg order is
/// still ~0.35% of one block. The per-leg cost is dominated by the swap
/// itself, not the binding. There is no gas-based DoS here and no realistic
/// order that cannot be included.
///
/// The only unbounded-array observation worth recording: the vault imposes no
/// cap on `n`, so an order CAN be anchored that cannot fit in a block. That is
/// self-inflicted only (the caller pays and the anchor rolls back), but it
/// interacts with the L-3 brick: an over-sized commitment, once anchored, is
/// permanently unexecutable for that orderHash. The off-chain pre-flight
/// `src/monad_tx.py:validate_route_execution` does not bound `n` either.
contract RT10_GasEnvelope is Test {
    uint256 constant MONAD_BLOCK_GAS_LIMIT = 150_000_000;

    WMON wmon;
    MockToken usdc;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    UniswapRoutingVault vault;

    address agent = address(0xA6E17);
    uint24 constant FEE = 3000;
    bytes32 constant H0 = bytes32(uint256(0x11));
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();

        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, tiers
        );
        for (uint256 i = 0; i < 20; ++i) usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 1_900_000 ether);
        vm.deal(agent, 10_000 ether);
    }

    function _shape(uint256 n)
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](n); f = new uint24[](n); w = new uint16[](n); m = new uint256[](n);
        uint16 each = uint16(10_000 / n);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(usdc); f[i] = FEE; w[i] = each; m[i] = 1;
        }
        w[n - 1] = uint16(10_000 - each * (n - 1));
    }

    /// The isolated cost of the binding itself: one external `routeCommitment`
    /// call per leg count.
    function test_RT10a_RouteCommitmentCostByLegCount() public {
        uint256[6] memory ns = [uint256(1), 2, 4, 8, 16, 32];
        for (uint256 k = 0; k < ns.length; ++k) {
            (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
                _shape(ns[k]);
            uint256 g0 = gasleft();
            vault.routeCommitment(H0, agent, t, f, w, 1 ether, m, FUTURE);
            uint256 used = g0 - gasleft();
            emit log_named_uint("routeCommitment legs", ns[k]);
            emit log_named_uint("  gas", used);
            assertLt(used, 200_000, "commitment hashing stays trivial");
        }
    }

    /// Full `executeAndRoute` by leg count, against the block gas limit.
    function test_RT10b_ExecuteAndRouteGasEnvelope() public {
        uint256[6] memory ns = [uint256(1), 2, 4, 8, 16, 32];
        for (uint256 k = 0; k < ns.length; ++k) {
            uint256 n = ns[k];
            (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
                _shape(n);
            bytes32 h = keccak256(abi.encode("gas", n));
            bytes32 c = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, FUTURE);
            uint64 s = anchor.nextSequence(agent);
            vm.prank(agent);
            anchor.anchor(h, c, s);

            vm.prank(agent);
            uint256 g0 = gasleft();
            vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
            uint256 used = g0 - gasleft();

            emit log_named_uint("executeAndRoute legs", n);
            emit log_named_uint("  gas", used);
            emit log_named_uint("  % of a 150M Monad block (x100)", (used * 10_000) / MONAD_BLOCK_GAS_LIMIT);
            assertLt(used, MONAD_BLOCK_GAS_LIMIT / 4, "well inside one block even at 32 legs");
        }
    }

    /// The hot path, decomposed: how much of `executeAndRoute` is the binding?
    /// `routeCommitment` is `public view` but is reached from `executeAndRoute`
    /// by an INTERNAL jump (no `this.`), so there is no external-call overhead;
    /// the only structural cost is the calldata->memory copy its `memory`
    /// signature forces, plus one CHAINID and one ADDRESS opcode.
    function test_RT10e_BindingShareOfTheHotPath() public {
        uint256[4] memory ns = [uint256(1), 4, 8, 32];
        for (uint256 k = 0; k < ns.length; ++k) {
            (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
                _shape(ns[k]);

            uint256 g0 = gasleft();
            vault.routeCommitment(H0, agent, t, f, w, 1 ether, m, FUTURE);
            uint256 commitGas = g0 - gasleft();

            bytes32 h = keccak256(abi.encode("share", ns[k]));
            bytes32 c = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, FUTURE);
            uint64 s = anchor.nextSequence(agent);
            vm.prank(agent);
            anchor.anchor(h, c, s);

            vm.prank(agent);
            g0 = gasleft();
            vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
            uint256 total = g0 - gasleft();

            emit log_named_uint("legs", ns[k]);
            emit log_named_uint("  routeCommitment (external, incl. call overhead)", commitGas);
            emit log_named_uint("  executeAndRoute total", total);
            emit log_named_uint("  binding share of total, bps", (commitGas * 10_000) / total);
            assertLt((commitGas * 10_000) / total, 2_000, "binding is <20% of the hot path");
        }
    }

    /// The V2 anchor write itself.
    function test_RT10c_AnchorGas() public {
        uint256 g0 = gasleft();
        vm.prank(agent);
        anchor.anchor(keccak256("g"), keccak256("c"), 0);
        emit log_named_uint("AuditAnchorV2.anchor first write gas", g0 - gasleft());

        g0 = gasleft();
        vm.prank(agent);
        anchor.anchor(keccak256("g2"), keccak256("c2"), 1);
        emit log_named_uint("AuditAnchorV2.anchor warm write gas", g0 - gasleft());
    }

    /// NEGATIVE — no third party can inflate anyone else's gas. The arrays are
    /// entirely caller-supplied and the loop touches only caller-scoped state,
    /// so a large-n order is a cost the submitter alone bears. (RT05c covers
    /// the funding side; this covers the gas side.)
    function test_RT10d_LargeNIsNotAGriefVector() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _shape(64);
        bytes32 h = keccak256("big");
        bytes32 c = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, FUTURE);
        uint64 s = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h, c, s);

        vm.prank(agent);
        uint256 g0 = gasleft();
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
        uint256 used = g0 - gasleft();
        emit log_named_uint("executeAndRoute 64 legs gas", used);
        assertLt(used, MONAD_BLOCK_GAS_LIMIT, "still includable");
    }
}
