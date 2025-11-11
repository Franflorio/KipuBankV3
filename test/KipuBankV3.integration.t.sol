// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KipuBankV3, PoolKey, Currency, IHooks, IV4Router} from "../src/KipuBankV3.sol";

/*//////////////////////////////////////////////////////////////
                        MOCK TOKENS
//////////////////////////////////////////////////////////////*/

// USDC 6d simple con mint libre
contract MockUSDC is ERC20("MockUSDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// ERC20 18d genérico con mint libre (lo usamos como "ABC")
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// WETH9 simplificado con deposit/withdraw
contract MockWETH is ERC20("MockWETH", "WETH") {
    receive() external payable {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "eth send fail");
    }
}

/*//////////////////////////////////////////////////////////////
                        MOCK v4 ROUTER
//////////////////////////////////////////////////////////////*/

// Router v4 que:
// - Pullea tokenIn con transferFrom (safe) desde msg.sender (el banco)
// - Entrega USDC al msg.sender (safe)
// - Conversión determinista: amountOut = amountIn / 1e12 (18d -> 6d)
contract MockV4Router is IV4Router {
    using SafeERC20 for IERC20;

    address public immutable USDC;

    constructor(address usdc) { USDC = usdc; }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        address c0 = Currency.unwrap(params.poolKey.currency0);
        address c1 = Currency.unwrap(params.poolKey.currency1);
        address tokenIn  = params.zeroForOne ? c0 : c1;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), uint256(params.amountIn));

        amountOut = uint256(params.amountIn) / 1e12;

        IERC20(USDC).safeTransfer(msg.sender, amountOut);

        require(amountOut >= params.amountOutMinimum, "slippage");
    }
}

/*//////////////////////////////////////////////////////////////
               IMPLEMENTACIÓN MÍNIMA DEL BANCO
//////////////////////////////////////////////////////////////*/

contract KipuBankV3Impl is KipuBankV3 {
    constructor(
        address usdc,
        address weth,
        address ur,
        address permit2,
        address v4router,
        uint256 cap
    ) KipuBankV3(usdc, weth, ur, permit2, v4router, cap) {}
}

/*//////////////////////////////////////////////////////////////
                         TESTS INTEG
//////////////////////////////////////////////////////////////*/

contract KipuBankV3_Integ is Test {
    // Actores
    address user = address(this);

    // Mocks
    MockUSDC  usdc;
    MockWETH  weth;
    MockERC20 abc;          // token arbitrario 18d
    MockV4Router v4;

    // SUT
    KipuBankV3Impl bank;

    function setUp() public {
        // 1) Deploy tokens
        usdc = new MockUSDC();
        weth = new MockWETH();
        abc  = new MockERC20("TokenABC", "ABC");

        // 2) Deploy router v4 mock
        v4   = new MockV4Router(address(usdc));

        // 3) Deploy banco con cap alto
        bank = new KipuBankV3Impl(
            address(usdc),
            address(weth),
            address(0x2), // UR dummy
            address(0x3), // Permit2 dummy
            address(v4),
            10_000_000 * 1e6 // 10M USDC cap
        );

        // 4) Liquidez USDC en router para pagar al banco
        usdc.mint(address(v4), 100_000_000 * 1e6); // 100M USDC

        // 5) Fondos al usuario
        vm.deal(user, 100 ether); // ETH
        abc.mint(user, 1_000_000 * 1e18);
    }

    /* ----------------------------- ETH -> USDC ----------------------------- */

    function test_DepositEthSingleHop_Works() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool zeroForOne = true; // WETH (c0) -> USDC (c1)
        uint128 minOut  = 900_000; // esperamos ~1e6 para 1 ETH, pedimos 0.9e6
        uint256 dl      = block.timestamp + 1 hours;

        uint256 beforeTot  = bank.totalUsdc();

        bank.depositEthSingleHop{value: 1 ether}(key, zeroForOne, minOut, dl);

        assertEq(bank.totalUsdc(), beforeTot + 1_000_000, "totalUsdc debe subir 1e6");
        assertEq(bank.balanceUsdc(user), 1_000_000, "balanceUsdc del user 1e6");
        assertEq(IERC20(address(usdc)).balanceOf(address(bank)), 1_000_000, "USDC en el banco 1e6");
    }

    function test_DepositEthSingleHop_CapExceeded_Reverts() public {
        // Banco con cap chico
        KipuBankV3Impl small = new KipuBankV3Impl(
            address(usdc),
            address(weth),
            address(0x2),
            address(0x3),
            address(v4),
            100 * 1e6 // 100 USDC cap
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool zeroForOne = true;

        // Forzamos revert PRE-swap: minOut > cap (sin importar msg.value)
        uint256 rem = small.remainingCap();           // 100e6
        uint128 minOut = uint128(rem + 1);            // 100e6 + 1
        uint256 dl     = block.timestamp + 1 hours;

        vm.expectRevert(
    abi.encodeWithSelector(
        KipuBankV3.CapExceeded.selector,
        rem,
        uint256(minOut)
    )
    );
        small.depositEthSingleHop{value: 1 ether}(key, zeroForOne, minOut, dl);
    }

    /* ---------------------------- ABC -> USDC ----------------------------- */

    function test_DepositArbitraryToken_Works() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(abc)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool zeroForOne = true; // ABC(c0) -> USDC(c1)
        uint256 amountIn = 5 ether;    // 5e18
        uint128 minOut   = 4_900_000;  // esperamos 5e6; pedimos 4.9e6

        IERC20(address(abc)).approve(address(bank), amountIn);

        uint256 beforeTot = bank.totalUsdc();
        bank.depositArbitraryToken(address(abc), amountIn, key, zeroForOne, minOut, block.timestamp + 1 hours);

        assertEq(bank.balanceUsdc(user), 5_000_000, "user credited 5e6 USDC");
        assertEq(bank.totalUsdc(), beforeTot + 5_000_000, "totalUsdc +5e6");
        assertEq(IERC20(address(usdc)).balanceOf(address(bank)), 5_000_000, "bank holds 5e6 USDC");
    }

    function test_DepositArbitraryToken_CapExceeded_Reverts() public {
        KipuBankV3Impl small = new KipuBankV3Impl(
            address(usdc),
            address(weth),
            address(0x2),
            address(0x3),
            address(v4),
            100 * 1e6 // 100 USDC cap
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(abc)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool zeroForOne = true;
        uint256 amountIn = 1 ether;        // 1e18 -> out 1e6 (pero no queremos llegar al swap)
        uint256 dl       = block.timestamp + 1 hours;

        // Forzamos revert PRE-swap: minOut > cap
        uint256 rem = small.remainingCap();         // 100e6
        uint128 minOut = uint128(rem + 1);          // 100e6 + 1

        IERC20(address(abc)).approve(address(small), amountIn);

        vm.expectRevert(
    abi.encodeWithSelector(
        KipuBankV3.CapExceeded.selector,
        rem,
        uint256(minOut)
    )
);
        small.depositArbitraryToken(address(abc), amountIn, key, zeroForOne, minOut, dl);
    }

    function test_DepositArbitraryToken_KeyDirectionMismatch_Reverts() public {
        // PoolKey USDC/ABC pero decimos zeroForOne=true (USDC->ABC). Nuestro tokenIn será ABC => mismatch.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(abc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool zeroForOne = true; // USDC -> ABC según key
        uint256 amountIn = 1 ether;
        uint128 minOut   = 1;

        IERC20(address(abc)).approve(address(bank), amountIn);

        vm.expectRevert(bytes("key/dir mismatch"));
        bank.depositArbitraryToken(address(abc), amountIn, key, zeroForOne, minOut, block.timestamp + 1 hours);
    }
}
