// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * KipuBankV3 — versión completa para TP4
 * - Ownable + Pausable + ReentrancyGuard
 * - Banca en USDC (6d)
 * - Swaps single-hop (v4): ERC20->USDC y ETH->USDC (vía WETH) con PoolKey/Currency
 * - Universal Router: depósitos multi-hop (ETH y ERC20) vía commands/inputs
 * - Permit2: interfaz y flujo básico transferFrom (allowance previa)
 * - Oráculos de Chainlink: seteo de feeds y consultas (preserva V2)
 * - Seguridad: SafeERC20 (OZ v5), allowances efímeras, rechazo FoT, deadlines, cap
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ===== Uniswap v4: tipos mínimos requeridos por la consigna =====
type Currency is address;
interface IHooks {}

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    IHooks   hooks; // address(0) si no hay hooks
}

interface IV4Router {
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool    zeroForOne;        // true: currency0->currency1 ; false: currency1->currency0
        uint128 amountIn;
        uint128 amountOutMinimum;  // slippage guard
        bytes   hookData;          // vacío si no hay hooks
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

// ===== Universal Router (multi-hop) =====
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

// ===== Permit2 (mejora UX de approvals): flujo básico sin firma in-line =====
interface IPermit2 {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

// ===== WETH9 mínimo =====
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// ===== Chainlink AggregatorV3 =====
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
/// @title KipuBankV3
/// @author Francisco Florio
/// @notice Banco custodio en USDC con depósitos generalizados (ETH/ERC20) y ruteo vía Uniswap.
/// @dev Incluye UR + tipos V4 (PoolKey/Currency), Permit2 y oráculos Chainlink.
/// @custom:repo https://github.com/franflorio/KipuBankV3
/// @custom:security-contact floriofrancs@gmail.com

abstract contract KipuBankV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- inmutables / config ---
    address public immutable USDC;   // 6 decimales
    address public immutable WETH;   // wrapped native
    IUniversalRouter public immutable UR;
    IPermit2 public immutable PERMIT2;
    IV4Router public immutable V4_ROUTER; // puede ser address(0) si no se usa

    // --- banca en USDC (6d) ---
    uint256 public bankCap;
    uint256 public totalUsdc;
    mapping(address => uint256) public balanceUsdc;

    // --- oráculos (preservado de V2) ---
    mapping(address => AggregatorV3Interface) public priceFeeds; // token => feed
    event PriceFeedSet(address indexed token, address indexed feed);

    // --- eventos banca ---
    event BankCapUpdated(uint256 newCapUsdc6d);
    event DepositedUSDC(address indexed user, uint256 amountUsdc6d, uint256 newUserBal, uint256 newTotal);
    event DepositedETH(address indexed user, uint256 ethInWei, uint256 usdcOut6d, uint256 newUserBal, uint256 newTotal);
    event DepositedToken(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcOut6d, uint256 newUserBal, uint256 newTotal);
    event WithdrawnUSDC(address indexed user, uint256 amountUsdc6d, uint256 newUserBal, uint256 newTotal);

    // --- errores ---
    error NotImplemented();
    error ZeroAmount();
    error CapExceeded(uint256 remainingUsdc6d, uint256 attemptedUsdc6d);
    error UnsupportedToken(address token);
    error TokenIsUSDC();
    error SwapFailed();
    error DeadlineExpired();
    error InsufficientBalance(uint256 availableUsdc6d, uint256 requestedUsdc6d);
    error NoPriceFeed(address token);
    error StalePrice(address token);

    // --- constructor ---
    constructor(
        address usdc_,
        address weth_,
        address universalRouter_,
        address permit2_,
        address v4Router_,
        uint256 bankCapUsdc6d_
    ) Ownable(msg.sender) {
        require(usdc_ != address(0) && weth_ != address(0), "bad tokens");
        USDC      = usdc_;
        WETH      = weth_;
        UR        = IUniversalRouter(universalRouter_);
        PERMIT2   = IPermit2(permit2_);
        V4_ROUTER = IV4Router(v4Router_);
        bankCap   = bankCapUsdc6d_;
    }

    // --- admin / seguridad ---
    function setBankCap(uint256 newCapUsdc6d) external onlyOwner {
        bankCap = newCapUsdc6d;
        emit BankCapUpdated(newCapUsdc6d);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // --- oráculos: seteo y consultas (preserva V2) ---
    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "bad feed");
        priceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedSet(token, feed);
    }

    /// @notice Devuelve último precio crudo del feed del token, sus decimales y el timestamp de actualización.
    function latestPrice(address token)
        public
        view
        returns (int256 price, uint8 feedDecimals, uint256 updatedAt)
    {
        AggregatorV3Interface feed = priceFeeds[token];
        if (address(feed) == address(0)) revert NoPriceFeed(token);
        (, price, , updatedAt, ) = feed.latestRoundData();
        feedDecimals = feed.decimals();
        require(price > 0, "bad price");
    }

    /// @notice Cotiza `amountIn` de `token` en **USDC (6d)** usando Chainlink. Redondea hacia abajo.
    /// @dev Si `token == USDC`, retorna `amountIn`.
    ///      Para tokens con 18d y feeds en USD (8d), esto hace:
    ///      usdc6d = (amountIn * price * 1e6) / (1eTokenDec * 1eFeedDec)
    function quoteTokenToUsdc6d(address token, uint256 amountIn) public view returns (uint256 usdcAmount6d) {
        if (token == USDC) return amountIn;

        (int256 p, uint8 fd, ) = latestPrice(token);
        uint256 price = uint256(p);
        uint8 td = IERC20Metadata(token).decimals();

        // Para minimizar overflow trabajamos por pasos con redondeo hacia abajo.
        // Paso 1: escalar a 6d y normalizar por decimales del token.
        // usdc6d ≈ ((amountIn * 1e6) / 10^td) * price / 10^fd
        uint256 scaled = (amountIn * 1e6) / (10 ** td);
        usdcAmount6d = (scaled * price) / (10 ** fd);
        // Nota: este enfoque es conservador (round-down) y suficiente para consultas.
    }

    // --- vistas ---
    function remainingCap() public view returns (uint256) {
        return bankCap > totalUsdc ? bankCap - totalUsdc : 0;
    }

    // =========================================================
    //                 Depósitos / Retiros USDC
    // =========================================================

    function depositUsdc(uint256 amountUsdc6d) external whenNotPaused nonReentrant {
        if (amountUsdc6d == 0) revert ZeroAmount();

        uint256 rem = remainingCap();
        if (amountUsdc6d > rem) revert CapExceeded(rem, amountUsdc6d);

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amountUsdc6d);

        unchecked {
            balanceUsdc[msg.sender] += amountUsdc6d;
            totalUsdc += amountUsdc6d;
        }

        emit DepositedUSDC(msg.sender, amountUsdc6d, balanceUsdc[msg.sender], totalUsdc);
    }

    function withdrawUsdc(uint256 amountUsdc6d) external whenNotPaused nonReentrant {
        if (amountUsdc6d == 0) revert ZeroAmount();

        uint256 bal = balanceUsdc[msg.sender];
        if (amountUsdc6d > bal) revert InsufficientBalance(bal, amountUsdc6d);

        unchecked {
            balanceUsdc[msg.sender] = bal - amountUsdc6d;
            totalUsdc -= amountUsdc6d;
        }

        IERC20(USDC).safeTransfer(msg.sender, amountUsdc6d);
        emit WithdrawnUSDC(msg.sender, amountUsdc6d, balanceUsdc[msg.sender], totalUsdc);
    }

    // =========================================================
    //                      Single-hop swaps (v4)
    // =========================================================

    /**
     * @dev ERC20 -> USDC (v4 single-hop).
     * Requiere que el poolKey incluya USDC y que la dirección (zeroForOne) haga tokenIn -> USDC.
     * Usa SafeERC20.forceApprove y resetea a 0 post-swap.
     */
    function _swapExactInputSingle(
        PoolKey calldata key,
        bool      zeroForOne,
        uint128   amountIn,
        uint128   minOut
    ) internal virtual returns (uint256 amountOut) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require(c0 == USDC || c1 == USDC, "pool w/out USDC");

        address tokenIn = zeroForOne ? c0 : c1;

        IERC20(tokenIn).forceApprove(address(V4_ROUTER), uint256(amountIn));
        amountOut = V4_ROUTER.exactInputSingle(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: bytes("")
            })
        );
        IERC20(tokenIn).forceApprove(address(V4_ROUTER), 0);

        if (amountOut < minOut) revert SwapFailed();
    }

    /**
     * @dev ETH -> USDC: wrap ETH a WETH y single-hop WETH->USDC.
     * Requiere que el poolKey sea WETH/USDC y la dirección coincida con WETH -> USDC.
     * Usa SafeERC20.forceApprove y resetea a 0 post-swap.
     */
    function _swapExactInputSingleEth(
        PoolKey calldata key,
        bool      zeroForOne,
        uint128   amountIn,
        uint128   minOut
    ) internal virtual returns (uint256 amountOut) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require((c0 == WETH || c1 == WETH) && (c0 == USDC || c1 == USDC), "pool must be WETH/USDC");

        IWETH9(WETH).deposit{value: uint256(amountIn)}();

        address tokenIn = zeroForOne ? c0 : c1;
        require(tokenIn == WETH, "dir must be WETH->USDC");

        IERC20(WETH).forceApprove(address(V4_ROUTER), uint256(amountIn));
        amountOut = V4_ROUTER.exactInputSingle(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: bytes("")
            })
        );
        IERC20(WETH).forceApprove(address(V4_ROUTER), 0);

        if (amountOut < minOut) revert SwapFailed();
    }

    /**
     * @notice Depósito de cualquier ERC-20 soportado: swappea a USDC (single-hop) y acredita.
     */
    function depositArbitraryToken(
        address   tokenIn,
        uint256   amountIn,
        PoolKey calldata key,
        bool      zeroForOne,
        uint128   minOutUsdc6d,
        uint256   deadline
    ) external virtual whenNotPaused nonReentrant {
        if (tokenIn == address(0)) revert UnsupportedToken(tokenIn);
        if (tokenIn == USDC) revert TokenIsUSDC();
        if (amountIn == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        // cap conservador: exigimos que al menos el minOut quepa en el banco
        uint256 rem = remainingCap();
        if (uint256(minOutUsdc6d) > rem) revert CapExceeded(rem, uint256(minOutUsdc6d));

        // coherencia de pool/dirección
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require(c0 == USDC || c1 == USDC, "pool w/out USDC");
        address expectedIn = zeroForOne ? c0 : c1;
        require(expectedIn == tokenIn, "key/dir mismatch");

        // transferir y bloquear tokens con fee-on-transfer (no soportados)
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - balBefore;
        require(received == amountIn, "fee-on-transfer not supported");

        // casting a uint128 validado
        require(amountIn <= type(uint128).max, "amountIn too big");
        // casting to 'uint128' is safe because we checked it fits above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outUsdc = _swapExactInputSingle(key, zeroForOne, uint128(amountIn), minOutUsdc6d);

        unchecked {
            balanceUsdc[msg.sender] += outUsdc;
            totalUsdc += outUsdc;
        }
        emit DepositedToken(msg.sender, tokenIn, amountIn, outUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    /**
     * @notice Depósito en ETH: wrap a WETH y single-hop WETH->USDC.
     */
    function depositEthSingleHop(
        PoolKey calldata key,
        bool      zeroForOne,
        uint128   minOutUsdc6d,
        uint256   deadline
    ) external payable virtual whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        // cap conservador: minOut debe caber
        uint256 rem = remainingCap();
        if (uint256(minOutUsdc6d) > rem) revert CapExceeded(rem, uint256(minOutUsdc6d));

        // coherencia de pool/dirección: WETH -> USDC
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require((c0 == WETH || c1 == WETH) && (c0 == USDC || c1 == USDC), "pool must be WETH/USDC");
        address expectedIn = zeroForOne ? c0 : c1;
        require(expectedIn == WETH, "dir must be WETH->USDC");

        require(msg.value <= type(uint128).max, "msg.value too big");
        // casting to 'uint128' is safe because we checked it fits above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outUsdc = _swapExactInputSingleEth(key, zeroForOne, uint128(msg.value), minOutUsdc6d);

        unchecked {
            balanceUsdc[msg.sender] += outUsdc;
            totalUsdc += outUsdc;
        }
        emit DepositedETH(msg.sender, msg.value, outUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    // =========================================================
    //                 Universal Router (multi-hop)
    // =========================================================

    /// @notice Depósito en ETH vía Universal Router. El path debe terminar entregando USDC a este contrato.
    function depositEthViaUr(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable virtual whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 outUsdc = _executeUr(commands, inputs, msg.value, deadline);

        uint256 rem = remainingCap();
        if (outUsdc > rem) revert CapExceeded(rem, outUsdc);

        unchecked {
            balanceUsdc[msg.sender] += outUsdc;
            totalUsdc += outUsdc;
        }
        emit DepositedETH(msg.sender, msg.value, outUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    /// @notice Depósito de ERC20 vía Universal Router. Requiere transferir tokenIn al banco y aprobar al UR.
    function depositTokenViaUr(
        address   tokenIn,
        uint256   amountIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256   deadline
    ) external virtual whenNotPaused nonReentrant {
        if (tokenIn == address(0)) revert UnsupportedToken(tokenIn);
        if (tokenIn == USDC) revert TokenIsUSDC();
        if (amountIn == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        // Transfer in (rechazo FoT)
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - balBefore;
        require(received == amountIn, "fee-on-transfer not supported");

        // Approve UR y ejecutar
        IERC20(tokenIn).forceApprove(address(UR), amountIn);
        uint256 outUsdc = _executeUr(commands, inputs, 0, deadline);
        IERC20(tokenIn).forceApprove(address(UR), 0); // reset

        uint256 rem = remainingCap();
        if (outUsdc > rem) revert CapExceeded(rem, outUsdc);

        unchecked {
            balanceUsdc[msg.sender] += outUsdc;
            totalUsdc += outUsdc;
        }
        emit DepositedToken(msg.sender, tokenIn, amountIn, outUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    /// @notice Depósito ERC20 vía Universal Router usando Permit2 (sin firma inline; requiere allowance previa en Permit2).
    function depositTokenViaUrPermit2(
        address   tokenIn,
        uint160   amountIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256   deadline
    ) external virtual whenNotPaused nonReentrant {
        if (tokenIn == address(0)) revert UnsupportedToken(tokenIn);
        if (tokenIn == USDC) revert TokenIsUSDC();
        if (amountIn == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        // Traer fondos del usuario usando Permit2 allowance previa
        PERMIT2.transferFrom(msg.sender, address(this), amountIn, tokenIn);

        // Approve UR y ejecutar
        IERC20(tokenIn).forceApprove(address(UR), uint256(amountIn));
        uint256 outUsdc = _executeUr(commands, inputs, 0, deadline);
        IERC20(tokenIn).forceApprove(address(UR), 0); // reset

        uint256 rem = remainingCap();
        if (outUsdc > rem) revert CapExceeded(rem, outUsdc);

        unchecked {
            balanceUsdc[msg.sender] += outUsdc;
            totalUsdc += outUsdc;
        }
        emit DepositedToken(msg.sender, tokenIn, uint256(amountIn), outUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    // =========================================================
    //                      Helpers públicos
    // =========================================================
    function buildSinglePoolKeyAndDirection(
        address tokenA,
        address tokenB,
        uint24  fee,
        int24   tickSpacing,
        IHooks  hooks
    ) external pure returns (PoolKey memory key, bool zeroForOne) {
        Currency a = Currency.wrap(tokenA);
        Currency b = Currency.wrap(tokenB);

        bool aLtB = (tokenA < tokenB);
        Currency c0 = aLtB ? a : b;
        Currency c1 = aLtB ? b : a;

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee:       fee,
            tickSpacing: tickSpacing,
            hooks:     hooks
        });

        zeroForOne = (Currency.unwrap(a) == Currency.unwrap(c0)); // si tokenA es c0 => 0->1
    }

    // =========================================================
    //                 Internas (UR execution)
    // =========================================================
    /// @dev Ejecuta UR y devuelve los USDC recibidos por el contrato (balance diff).
    function _executeUr(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 value,
        uint256 deadline
    ) internal virtual returns (uint256 usdcOut) {
        uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
        UR.execute{value: value}(commands, inputs, deadline);
        uint256 afterBal = IERC20(USDC).balanceOf(address(this));

        unchecked { usdcOut = afterBal - beforeBal; }
        require(usdcOut > 0, "UR: no USDC out");
    }
}
