// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

// ===== Mock USDC (6 decimales) =====
contract MockUSDC is ERC20("MockUSDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ===== Implementación mínima: ya no se necesitan overrides =====
contract KipuBankV3Impl is KipuBankV3 {
    constructor(address usdc, uint256 cap)
        KipuBankV3(
            usdc,
            address(0x1), // WETH dummy
            address(0x2), // UR dummy
            address(0x3), // Permit2 dummy
            address(0x4), // v4Router dummy
            cap
        )
    {}
}

contract KipuBankV3_Unit is Test {
    MockUSDC usdc;
    KipuBankV3Impl bank;

    address user = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        bank = new KipuBankV3Impl(address(usdc), 1_000_000 * 1e6); // cap 1M USDC
        usdc.mint(user, 1_000_000 * 1e6);
    }

    function test_DepositUsdc_Ok() public {
        uint256 amt = 50_000 * 1e6;
        IERC20(address(usdc)).approve(address(bank), amt);
        bank.depositUsdc(amt);

        assertEq(bank.balanceUsdc(user), amt);
        assertEq(bank.totalUsdc(), amt);
        assertEq(IERC20(address(usdc)).balanceOf(address(bank)), amt);
    }

    function test_WithdrawUsdc_Ok() public {
        uint256 depositAmt = 25_000 * 1e6;
        IERC20(address(usdc)).approve(address(bank), depositAmt);
        bank.depositUsdc(depositAmt);

        uint256 withdrawAmt = 10_000 * 1e6;
        uint256 userAfterDeposit = IERC20(address(usdc)).balanceOf(user);

        bank.withdrawUsdc(withdrawAmt);

        assertEq(bank.balanceUsdc(user), depositAmt - withdrawAmt);
        assertEq(bank.totalUsdc(), depositAmt - withdrawAmt);
        assertEq(IERC20(address(usdc)).balanceOf(user), userAfterDeposit + withdrawAmt);
    }

    function test_DepositUsdc_ZeroAmount_Revert() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUsdc(0);
    }

    function test_WithdrawUsdc_Insufficient_Revert() public {
        uint256 available = bank.balanceUsdc(user); // 0
        uint256 requested = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.InsufficientBalance.selector,
                available,
                requested
            )
        );
        bank.withdrawUsdc(requested);
    }

    function test_DepositUsdc_CapExceeded_Revert() public {
        uint256 cap = 100 * 1e6;
        KipuBankV3Impl smallCap = new KipuBankV3Impl(address(usdc), cap);
        uint256 attempted = 200 * 1e6;

        usdc.mint(address(this), attempted);
        IERC20(address(usdc)).approve(address(smallCap), attempted);

        uint256 remaining = smallCap.remainingCap(); // == cap

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.CapExceeded.selector,
                remaining,
                attempted
            )
        );
        smallCap.depositUsdc(attempted);
    }
}
