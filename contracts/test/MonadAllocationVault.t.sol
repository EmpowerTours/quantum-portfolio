// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MonadAllocationVault } from "../src/MonadAllocationVault.sol";

contract MonadAllocationVaultTest is Test {
    MonadAllocationVault vault;

    address alice = address(0xAAAA);
    address bob   = address(0xBBBB);

    bytes32 constant ORDER_1 = bytes32(uint256(0xC0FFEE01));
    bytes32 constant ORDER_2 = bytes32(uint256(0xC0FFEE02));

    bytes32[] pools3;
    uint16[]  weights3;

    function setUp() public {
        vault = new MonadAllocationVault();
        // Three Monad pool labels, equal-weighted (matches our QPU output).
        pools3 = new bytes32[](3);
        pools3[0] = keccak256("Morpho STEAKETH (Monad)");
        pools3[1] = keccak256("Neverland USDC (Monad)");
        pools3[2] = keccak256("shMONAD (Monad)");
        weights3 = new uint16[](3);
        weights3[0] = 3334;
        weights3[1] = 3333;
        weights3[2] = 3333;
        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
    }

    /// Happy path: alice executes with 1 MON, vault holds it, event fires.
    function test_ExecuteRecordsAllocationAndEmitsEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        vault.execute{value: 1 ether}(ORDER_1, pools3, weights3);

        assertEq(vault.deposits(alice, ORDER_1), 1 ether);
        assertEq(vault.totalDeposited(alice),     1 ether);
        assertEq(vault.totalLocked(),             1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0],
                 keccak256("Allocated(address,bytes32,uint256,bytes32[],uint16[])"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(logs[0].topics[2], ORDER_1);
    }

    function test_RevertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(MonadAllocationVault.ZeroValue.selector);
        vault.execute{value: 0}(ORDER_1, pools3, weights3);
    }

    function test_RevertsOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert(MonadAllocationVault.ZeroHash.selector);
        vault.execute{value: 1 ether}(bytes32(0), pools3, weights3);
    }

    function test_RevertsOnLengthMismatch() public {
        uint16[] memory shortWeights = new uint16[](2);
        shortWeights[0] = 5000;
        shortWeights[1] = 5000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            MonadAllocationVault.LengthMismatch.selector,
            uint256(3), uint256(2)
        ));
        vault.execute{value: 1 ether}(ORDER_1, pools3, shortWeights);
    }

    function test_RevertsOnWeightsNot10000() public {
        uint16[] memory badWeights = new uint16[](3);
        badWeights[0] = 5000;
        badWeights[1] = 5000;
        badWeights[2] = 5000;   // sums to 15000
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            MonadAllocationVault.WeightsDoNotSumTo10000.selector,
            uint256(15_000)
        ));
        vault.execute{value: 1 ether}(ORDER_1, pools3, badWeights);
    }

    /// User can withdraw their own deposit, can't take more than they put in.
    function test_WithdrawHappyPath() public {
        vm.prank(alice);
        vault.execute{value: 2 ether}(ORDER_1, pools3, weights3);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(ORDER_1, 0.5 ether);
        assertEq(alice.balance - balanceBefore, 0.5 ether);
        assertEq(vault.deposits(alice, ORDER_1), 1.5 ether);
        assertEq(vault.totalWithdrawn(alice),    0.5 ether);
        assertEq(vault.totalLocked(),            1.5 ether);
    }

    function test_WithdrawRevertsOnInsufficient() public {
        vm.prank(alice);
        vault.execute{value: 1 ether}(ORDER_1, pools3, weights3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            MonadAllocationVault.InsufficientDeposit.selector,
            uint256(2 ether), uint256(1 ether)
        ));
        vault.withdraw(ORDER_1, 2 ether);
    }

    /// Per-user / per-orderHash deposit isolation. The withdraw API only
    /// takes an orderHash (slots are keyed by msg.sender), so the
    /// isolation is structural: there is no syntax for bob to express
    /// "withdraw from alice's slot". We verify it by showing bob's
    /// withdrawal touches only his own balance and alice's is untouched.
    function test_DepositsAreIsolatedBetweenUsers() public {
        vm.prank(alice);
        vault.execute{value: 1 ether}(ORDER_1, pools3, weights3);
        vm.prank(bob);
        vault.execute{value: 3 ether}(ORDER_1, pools3, weights3);

        assertEq(vault.deposits(alice, ORDER_1), 1 ether);
        assertEq(vault.deposits(bob,   ORDER_1), 3 ether);
        assertEq(vault.totalLocked(),            4 ether);

        vm.prank(bob);
        vault.withdraw(ORDER_1, 2 ether);
        assertEq(vault.deposits(bob,   ORDER_1), 1 ether);
        assertEq(vault.deposits(alice, ORDER_1), 1 ether);  // unchanged
        assertEq(vault.totalLocked(),            2 ether);
    }

    /// Same user, two different orders, two independent slots.
    function test_DepositsAreIsolatedBetweenOrders() public {
        vm.prank(alice);
        vault.execute{value: 1 ether}(ORDER_1, pools3, weights3);
        vm.prank(alice);
        vault.execute{value: 2 ether}(ORDER_2, pools3, weights3);

        assertEq(vault.deposits(alice, ORDER_1), 1 ether);
        assertEq(vault.deposits(alice, ORDER_2), 2 ether);
        assertEq(vault.totalDeposited(alice),    3 ether);
    }

    /// Naked send to the vault must revert (no orderless deposits).
    function test_RevertsOnNakedSend() public {
        vm.prank(alice);
        vm.expectRevert(MonadAllocationVault.ZeroHash.selector);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        ok;  // silence unused-var
    }

    /// Reentrancy: a malicious withdraw target can't drain.
    function test_NoReentrancyOnWithdraw() public {
        ReentrantAttacker attacker = new ReentrantAttacker(vault);
        vm.deal(address(attacker), 10 ether);

        attacker.deposit{value: 5 ether}(ORDER_1, pools3, weights3);
        assertEq(vault.deposits(address(attacker), ORDER_1), 5 ether);

        // Single withdraw call. The attacker tries to re-enter; the CEI
        // pattern (state updated before .call) makes the re-entry's
        // `deposits[attacker][ORDER_1] - amount` underflow and revert.
        vm.expectRevert();
        attacker.attack(ORDER_1, 5 ether);
    }

    function test_GasUnderBudget() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        vault.execute{value: 1 ether}(ORDER_1, pools3, weights3);
        uint256 used = g0 - gasleft();
        emit log_named_uint("first execute gas", used);
        assertLt(used, 200_000, "first execute over 200K gas");

        vm.prank(alice);
        g0 = gasleft();
        vault.execute{value: 1 ether}(ORDER_2, pools3, weights3);
        used = g0 - gasleft();
        emit log_named_uint("warm execute gas", used);
        assertLt(used, 150_000, "warm execute over 150K gas");
    }

    /// Fuzz the deposit/withdraw invariant: per-user balance never
    /// exceeds totalDeposited - totalWithdrawn.
    function testFuzz_DepositWithdrawInvariant(uint96 dep, uint96 wd, bytes32 oh) public {
        vm.assume(dep > 0 && wd > 0);
        vm.assume(oh != bytes32(0));
        vm.assume(wd <= dep);

        vm.deal(alice, uint256(dep));
        vm.prank(alice);
        vault.execute{value: dep}(oh, pools3, weights3);
        vm.prank(alice);
        vault.withdraw(oh, wd);

        assertEq(vault.deposits(alice, oh), uint256(dep) - uint256(wd));
        assertEq(vault.totalLocked(),       uint256(dep) - uint256(wd));
    }
}

/// Test helper: attempts to re-enter the vault during withdraw.
contract ReentrantAttacker {
    MonadAllocationVault public immutable vault;
    bytes32 public targetHash;
    uint256 public targetAmount;
    bool public reentered;

    constructor(MonadAllocationVault _vault) {
        vault = _vault;
    }

    function deposit(bytes32 oh, bytes32[] calldata pools, uint16[] calldata weights) external payable {
        vault.execute{value: msg.value}(oh, pools, weights);
    }

    function attack(bytes32 oh, uint256 amount) external {
        targetHash = oh;
        targetAmount = amount;
        vault.withdraw(oh, amount);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            // Try to re-enter; CEI ordering should make this revert.
            vault.withdraw(targetHash, targetAmount);
        }
    }
}
