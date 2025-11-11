// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";
import {KipuBankV3Deployed} from "../src/KipuBankV3Deployed.sol";

contract DeployKipuBankV3 is Script {
    using stdJson for string;

    function run() external {
        // 1) Leer claves y direcciones
        uint256 pk = vm.envUint("PRIVATE_KEY"); // <- usa tu cuenta NUEVA
        string memory path = string.concat(vm.projectRoot(), "/script/addresses.sepolia.json");
        string memory json = vm.readFile(path);

        address usdc    = json.readAddress(".tokens.USDC.address");
        address weth9   = json.readAddress(".tokens.WETH9.address");
        address ur      = json.readAddress(".contracts.UNIVERSAL_ROUTER");
        address permit2 = json.readAddress(".contracts.PERMIT2");

        // Uniswap V4 router: si no lo usás en producción, podés dejar address(0)
        address v4router = address(0);

        // 2) Cap inicial recomendado (1,000,000 USDC 6d)
        uint256 bankCap = 1_000_000 * 1e6;

        // 3) Broadcast
        vm.startBroadcast(pk);

        KipuBankV3Deployed bank = new KipuBankV3Deployed(
            usdc,
            weth9,
            ur,
            permit2,
            v4router,
            bankCap
        );

        vm.stopBroadcast();

        console.log("KipuBankV3 deployed at:", address(bank));
        console.log("USDC:", usdc);
        console.log("WETH9:", weth9);
        console.log("UR:", ur);
        console.log("PERMIT2:", permit2);
        console.log("V4_ROUTER:", v4router);
        console.log("BANK_CAP_USDC_6D:", bankCap);
    }
}
