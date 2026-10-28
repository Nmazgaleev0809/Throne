// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Throne} from "../src/Throne.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract DeployScriptTest is Test {
    function test_runDeploysWithEnvArgs() public {
        MockUSDC token = new MockUSDC();
        address owner = makeAddr("owner");
        address moderator = makeAddr("moderator");
        address treasury = makeAddr("treasury");
        uint256 startingPrice = 1_000_000;
        uint256 maxBid = 100_000_000;

        vm.setEnv("USDC", vm.toString(address(token)));
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("MODERATOR", vm.toString(moderator));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("STARTING_PRICE", vm.toString(startingPrice));
        vm.setEnv("MAX_BID", vm.toString(maxBid));

        DeployScript script = new DeployScript();
        script.run();
    }
}
