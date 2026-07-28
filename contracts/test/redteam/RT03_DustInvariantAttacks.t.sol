// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }      from "forge-std/Test.sol";
import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 }     from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { WMON }          from "../../src/dex/WMON.sol";
import { MockToken }     from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";

// ---------------------------------------------------------------------------
// Faithful SwapRouter02 stand-in: payer is msg.sender (never an arbitrary
// address), and amountIn == 0 is the CONTRACT_BALANCE sentinel, exactly like
// the deployed router. Used so reentrancy results here match mainnet.
// ---------------------------------------------------------------------------
contract FaithfulRouter is IV3SwapRouter {
    using SafeERC20 for IERC20;
    uint256 public rateNum = 2000;
    uint256 public rateDen = 1;

    function setRate(uint256 num, uint256 den) external { rateNum = num; rateDen = den; }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        uint256 amountIn = p.amountIn;
        bool alreadyPaid;
        if (amountIn == 0) {                        // Constants.CONTRACT_BALANCE
            alreadyPaid = true;
            amountIn = IERC20(p.tokenIn).balanceOf(address(this));
        }
        if (!alreadyPaid) {
            IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        amountOut = (amountIn * rateNum) / rateDen;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}

/// tokenOut with an ERC-777-style hook fired at the RECIPIENT on transfer.
contract HookToken is ERC20 {
    address public hookTarget;
    bytes   public hookData;
    bool    public armed;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 a) external { _mint(to, a); }

    function arm(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to == hookTarget && from != address(0)) {
            armed = false; // one-shot, avoid infinite recursion
            (bool ok, bytes memory err) = hookTarget.call(hookData);
            if (!ok) {
                assembly { revert(add(err, 0x20), mload(err)) }
            }
        }
    }
}

/// Attacker contract: receives tokenOut, and its hook re-enters the vault.
contract ReenterVault {
    UniswapRoutingVault public vault;
    AuditAnchorV2 public anchor;
    WMON public wmon;
    address public tokenOut;

    constructor(UniswapRoutingVault v, AuditAnchorV2 a, WMON w, address t) {
        vault = v; anchor = a; wmon = w; tokenOut = t;
    }

    receive() external payable {}

    /// Anchor BOTH the outer and the inner (re-entrant) call with fully valid
    /// commitments, so the only thing that can stop the re-entry is the
    /// ReentrancyGuard — not a commitment mismatch and not consumption.
    function prep(bytes32 hOuter, uint256 vOuter, bytes32 hInner, uint256 vInner) external {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _legs();
        anchor.anchor(
            hOuter,
            vault.routeCommitment(address(this), t, f, w, vOuter, m, type(uint256).max),
            anchor.nextSequence(address(this))
        );
        if (hInner != bytes32(0)) {
            anchor.anchor(
                hInner,
                vault.routeCommitment(address(this), t, f, w, vInner, m, type(uint256).max),
                anchor.nextSequence(address(this))
            );
        }
    }

    function go(bytes32 h) external payable {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _legs();
        vault.executeAndRoute{ value: msg.value }(h, t, f, w, m, type(uint256).max);
    }

    /// hook body — re-enter executeAndRoute with a SEPARATE, validly anchored
    /// order. Must still be blocked.
    function reenter(bytes32 h) external {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _legs();
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, type(uint256).max);
    }

    /// hook body — donate 1 wei WMON into the vault mid-call
    function donate() external {
        wmon.transfer(address(vault), 1);
    }

    function _legs()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tokenOut;
        f = new uint24[](1);  f[0] = 3000;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }
}

// --------------------------- Morpho side -----------------------------------

interface IIrmLike { function borrowRate(MarketParams calldata, uint256) external returns (uint256); }

/// Morpho stand-in that reproduces the real accrual order: it calls the
/// CALLER-SUPPLIED irm BEFORE pulling the loan token from msg.sender.
contract AccruingMorpho {
    function supply(MarketParams calldata p, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        if (p.irm != address(0)) IIrmLike(p.irm).borrowRate(p, 0);   // attacker code runs here
        IERC20(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

contract EvilIrm {
    MorphoSupplyAdapter public adapter;
    AccruingMorpho public morpho;
    IERC20 public loan;
    uint8 public mode; // 0 = noop, 1 = reenter adapter, 2 = donate, 3 = spend adapter allowance

    constructor(MorphoSupplyAdapter a, AccruingMorpho m, IERC20 l) {
        adapter = a; morpho = m; loan = l;
    }

    function setMode(uint8 x) external { mode = x; }

    function borrowRate(MarketParams calldata p, uint256) external returns (uint256) {
        uint8 m = mode;
        mode = 0; // one-shot: avoid unbounded self-recursion in the stub
        if (m == 1) {
            adapter.supply(keccak256("evil"), p, 1, 1);
        } else if (m == 2) {
            loan.transfer(address(adapter), 1);
        } else if (m == 3) {
            // adapter has approved MORPHO for `assets`. Try to make MORPHO
            // spend it on our behalf. msg.sender to morpho is US, not the
            // adapter, so this can only ever move OUR tokens.
            loan.approve(address(morpho), type(uint256).max);
            morpho.supply(p, 1, 0, address(this), "");
        }
        return 0;
    }
}

/// RED TEAM — RT-03: attempts to defeat the balance-delta dust invariant
/// (the H-1/H-2 fix) and the M-4 market allowlist, migrated to AuditAnchorV2.
/// Every attack below is a NEGATIVE result unless the test name says otherwise.
contract RT03_DustInvariantAttacks is Test {
    WMON wmon;
    MockToken usdc;
    HookToken hook;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    UniswapRoutingVault vault;

    AccruingMorpho morpho;
    MorphoSupplyAdapter adapter;
    EvilIrm evilIrm;

    address alice   = address(0xA11CE);
    address grief   = address(0x6816F);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        hook = new HookToken();
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(hook);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, tiers
        );

        usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 100_000 ether);
        hook.mint(address(router), 100_000 ether);

        morpho  = new AccruingMorpho();
        address[] memory loans = new address[](1);
        loans[0] = address(usdc);

        // Predict the EvilIrm address so the hostile market can be put on the
        // (M-4) market allowlist. This deliberately models the WORST case for
        // the allowlist: an operator who vets a market whose IRM later turns
        // hostile, or a market that was hostile all along.
        address predictedIrm = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_params(predictedIrm)));
        adapter = new MorphoSupplyAdapter(address(morpho), address(anchor), loans, markets);
        evilIrm = new EvilIrm(adapter, morpho, IERC20(address(usdc)));
        assertEq(address(evilIrm), predictedIrm, "irm address prediction");

        vm.deal(alice, 100 ether);
        vm.deal(grief, 100 ether);
    }

    function _legs(address tok)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tok;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;      // non-zero: ZeroSlippageFloor guard
    }

    function _anchorRoute(address who, bytes32 h, address tok, uint256 amountInWei) internal {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(tok);
        bytes32 c = vault.routeCommitment(who, t, f, w, amountInWei, m, FUTURE);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }

    function _anchorSupply(address who, bytes32 h, address irm, uint256 maxAssets) internal {
        bytes32 c = adapter.supplyCommitment(who, _params(irm), maxAssets);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }

    function _donateWmon(address from, uint256 amt) internal {
        vm.startPrank(from);
        wmon.deposit{ value: amt }();
        wmon.transfer(address(vault), amt);
        vm.stopPrank();
    }

    /// NEGATIVE — the H-1/H-2 fix holds under V2: pre-donated dust no longer
    /// bricks anything, for any donation size, and is not stealable.
    function test_RT03a_PreDonatedDustDoesNotBrickOrLeak(uint96 dust) public {
        vm.assume(dust > 0 && dust < 50 ether);
        _donateWmon(grief, dust);

        bytes32 h = keccak256("h");
        _anchorRoute(alice, h, address(usdc), 1 ether);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        vm.prank(alice);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);

        assertEq(wmon.balanceOf(address(vault)), dust, "dust inert, neither stolen nor blocking");
        assertEq(usdc.balanceOf(alice), 2000 ether, "user got the full swap");
    }

    /// NEGATIVE — a callback tokenOut cannot re-enter executeAndRoute, even
    /// when the re-entrant call carries its OWN fully valid, unconsumed anchor.
    /// This isolates the ReentrancyGuard as the control that stops it.
    function test_RT03b_ReentrancyViaTokenOutHookIsBlocked() public {
        ReenterVault atk = new ReenterVault(vault, anchor, wmon, address(hook));
        vm.deal(address(atk), 10 ether);

        bytes32 hOuter = keccak256("re-outer");
        bytes32 hInner = keccak256("re-inner");
        atk.prep(hOuter, 1 ether, hInner, 1 ether);

        // sanity: the inner order IS validly anchored and unconsumed
        assertTrue(anchor.execCommitmentOf(address(atk), hInner) != bytes32(0));
        assertFalse(vault.consumed(address(atk), hInner));

        hook.arm(address(atk), abi.encodeCall(ReenterVault.reenter, (hInner)));

        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up through the hook
        atk.go{ value: 1 ether }(hOuter);
    }

    /// NEGATIVE (self-DoS only) — a mid-call WMON donation makes the delta
    /// check fire, but the donation can only be triggered by the CALLER's own
    /// tokenOut hook, so it grief-fails the attacker's own transaction. There
    /// is no path for a third party to inject WMON during a victim's call.
    function test_RT03c_MidCallDonationRevertsOnlyTheAttackersOwnTx() public {
        ReenterVault atk = new ReenterVault(vault, anchor, wmon, address(hook));
        vm.deal(address(atk), 10 ether);
        vm.startPrank(grief);
        wmon.deposit{ value: 1 }();
        wmon.transfer(address(atk), 1);
        vm.stopPrank();

        bytes32 h = keccak256("don");
        atk.prep(h, 1 ether, bytes32(0), 0);
        hook.arm(address(atk), abi.encodeCall(ReenterVault.donate, ()));

        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.WMonDustResidual.selector, 1));
        atk.go{ value: 1 ether }(h);

        // A concurrent, unrelated user is unaffected.
        bytes32 h2 = keccak256("clean");
        _anchorRoute(alice, h2, address(usdc), 1 ether);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        vm.prank(alice);
        vault.executeAndRoute{ value: 1 ether }(h2, t, f, w, m, FUTURE);
        assertEq(usdc.balanceOf(alice), 2000 ether);
    }

    /// POSITIVE (informational) — donated WMON is permanently unrecoverable.
    /// The vault has no owner, no sweep, and receive() reverts, so the fix
    /// converts a DoS into an irreversible burn of anything sent here.
    function test_RT03d_DonatedWmonIsPermanentlyLocked() public {
        _donateWmon(grief, 5 ether);
        assertEq(wmon.balanceOf(address(vault)), 5 ether);

        bytes32 h = keccak256("x");
        _anchorRoute(alice, h, address(usdc), 1 ether);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        vm.prank(alice);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
        assertEq(wmon.balanceOf(address(vault)), 5 ether, "still stuck after a full route");

        vm.prank(grief);
        (bool ok, ) = address(vault).call{ value: 1 ether }("");
        assertFalse(ok, "receive() rejects native MON");
    }

    // ------------------------- Morpho adapter --------------------------

    /// NEGATIVE — a caller-supplied malicious `irm` gets code execution inside
    /// MORPHO.supply (M-4), but cannot re-enter the adapter...
    function test_RT03e_EvilIrmCannotReenterAdapter() public {
        evilIrm.setMode(1);
        _supplyExpectRevert();
    }

    /// ...cannot use the adapter's live MORPHO allowance to move adapter funds
    /// (Morpho pulls from ITS msg.sender, which is the irm, not the adapter)...
    function test_RT03f_EvilIrmCannotSpendAdapterAllowance() public {
        evilIrm.setMode(3);
        usdc.faucet(10 ether);
        usdc.transfer(address(evilIrm), 10 ether);

        uint256 adapterBefore = usdc.balanceOf(address(adapter));
        bytes32 h = keccak256("m");
        _anchorSupply(alice, h, address(evilIrm), 1000 ether);

        vm.startPrank(alice);
        usdc.faucet(1000 ether);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.supply(h, _params(address(evilIrm)), 1000 ether, 1000 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(adapter)), adapterBefore, "adapter drained nothing extra");
    }

    /// ...and can only grief its own transaction by donating.
    function test_RT03g_EvilIrmDonationRevertsOnlyItsOwnTx() public {
        evilIrm.setMode(2);
        usdc.faucet(10 ether);
        usdc.transfer(address(evilIrm), 10 ether);
        _supplyExpectRevert();
    }

    /// NEGATIVE — CONFIRMS the M-4 fix. A hostile market that was NOT vetted at
    /// deploy time is rejected. Under V2 the commitment check fires first, so
    /// anchor the hostile market honestly to reach the allowlist guard.
    function test_RT03h_UnvettedHostileMarketIsRejected() public {
        MarketParams memory hostile = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xDEAD),
            oracle: address(0xC0FFEE),
            irm: address(evilIrm),
            lltv: 98e16
        });
        bytes32 id = keccak256(abi.encode(hostile));

        bytes32 h = keccak256("m-hostile");
        bytes32 c = adapter.supplyCommitment(alice, hostile, 1000 ether);
        uint64 _seq = anchor.nextSequence(alice);
        vm.prank(alice);
        anchor.anchor(h, c, _seq);

        vm.startPrank(alice);
        usdc.faucet(1000 ether);
        usdc.approve(address(adapter), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.MarketNotApproved.selector, id)
        );
        adapter.supply(h, hostile, 1000 ether, 1000 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(adapter)), 0, "no tokens pulled before the check");
    }

    function _params(address irm) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0x1),
            oracle: address(0x2),
            irm: irm,
            lltv: 86e16
        });
    }

    function _supplyExpectRevert() internal {
        bytes32 h = keccak256("m");
        _anchorSupply(alice, h, address(evilIrm), 1000 ether);

        vm.startPrank(alice);
        usdc.faucet(1000 ether);
        usdc.approve(address(adapter), type(uint256).max);
        vm.expectRevert();
        adapter.supply(h, _params(address(evilIrm)), 1000 ether, 1000 ether);
        vm.stopPrank();
    }
}
