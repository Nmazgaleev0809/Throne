// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Throne} from "../src/Throne.sol";

/// @notice Deploy Throne. Constructor args come from the environment.
/// Verify the USDC address from Circle's docs before a real deploy; do not paste one from memory.
contract DeployScript is Script {
    function run() external {
        address token = vm.envAddress("USDC");
        address owner = vm.envAddress("OWNER");
        address moderator = vm.envAddress("MODERATOR");
        address treasury = vm.envAddress("TREASURY");
        uint256 startingPrice = vm.envUint("STARTING_PRICE");
        uint256 maxBid = vm.envUint("MAX_BID");

        vm.startBroadcast();
        Throne throne = new Throne(token, owner, moderator, treasury, startingPrice, maxBid);
        vm.stopBroadcast();

        console.log("Throne deployed at", address(throne));
    }
}
