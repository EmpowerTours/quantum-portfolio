// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
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

    function _anchorFor(bytes32 oh, MarketParams memory m, uint256 maxAssets) internal {
        bytes32 c = adapter.supplyCommitment(oh, user, m, maxAssets);
        uint64 s = anchor.nextSequence(user);
        vm.prank(user);
        anchor.anchor(oh, c, s);
    }

    // --- ZeroAssets -------------------------------------------------------

    function test_RevertsOnZeroAssets() public {
        bytes32 oh = keccak256("zero-assets");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        vm.expectRevert(MorphoSupplyAdapter.ZeroAssets.selector);
        adapter.supply(oh, m, 0, 1_000);
    }

    /// A zero-asset call must not burn the anchor either.
    function test_ZeroAssetsDoesNotConsumeTheAnchor() public {
        bytes32 oh = keccak256("zero-assets-2");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        vm.expectRevert(MorphoSupplyAdapter.ZeroAssets.selector);
        adapter.supply(oh, m, 0, 1_000);

        assertFalse(adapter.consumed(user, oh), "anchor must survive a rejected call");
        vm.prank(user);
        adapter.supply(oh, m, 500, 1_000);     // still usable
        assertTrue(adapter.consumed(user, oh));
    }

    // --- the maxAssets ceiling -------------------------------------------

    /// The signed order authorises a RANGE (0, max]. Supplying above the
    /// ceiling spends more of the user's balance than they signed for.
    function test_RevertsWhenAssetsExceedTheAuthorisedCeiling() public {
        bytes32 oh = keccak256("over-ceiling");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AssetsExceedAuthorised.selector,
                                   uint256(1_001), uint256(1_000))
        );
        adapter.supply(oh, m, 1_001, 1_000);
    }

    function test_ExactlyTheCeilingIsAllowed() public {
        bytes32 oh = keccak256("at-ceiling");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);
        vm.prank(user);
        assertEq(adapter.supply(oh, m, 1_000, 1_000), 1_000, "max is inclusive");
    }

    function testFuzz_AnythingAboveTheCeilingReverts(uint256 over) public {
        over = bound(over, 1, 400_000);
        bytes32 oh = keccak256("fuzz-ceiling");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AssetsExceedAuthorised.selector,
                                   uint256(1_000 + over), uint256(1_000))
        );
        adapter.supply(oh, m, 1_000 + over, 1_000);
    }

    // --- replay -----------------------------------------------------------

    /// One anchor authorises exactly ONE supply. Without this the same signed
    /// order could be drained repeatedly up to the ceiling each time.
    function test_RevertsOnReplayOfTheSameAnchor() public {
        bytes32 oh = keccak256("replay");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        adapter.supply(oh, m, 400, 1_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.AnchorAlreadyConsumed.selector, oh)
        );
        adapter.supply(oh, m, 400, 1_000);
    }

    /// Replay protection is per (user, orderHash) — a second user's anchor is
    /// unaffected by the first consuming theirs.
    function test_ConsumptionIsPerUser() public {
        address other = address(0xCAFE);
        usdc.transfer(other, 10_000);
        vm.prank(other);
        usdc.approve(address(adapter), type(uint256).max);

        bytes32 oh = keccak256("per-user");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        bytes32 c = adapter.supplyCommitment(oh, other, m, 1_000);
        uint64 sOther = anchor.nextSequence(other);   // hoisted: vm.prank is
        vm.prank(other);                              // consumed by the FIRST call
        anchor.anchor(oh, c, sOther);

        vm.prank(user);
        adapter.supply(oh, m, 500, 1_000);
        vm.prank(other);
        adapter.supply(oh, m, 500, 1_000);     // must still work

        assertTrue(adapter.consumed(user, oh));
        assertTrue(adapter.consumed(other, oh));
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

        bytes32 oh = keccak256("bad-token");
        bytes32 c = iso.supplyCommitment(oh, user, hostile, 1_000);
        uint64 sUser = anchor.nextSequence(user);     // hoisted, same reason
        vm.prank(user);
        anchor.anchor(oh, c, sUser);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.LoanTokenNotApproved.selector, address(rogue))
        );
        iso.supply(oh, hostile, 500, 1_000);
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

        bytes32 oh1 = keccak256("re-outer");
        bytes32 oh2 = keccak256("re-nested");

        bytes32 c1 = reAdapter.supplyCommitment(oh1, user, m, 1_000);
        uint64  s1 = anchor.nextSequence(user);
        vm.prank(user);
        anchor.anchor(oh1, c1, s1);

        // anchored BY the attacker, FOR the attacker
        bytes32 c2 = reAdapter.supplyCommitment(oh2, address(evil), m, 1_000);
        uint64  s2 = anchor.nextSequence(address(evil));
        vm.prank(address(evil));
        anchor.anchor(oh2, c2, s2);

        evil.arm(reAdapter, abi.encodeCall(reAdapter.supply, (oh2, m, 100, 1_000)));

        vm.prank(user);
        reAdapter.supply(oh1, m, 500, 1_000);

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
        bytes32 oh = keccak256("allowance");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);

        vm.prank(user);
        adapter.supply(oh, m, 700, 1_000);

        assertEq(usdc.allowance(address(adapter), address(morpho)), 0,
            "adapter must leave no standing allowance to Morpho");
    }

    function test_NoLoanTokenIsLeftInTheAdapter() public {
        bytes32 oh = keccak256("no-dust");
        MarketParams memory m = _market(address(usdc));
        _anchorFor(oh, m, 1_000);
        vm.prank(user);
        adapter.supply(oh, m, 700, 1_000);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }
}
