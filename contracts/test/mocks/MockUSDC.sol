// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 6-decimal ERC20 used as a stand-in for USDC in tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Transfer to a blocked recipient reverts. Used to exercise deferred payouts.
contract RevertingUSDC is MockUSDC {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) revert("blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) revert("blocked");
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Transfer to a blocked recipient returns false instead of reverting.
contract FalseReturningUSDC is MockUSDC {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, amount);
    }
}
