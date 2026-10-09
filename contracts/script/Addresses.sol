// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain mainnet (chainId 4663) addresses. Mirror of config/chains.ts — every value has a source:
///   Tokens:  https://docs.robinhood.com/chain/contracts/  +  https://api.robinhood.com/rhj/assets (official registry)
///   Feeds:   https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
///   Uniswap: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
/// Re-verified on-chain 2026-10-08 (decimals/symbol/pool balances).
library RobinhoodMainnet {
    uint256 internal constant CHAIN_ID = 4663;

    // stablecoin base asset (Paxos Global Dollar, 6 decimals)
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // risk-on basket (Robinhood Stock Tokens, 18 decimals)
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_USD_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant QQQ_USD_FEED = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;

    // risk-off sleeve
    address internal constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e; // SPDR Gold Trust token
    address internal constant GLD_USD_FEED = 0x470A51258068043bd43dC0a56245625C9fE86eB0;
    address internal constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5; // iShares 0-3M Treasury token
    address internal constant SGOV_USD_FEED = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11;

    // Uniswap v3
    address internal constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 internal constant SPY_POOL_FEE = 500; // deepest SPY/USDG pool (~$200k USDG, 2026-10-08)
    uint24 internal constant QQQ_POOL_FEE = 500; // ~$626k USDG
    uint24 internal constant GLD_POOL_FEE = 3000; // ~$438k USDG
    uint24 internal constant SGOV_POOL_FEE = 3000; // ~$1.29M USDG

    // No Chainlink L2 sequencer uptime feed is published for Robinhood Chain (documented gap).
    address internal constant SEQUENCER_UPTIME_FEED = address(0);

    string internal constant BLOCKSCOUT_API = "https://robinhoodchain.blockscout.com/api/";
}
