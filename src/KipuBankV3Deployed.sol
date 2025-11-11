// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KipuBankV3} from "./KipuBankV3.sol";

contract KipuBankV3Deployed is KipuBankV3 {
    constructor(
        address usdc,
        address weth,
        address universalRouter,
        address permit2,
        address v4Router,
        uint256 bankCapUsdc6d
    )
        KipuBankV3(usdc, weth, universalRouter, permit2, v4Router, bankCapUsdc6d)
    {}
}
