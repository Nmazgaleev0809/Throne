// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Throne} from "../src/Throne.sol";
import {MockUSDC, RevertingUSDC} from "./mocks/MockUSDC.sol";

/// @dev Drives random bids / resolutions against Throne so we can assert the
///      escrow invariant: token.balanceOf(contract) == pending.amount + sum(claimable).
contract ThroneHandler is Test {
    Throne public throne;
    RevertingUSDC public token;
    address public moderator;
    address public treasury;

    address[] public actors;
    bytes32 internal nextHash = keccak256("seed");

    constructor(Throne throne_, RevertingUSDC token_, address moderator_, address treasury_, address[] memory actors_) {
        throne = throne_;
        token = token_;
        moderator = moderator_;
        treasury = treasury_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function bid(uint256 actorSeed, uint256 extra) external {
        if (throne.hasPending()) return;
        address bidder = actors[actorSeed % actors.length];
        uint256 minBid = throne.minNextBid();
        uint256 maxBid = throne.maxBid();
        if (minBid > maxBid) return;

        extra = bound(extra, 0, maxBid - minBid);
        uint256 amount = minBid + extra;
        if (token.balanceOf(bidder) < amount) {
            token.mint(bidder, amount);
        }
        vm.prank(bidder);
        token.approve(address(throne), amount);

        nextHash = keccak256(abi.encodePacked(nextHash, bidder, amount));
        vm.prank(bidder);
        throne.bid(amount, nextHash);
    }

    function approveBid() external {
        if (!throne.hasPending()) return;
        (,,, uint64 deadline) = throne.pending();
        if (block.timestamp > deadline) return;
        vm.prank(moderator);
        throne.approve();
    }

    function rejectBid() external {
        if (!throne.hasPending()) return;
        vm.prank(moderator);
        throne.reject();
    }

    function expireBid(uint256 warpExtra) external {
        if (!throne.hasPending()) return;
        (,,, uint64 deadline) = throne.pending();
        if (block.timestamp <= deadline) {
            warpExtra = bound(warpExtra, 1, 7 days);
            vm.warp(uint256(deadline) + warpExtra);
        }
        throne.expire();
    }

    function withdraw(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        if (throne.claimable(who) == 0) return;
        token.setBlocked(who, false);
        vm.prank(who);
        throne.withdraw();
    }

    function toggleBlock(uint256 actorSeed, bool blocked) external {
        address who = actors[actorSeed % actors.length];
        token.setBlocked(who, blocked);
    }
}

contract ThroneInvariantTest is Test {
    Throne internal throne;
    RevertingUSDC internal token;
    ThroneHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal moderator = makeAddr("moderator");
    address internal treasury = makeAddr("treasury");

    address[] internal actors;

    function setUp() public {
        token = new RevertingUSDC();
        uint256 starting = 1_000_000;
        uint256 maxBid = 1_000_000_000_000;
        throne = new Throne(address(token), owner, moderator, treasury, starting, maxBid);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(treasury);

        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000_000_000);
            vm.prank(actors[i]);
            token.approve(address(throne), type(uint256).max);
        }

        handler = new ThroneHandler(throne, token, moderator, treasury, actors);
        targetContract(address(handler));
    }

    function invariant_escrowBalance() public view {
        uint256 sumClaimable = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sumClaimable += throne.claimable(actors[i]);
        }
        (, uint256 pendingAmount,,) = throne.pending();
        assertEq(token.balanceOf(address(throne)), pendingAmount + sumClaimable);
    }

    function invariant_pendingClearedOrFunded() public view {
        (address bidder, uint256 amount,,) = throne.pending();
        if (bidder == address(0)) {
            assertEq(amount, 0);
        } else {
            assertGt(amount, 0);
        }
    }
}
