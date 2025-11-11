# KipuBankV3 — DeFi bank con Universal Router (Uniswap V4), Permit2 y oráculos Chainlink

**Dirección (Sepolia):** `0xD90C9fE568254b7FB0a1bB8bb4350163e9aEFA73` (verificado en Etherscan)  
**Red:** Sepolia (chainId `11155111`)  
**Autor:** Francisco Florio — _EDP Módulo 4 (KipuBankV3)_  
**Licencia:** MIT


## ✨ Resumen de la mejora (V2 → V3)

KipuBankV3 extiende KipuBankV2 para aceptar **cualquier token soportado por Uniswap V4**, intercambiarlo automáticamente a **USDC** dentro del contrato, y **acreditar el balance en USDC** del usuario, **respetando el bank cap**.

Se integran:
- **Universal Router (UR)** de Uniswap para ruteo flexible de swaps.
- **Tipos V4**: `PoolKey`, `Currency` (single-hop programático).
- **Permit2** para depósitos con approvals gas-eficientes.
- **Chainlink** para oráculos (ETH/USD, 8 decimales) en quoting/checks.
- **Seguridad**: `ReentrancyGuard`, `Pausable`, `Ownable`, `SafeERC20`.

**Contabilidad:** el banco sólo lleva saldos en **USDC (6 decimales)**. Todo depósito no-USDC se **swapea → USDC** antes de acreditar.


## ✅ Objetivos

- **Tokens arbitrarios (Uniswap V4):** `depositTokenViaUr`, `depositArbitraryToken`, `depositEthSingleHop`, `depositEthViaUr`.
- **Swaps on-chain:** `_swapExactInputSingle(...)` + ejecución UR (commands/inputs).
- **Preserva V2:** owner, pausas, depósitos/retiros USDC, oráculos Chainlink, balances.
- **Respeta bank cap:** valida contra `bankCap()` y `remainingCap()` con el USDC resultante; error `CapExceeded`.
- **Dependencias:** UR, Permit2, tipos V4 (`PoolKey`, `Currency`), `SafeERC20`. Tests unitarios + integración en verde.


## 📦 Estructura (relevante)
/src
  KipuBankV3.sol             # contrato principal
  KipuBankV3Deployed.sol     # envoltorio de deploy

/script
  DeployKipuBankV3.s.sol     # script de deploy
  addresses.sepolia.json     # direcciones USDC/WETH/UR/Permit2

/test
  KipuBankV3.unit.t.sol          # unit: USDC, cap, withdraw
  KipuBankV3.integration.t.sol   # integración: ETH, arbitrary token, UR, cap

## 🔧 Requisitos locales

- **Foundry** (forge/cast): https://book.getfoundry.sh
- **Git** (y Node opcional)
- **.env** con: `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, `ETHERSCAN_API_KEY`


## 🧪 Tests
```bash
forge install
forge build
forge test -vv
```

## 🔐 .env de ejemplo
```bash
# RPC (Sepolia + opcional Tenderly)
SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/<TU_API_KEY>"     # o Alchemy/Ankr/etc
TENDERLY_VNET_RPC_URL="https://virtual.sepolia.eu.rpc.tenderly.co/<tu-id>"  # opcional

# Deploy / Verify
PRIVATE_KEY="0x<PRIVATE_KEY_TESTNET>"        # usa una cuenta NUEVA
ETHERSCAN_API_KEY="<TU_ETHERSCAN_API_KEY>"

```



## 📚 script/addresses.sepolia.json
```json
{
  "chainId": 11155111,
  "tokens": {
    "USDC":  { "address": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", "decimals": 6 },
    "WETH9": { "address": "0xFfF9976782d46CC05630D1f6eBAb18b2324d6B14", "decimals": 18 }
  },
  "contracts": {
    "UNIVERSAL_ROUTER": "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
    "PERMIT2":          "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  },
  "notes": "V4_ROUTER opcional; no requerido para UR."
}

```

## 🚀 Deploy + Verify (Sepolia)
```bash
# 1) cargar .env en shell (Git Bash)
set -a; source .env; set +a

# 2) Deploy + verify
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvvv

```
> Dirección resultante (verificado): 0xD90C9fE568254b7FB0a1bB8bb4350163e9aEFA73

## 🔗 Configurar oráculo Chainlink (WETH → ETH/USD)
```bash
export BANK=0xD90C9fE568254b7FB0a1bB8bb4350163e9aEFA73
export WETH=0xFfF9976782d46CC05630D1f6eBAb18b2324d6B14
export ETH_USD_FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306

# mapear el feed
cast send $BANK "setPriceFeed(address,address)" $WETH $ETH_USD_FEED \
  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"

# sanity
cast call $BANK "priceFeeds(address)(address)" $WETH --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "latestPrice(address)(int256)"  $WETH --rpc-url "$SEPOLIA_RPC_URL"
# Ejemplo: 355104667900 (8d) => 3551.046679 USD/ETH
```

## 🧭 Interacción básica (USDC)
```bash
# Direcciones leídas del contrato (evita typos)
export USDC=$(cast call $BANK "USDC()(address)" --rpc-url "$SEPOLIA_RPC_URL")
export EOA=<TU_ADDRESS>

# Depositar 5 USDC
export AMOUNT=5000000   # 6 dec
cast send $USDC "approve(address,uint256)" $BANK $AMOUNT \
  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"

cast send $BANK "depositUsdc(uint256)" $AMOUNT \
  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"

# Consultas
cast call $BANK "balanceUsdc(address)(uint256)" $EOA --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "totalUsdc()(uint256)"          --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "bankCap()(uint256)"            --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "remainingCap()(uint256)"       --rpc-url "$SEPOLIA_RPC_URL"

# Retirar 1 USDC
cast send $BANK "withdrawUsdc(uint256)" 1000000 \
  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"
```

## 💱 Depósitos con swap (ETH / ERC-20 arbitrario)

**ETH single-hop (WETH↔USDC con `PoolKey`):**
- `depositEthSingleHop((address,address,uint24,int24,address) key, bool zeroForOne, uint128 amountIn, uint256 minOutUsdc6d)`
- `minOutUsdc6d` controla **slippage** (USDC 6d).

**ERC-20 arbitrario vía Universal Router:**
- `depositTokenViaUr(tokenIn, amountIn, commands, inputs, minOutUsdc6d)`
- `depositTokenViaUrPermit2(tokenIn, amountInPermit160, commands, inputs, minOutUsdc6d)`

**Helper single-hop:**
- `buildSinglePoolKeyAndDirection(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hooks)`


## 🧩 ABI / métodos útiles
- **Addresses/constantes:** `USDC()`, `WETH()`, `UR()`, `PERMIT2()`, `V4_ROUTER()`
- **Cap & totales:** `bankCap()`, `totalUsdc()`, `remainingCap()`
- **Balances:** `balanceUsdc(address)`
- **Depósitos:**
  - `depositUsdc(uint256)`
  - `depositEthSingleHop((...), bool, uint128, uint256)`
  - `depositEthViaUr(bytes, bytes[], uint256)`
  - `depositTokenViaUr(address, uint256, bytes, bytes[], uint256)`
  - `depositTokenViaUrPermit2(address, uint160, bytes, bytes[], uint256)`
- **Retiros:** `withdrawUsdc(uint256)`
- **Oráculos:** `setPriceFeed(address,address)`, `priceFeeds(address)`, `latestPrice(address)`
- **Quoting:** `quoteTokenToUsdc6d(address,uint256)`
- **Admin:** `setBankCap(uint256)`, `pause()`, `unpause()`, `owner()`, `transferOwnership(address)`


## 🛡️ Seguridad y trade-offs

- **USDC-only accounting:** simplifica y reduce riesgo de precio. Todo no-USDC se swapea → USDC antes de acreditar.
- **Bank Cap estricto:** validación previa con `minOutUsdc6d`; revierte `CapExceeded` si excede.
- **Slippage on-chain:** `minOutUsdc6d` requerido en depósitos con swap; el usuario controla el deslizamiento.
- **SafeERC20:** transferencias/approvals seguros; se descartan FoT/rebase no estándar.
- **Reentrancy & Pausable:** `nonReentrant`, `whenNotPaused`.
- **Chainlink:** 8 decimales → convertido a 6d USDC para quoting; no se usa para ejecutar swaps (eso lo hace UR).
- **Single-hop por defecto:** WETH↔USDC directo (gas y complejidad). Multi-hop vía UR (`deposit*ViaUr`).

**Limitaciones**
- Si no hay **liquidez**/pool compatible en V4/UR para el token in, el depósito revierte.
- Tokens **exóticos** (rebase, FoT severo, blacklists) no están soportados.
- Chainlink es **lagging** vs spot: sirve para sanity/limits, no para ejecución MEV-grade.


## 🔍 Sanity checks útiles (Sepolia)
```bash
# Identidad del contrato
cast call $BANK "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "USDC()(address)"  --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "WETH()(address)"  --rpc-url "$SEPOLIA_RPC_URL"

# Cap y estado
cast call $BANK "bankCap()(uint256)"      --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "remainingCap()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "paused()(bool)"          --rpc-url "$SEPOLIA_RPC_URL"

# Oráculo y cotización
cast call $BANK "priceFeeds(address)(address)" $WETH --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "latestPrice(address)(int256)" $WETH --rpc-url "$SEPOLIA_RPC_URL"
cast call $BANK "quoteTokenToUsdc6d(address,uint256)(uint256)" $WETH 1000000000000000000 \
  --rpc-url "$SEPOLIA_RPC_URL"

```

## 📤 Verificación del deploy

Contrato verificado en Sepolia:  
`0xD90C9fE568254b7FB0a1bB8bb4350163e9aEFA73` — pestañas **Code/Read/Write** disponibles en Etherscan.

## .gitignore Recomendado
```gitignore
.env
out/
broadcast/
cache/
```

## 📬 Contacto + disclaimer
**Autor:** Francisco Florio — `franflorio` (GitHub)  
**Curso:** Ethereum Developer Pack — Módulo 4 (TP Final KipuBankV3)

> Proyecto educativo. **No usar en producción** sin auditoría formal.
