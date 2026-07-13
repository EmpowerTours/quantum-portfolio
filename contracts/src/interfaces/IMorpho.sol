// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Morpho Blue market identifier tuple. The market id is
///         keccak256(abi.encode(MarketParams)).
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Minimal Morpho Blue interface — only what the supply adapter needs.
///         Morpho Blue on Monad mainnet: 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee.
interface IMorpho {
    /// @notice Supply `assets` of the market's loan token, crediting supply
    ///         shares to `onBehalf`. Pass shares=0 to supply an exact asset
    ///         amount. Returns (assetsSupplied, sharesSupplied).
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Per-user position in a market (id = keccak256(abi.encode(params))).
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}
