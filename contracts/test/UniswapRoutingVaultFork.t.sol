// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }  from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AuditAnchor }         from "../src/AuditAnchor.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";

/// @notice Opt-in integration test against the REAL Uniswap v3 SwapRouter02
///         on a Monad-mainnet fork. Proves the vault routes native MON into
///         a live DeFi token through production liquidity — the whole point
///         of the MiniAMM -> real-DEX migration.
///
///         Skips cleanly (no failure) unless the operator provides:
///           MONAD_RPC_URL   an archive/full RPC for Monad mainnet
///           FORK_TOKEN_OUT  a token with a live WMON/token v3 pool
///           FORK_FEE        that pool's fee tier (500 / 3000 / 10000)
///
///     Run it:
///       MONAD_RPC_URL=https://rpc.monad.xyz \
///       FORK_TOKEN_OUT=0x... FORK_FEE=3000 \
///       forge test --match-contract UniswapRoutingVaultForkTest -vvv
contract UniswapRoutingVaultForkTest is Test {
    address constant WMON   = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;

    AuditAnchor anchor;
    UniswapRoutingVault vault;
    address tokenOut;
    uint24 fee;
    address trader = address(0xBEEF);

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // fork params absent -> test self-skips

        vm.createSelectFork(rpc);
        require(block.chainid == 143, "fork is not Monad mainnet");

        tokenOut = vm.envAddress("FORK_TOKEN_OUT");
        fee = uint24(vm.envUint("FORK_FEE"));

        anchor = new AuditAnchor();
        address[] memory approved = new address[](1);
        approved[0] = tokenOut;
        vault = new UniswapRoutingVault(WMON, ROUTER, address(anchor), approved);

        vm.deal(trader, 10 ether);
    }

    function test_RoutesNativeMonThroughLiveUniswapPool() public {
        if (address(vault) == address(0)) {
            emit log("SKIP: set MONAD_RPC_URL / FORK_TOKEN_OUT / FORK_FEE to run the fork test");
            return;
        }

        bytes32 orderHash = keccak256("fork-live-swap");
        vm.prank(trader);
        anchor.anchor(orderHash);

        address[] memory t = new address[](1); t[0] = tokenOut;
        uint24[]  memory f = new uint24[](1);  f[0] = fee;
        uint16[]  memory w = new uint16[](1);  w[0] = 10_000;
        uint256[] memory m = new uint256[](1); m[0] = 1; // accept anything > 0 for the smoke test

        uint256 before = IERC20(tokenOut).balanceOf(trader);
        vm.prank(trader);
        vault.executeAndRoute{value: 0.1 ether}(
            orderHash, t, f, w, m, block.timestamp + 300
        );
        uint256 received = IERC20(tokenOut).balanceOf(trader) - before;

        assertGt(received, 0, "trader received no tokenOut from the live pool");
        assertEq(IERC20(WMON).balanceOf(address(vault)), 0, "vault retained WMON dust");
        emit log_named_uint("tokenOut received (0.1 MON in)", received);
    }
}
