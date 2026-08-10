// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PQBind } from "./helpers/PQBind.sol";
import { MockPQAttestation } from "./mocks/MockPQAttestation.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../src/AuditAnchorV2.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";
import { MarketParams } from "../src/interfaces/IMorpho.sol";

/// Minimal Morpho stand-in: pulls exactly `assets`, credits shares 1:1.
contract PlainMorpho {
    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        MockToken(params.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

/// Morpho stand-in that calls BACK into the adapter mid-supply. Used to prove
/// `nonReentrant` is load-bearing rather than decorative.
contract ReentrantMorpho {
    MorphoSupplyAdapter public adapter;
    bytes public payload;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public lastReturndata;

    function arm(MorphoSupplyAdapter a, bytes calldata p) external {
        adapter = a;
        payload = p;
    }

    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        MockToken(params.loanToken).transferFrom(msg.sender, address(this), assets);
        if (!reentered && address(adapter) != address(0)) {
            reentered = true;
            (bool ok, bytes memory ret) = address(adapter).call(payload);
            reentrySucceeded = ok;
            lastReturndata = ret;
        }
        return (assets, assets);
    }
}

/// @notice Guard-level tests for MorphoSupplyAdapter.
///
/// @dev    A mutation sweep deleted each of these guards in turn and the whole
///         135-test suite still passed: `nonReentrant`, the `consumed` replay
///         check, the `assets > maxAssets` ceiling, the approved-loan-token
///         check, `ZeroAssets`, and the post-supply `forceApprove(MORPHO, 0)`.
///         `AssetsExceedAuthorised`, `LoanTokenNotApproved` and `ZeroAssets`
///         appeared in ZERO test files. The adapter was correct; nothing would
///         have caught a regression.
///
///         Every negative assertion names the exact selector.
contract MorphoSupplyAdapterGuardsTest is Test {
    AuditAnchorV2 anchor;
    PlainMorpho morpho;
    MorphoSupplyAdapter adapter;
    MockToken usdc;
    MockToken wbtc;
    MockToken rogue;          // real ERC-20, deliberately NOT allowlisted

    address user = address(0xBEEF);

    uint256 constant LLTV = 86e16;
    address constant ORACLE = address(0x00000000000000000000000000000000000000A1);
    address constant IRM    = address(0x00000000000000000000000000000000000000b2);

    function setUp() public {
        anchor = new AuditAnchorV2();
        morpho = new PlainMorpho();
        usdc  = new MockToken("USDC", "USDC", 6);
        wbtc  = new MockToken("WBTC", "WBTC", 8);
        rogue = new MockToken("ROGUE", "RGE", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market(address(usdc))));

        adapter = new MorphoSupplyAdapter(address(morpho), address(anchor), address(new MockPQAttestation()), tokens, markets);

        usdc.faucet(1_000_000);
        usdc.transfer(user, 500_000);
        vm.prank(user);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function _market(address loan) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: loan, collateralToken: address(0x00000000000000000000000000000000000000C3),
            oracle: ORACLE, irm: IRM, lltv: LLTV
        });
    }

    /// Derives the orderHash instead of taking one: the adapter now requires
    /// bytes that hash to it AND carry the matching exec_commitment.
    function _anchorFor(MarketParams memory m, uint256 maxAssets)
        internal returns (bytes32 oh, bytes memory pre)
    {
        (oh, pre) = _bindSupply(m, maxAssets);
        bytes32 c = adapter.supplyCommitment(oh, user, m, maxAssets);
        uint64 s = anchor.nextSequence(user);
        vm.prank(user);
        anchor.anchor(oh, c, s);
    }

    /// Same derivation, without anchoring.
    function _bindSupply(MarketParams memory m, uint256 maxAssets)
        internal view returns (bytes32 oh, bytes memory pre)
    {
        bytes32 paramsHash = keccak256(abi.encode(
            block.chainid, address(adapter), user, m.loanToken, m.collateralToken,
            m.oracle, m.irm, m.lltv, maxAssets
        ));
        (pre, oh) = PQBind.preimage(paramsHash);
    }

    // --- ZeroAssets -------------------------------------------------------

    function test_RevertsOnZeroAssets() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        vm.expectRevert(MorphoSupplyAdapter.ZeroAssets.selector);
        adapter.supply(oh, m, 0, 1_000, oh_pre);
    }

    /// A zero-asset call must not burn the anchor either.
    function test_ZeroAssetsDoesNotConsumeTheAnchor() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        vm.expectRevert(MorphoSupplyAdapter.ZeroAssets.selector);
        adapter.supply(oh, m, 0, 1_000, oh_pre);

        assertFalse(adapter.consumed(user, oh), "anchor must survive a rejected call");
        vm.prank(user);
        adapter.supply(oh, m, 500, 1_000, oh_pre);     // still usable
        assertTrue(adapter.consumed(user, oh));
    }

    // --- the maxAssets ceiling -------------------------------------------

    /// The signed order authorises a RANGE (0, max]. Supplying above the
    /// ceiling spends more of the user's balance than they signed for.
    function test_RevertsWhenAssetsExceedTheAuthorisedCeiling() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AssetsExceedAuthorised.selector,
                                   uint256(1_001), uint256(1_000))
        );
        adapter.supply(oh, m, 1_001, 1_000, oh_pre);
    }

    function test_ExactlyTheCeilingIsAllowed() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);
        vm.prank(user);
        assertEq(adapter.supply(oh, m, 1_000, 1_000, oh_pre), 1_000, "max is inclusive");
    }

    function testFuzz_AnythingAboveTheCeilingReverts(uint256 over) public {
        over = bound(over, 1, 400_000);
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AssetsExceedAuthorised.selector,
                                   uint256(1_000 + over), uint256(1_000))
        );
        adapter.supply(oh, m, 1_000 + over, 1_000, oh_pre);
    }

    // --- replay -----------------------------------------------------------

    /// One anchor authorises exactly ONE supply. Without this the same signed
    /// order could be drained repeatedly up to the ceiling each time.
    function test_RevertsOnReplayOfTheSameAnchor() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        adapter.supply(oh, m, 400, 1_000, oh_pre);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AnchorAlreadyConsumed.selector, oh)
        );
        adapter.supply(oh, m, 400, 1_000, oh_pre);
    }

    /// Replay protection is per (user, orderHash) — a second user's anchor is
    /// unaffected by the first consuming theirs.
    /// `consumed` is keyed per (user, orderHash). It used to be provable by
    /// having two users spend ONE orderHash; that is no longer expressible,
    /// because `msg.sender` is inside the signed exec_commitment, so an order
    /// naming one user cannot be executed by another — a strictly stronger
    /// property, asserted here as well. Each user therefore gets their own
    /// derived order, and the claim becomes: one user consuming theirs leaves
    /// the other's slot untouched.
    function test_ConsumptionIsPerUser() public {
        address other = address(0xCAFE);
        usdc.transfer(other, 10_000);
        vm.prank(other);
        usdc.approve(address(adapter), type(uint256).max);
        MarketParams memory m = _market(address(usdc));

        (bytes32 ohUser, bytes memory preUser) = _anchorFor(m, 1_000);

        (bytes memory preOther, bytes32 ohOther) = PQBind.preimage(keccak256(abi.encode(
            block.chainid, address(adapter), other, m.loanToken, m.collateralToken,
            m.oracle, m.irm, m.lltv, uint256(1_000)
        )));
        bytes32 c = adapter.supplyCommitment(ohOther, other, m, 1_000);
        uint64 sOther = anchor.nextSequence(other);   // hoisted: vm.prank is
        vm.prank(other);                              // consumed by the FIRST call
        anchor.anchor(ohOther, c, sOther);

        assertTrue(ohUser != ohOther, "an order names its user, so the hashes differ");

        vm.prank(user);
        adapter.supply(ohUser, m, 500, 1_000, preUser);
        assertTrue(adapter.consumed(user, ohUser));
        assertFalse(adapter.consumed(other, ohOther), "the other user's slot is untouched");

        vm.prank(other);
        adapter.supply(ohOther, m, 500, 1_000, preOther);   // must still work
        assertTrue(adapter.consumed(other, ohOther));

        // The stronger property the binding now gives for free: `other` cannot
        // execute the order that names `user`, even holding its preimage.
        vm.prank(other);
        vm.expectRevert();
        adapter.supply(ohUser, m, 500, 1_000, preUser);
    }


    // --- loan-token allowlist ---------------------------------------------

    /// The market id pins the loan token, but the explicit allowlist is a
    /// second, independent gate. Deleting it left every test green.
    function test_RevertsOnUnapprovedLoanToken() public {
        MarketParams memory hostile = _market(address(rogue));
        bytes32 id = keccak256(abi.encode(hostile));

        // Deploy an adapter that approves the hostile MARKET but not its TOKEN,
        // isolating the loan-token guard from the market guard.
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);              // rogue deliberately absent
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = id;
        MorphoSupplyAdapter iso =
            new MorphoSupplyAdapter(address(morpho), address(anchor), address(new MockPQAttestation()), tokens, markets);

        rogue.faucet(10_000);
        rogue.transfer(user, 5_000);
        vm.prank(user);
        rogue.approve(address(iso), type(uint256).max);
        // Bound to `iso`, not the default adapter: the params hash names the
        // executor, so a preimage built for one is inert at the other.
        bytes32 paramsHash = keccak256(abi.encode(
            block.chainid, address(iso), user, hostile.loanToken,
            hostile.collateralToken, hostile.oracle, hostile.irm,
            hostile.lltv, uint256(1_000)
        ));
        (bytes memory oh_pre, bytes32 oh) = PQBind.preimage(paramsHash);
        bytes32 c = iso.supplyCommitment(oh, user, hostile, 1_000);
        uint64 sUser = anchor.nextSequence(user);     // hoisted, same reason
        vm.prank(user);
        anchor.anchor(oh, c, sUser);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.LoanTokenNotApproved.selector, address(rogue))
        );
        iso.supply(oh, hostile, 500, 1_000, oh_pre);
    }

    // --- reentrancy -------------------------------------------------------

    /// Morpho is an external call made while the adapter holds pulled funds.
    /// A malicious or compromised market re-entering must be refused.
    ///
    /// The nested call must be VALID in every respect except its nestedness —
    /// otherwise it dies on the binding and `nonReentrant` is never reached,
    /// and the test passes for the wrong reason. So the attacker anchors its
    /// OWN order, funds itself, and approves the adapter: the only thing left
    /// that can stop it is the reentrancy guard.
    function test_ReentrantSupplyIsRefused() public {
        ReentrantMorpho evil = new ReentrantMorpho();
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        MarketParams memory m = _market(address(usdc));
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(m));
        MorphoSupplyAdapter reAdapter =
            new MorphoSupplyAdapter(address(evil), address(anchor), address(new MockPQAttestation()), tokens, markets);

        usdc.transfer(user, 10_000);
        vm.prank(user);
        usdc.approve(address(reAdapter), type(uint256).max);

        // Fund and authorise the ATTACKER so its nested call is otherwise legal.
        usdc.transfer(address(evil), 10_000);
        vm.prank(address(evil));
        usdc.approve(address(reAdapter), type(uint256).max);

        // Derived, not invented: the outer call must satisfy the binding so the
        // re-entrancy guard is genuinely what refuses the nested one. Bound to
        // reAdapter and to each caller, which also keeps the two hashes
        // distinct without needing a literal.
        (bytes memory oh1_pre, bytes32 oh1) = PQBind.preimage(keccak256(abi.encode(
            block.chainid, address(reAdapter), user, m.loanToken, m.collateralToken,
            m.oracle, m.irm, m.lltv, uint256(1_000)
        )));
        (, bytes32 oh2) = PQBind.preimage(keccak256(abi.encode(
            block.chainid, address(reAdapter), address(evil), m.loanToken,
            m.collateralToken, m.oracle, m.irm, m.lltv, uint256(1_000)
        )));

        bytes32 c1 = reAdapter.supplyCommitment(oh1, user, m, 1_000);
        uint64  s1 = anchor.nextSequence(user);
        vm.prank(user);
        anchor.anchor(oh1, c1, s1);

        // anchored BY the attacker, FOR the attacker
        bytes32 c2 = reAdapter.supplyCommitment(oh2, address(evil), m, 1_000);
        uint64  s2 = anchor.nextSequence(address(evil));
        vm.prank(address(evil));
        anchor.anchor(oh2, c2, s2);

        // The nested call is refused by nonReentrant before any binding check,
        // so it deliberately carries no preimage — if that ever starts
        // mattering, the guard order has changed.
        evil.arm(reAdapter, abi.encodeCall(reAdapter.supply, (oh2, m, 100, 1_000, "")));

        vm.prank(user);
        reAdapter.supply(oh1, m, 500, 1_000, oh1_pre);

        assertTrue(evil.reentered(), "precondition: the mock actually re-entered");
        assertFalse(evil.reentrySucceeded(), "nonReentrant must refuse the nested call");
        assertEq(
            evil.lastReturndata(),
            abi.encodeWithSignature("ReentrancyGuardReentrantCall()"),
            "and it must fail BECAUSE of the guard, not because of the binding"
        );
        assertFalse(reAdapter.consumed(address(evil), oh2),
            "the attacker's own anchor must remain unconsumed");
    }

    // --- allowance hygiene ------------------------------------------------

    /// The post-supply `forceApprove(MORPHO, 0)` survived mutation. A lingering
    /// allowance would let the market pull again later, outside any anchor.
    function test_AllowanceToMorphoIsResetToZeroAfterSupply() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);

        vm.prank(user);
        adapter.supply(oh, m, 700, 1_000, oh_pre);

        assertEq(usdc.allowance(address(adapter), address(morpho)), 0,
            "adapter must leave no standing allowance to Morpho");
    }

    function test_NoLoanTokenIsLeftInTheAdapter() public {
        MarketParams memory m = _market(address(usdc));
        (bytes32 oh, bytes memory oh_pre) = _anchorFor(m, 1_000);
        vm.prank(user);
        adapter.supply(oh, m, 700, 1_000, oh_pre);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }
}
