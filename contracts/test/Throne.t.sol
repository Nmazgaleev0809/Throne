// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Throne} from "../src/Throne.sol";
import {MockUSDC, RevertingUSDC, FalseReturningUSDC} from "./mocks/MockUSDC.sol";

contract ThroneTest is Test {
    uint256 internal constant STARTING_PRICE = 1_000_000; // 1 USDC
    uint256 internal constant MAX_BID = 1_000_000_000_000; // 1,000,000 USDC
    bytes32 internal constant HASH_A = keccak256("a");
    bytes32 internal constant HASH_B = keccak256("b");
    bytes32 internal constant HASH_C = keccak256("c");

    Throne internal throne;
    MockUSDC internal token;

    address internal owner = makeAddr("owner");
    address internal moderator = makeAddr("moderator");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        token = new MockUSDC();
        throne = new Throne(address(token), owner, moderator, treasury, STARTING_PRICE, MAX_BID);

        token.mint(alice, 10_000_000_000_000);
        token.mint(bob, 10_000_000_000_000);
        token.mint(carol, 10_000_000_000_000);

        vm.prank(alice);
        token.approve(address(throne), type(uint256).max);
        vm.prank(bob);
        token.approve(address(throne), type(uint256).max);
        vm.prank(carol);
        token.approve(address(throne), type(uint256).max);
    }

    function _seat(address bidder, uint256 amount, bytes32 contentHash) internal {
        vm.prank(bidder);
        throne.bid(amount, contentHash);
        vm.prank(moderator);
        throne.approve();
    }

    function _expectedMin(uint256 price) internal view returns (uint256) {
        if (price == 0) return STARTING_PRICE;
        return (price * (throne.BPS() + throne.MIN_INCREMENT_BPS()) + throne.BPS() - 1) / throne.BPS();
    }

    function _refundBonus(uint256 price) internal view returns (uint256) {
        return price + (price * throne.REFUND_BONUS_BPS()) / throne.BPS();
    }

    function _throneOwner() internal view returns (address) {
        (address o,,,) = throne.throne();
        return o;
    }

    function _thronePrice() internal view returns (uint256) {
        (, uint256 p,,) = throne.throne();
        return p;
    }

    function _pendingBidder() internal view returns (address) {
        (address b,,,) = throne.pending();
        return b;
    }

    function _pendingAmount() internal view returns (uint256) {
        (, uint256 a,,) = throne.pending();
        return a;
    }

    function _pendingDeadline() internal view returns (uint64) {
        (,,, uint64 d) = throne.pending();
        return d;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_constructorSetsConfig() public view {
        assertEq(address(throne.token()), address(token));
        assertEq(throne.owner(), owner);
        assertEq(throne.moderator(), moderator);
        assertEq(throne.treasury(), treasury);
        assertEq(throne.startingPrice(), STARTING_PRICE);
        assertEq(throne.maxBid(), MAX_BID);
        assertEq(throne.minNextBid(), STARTING_PRICE);
        assertFalse(throne.hasPending());
        assertEq(_throneOwner(), address(0));
    }

    function test_constructorRevertsZeroAddresses() public {
        vm.expectRevert(Throne.ZeroAddress.selector);
        new Throne(address(0), owner, moderator, treasury, STARTING_PRICE, MAX_BID);

        vm.expectRevert(Throne.ZeroAddress.selector);
        new Throne(address(token), owner, address(0), treasury, STARTING_PRICE, MAX_BID);

        vm.expectRevert(Throne.ZeroAddress.selector);
        new Throne(address(token), owner, moderator, address(0), STARTING_PRICE, MAX_BID);
    }

    function test_constructorRevertsInvalidConfig() public {
        vm.expectRevert(Throne.InvalidConfig.selector);
        new Throne(address(token), owner, moderator, treasury, 0, MAX_BID);

        vm.expectRevert(Throne.InvalidConfig.selector);
        new Throne(address(token), owner, moderator, treasury, STARTING_PRICE, STARTING_PRICE - 1);
    }

    // ------------------------------------------------------------------
    // First bid / happy path / price math
    // ------------------------------------------------------------------

    function test_firstBidMinimumIsStartingPrice() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Throne.BidTooLow.selector, STARTING_PRICE));
        throne.bid(STARTING_PRICE - 1, HASH_A);

        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        assertTrue(throne.hasPending());
        assertEq(_pendingBidder(), alice);
        assertEq(_pendingAmount(), STARTING_PRICE);
        assertEq(_pendingDeadline(), uint64(block.timestamp + throne.REVIEW_TIMEOUT()));
        assertEq(token.balanceOf(address(throne)), STARTING_PRICE);
        assertEq(token.balanceOf(alice), 10_000_000_000_000 - STARTING_PRICE);
    }

    function test_approveFirstBidSendsAllToTreasury() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.expectEmit(true, true, false, true);
        emit Throne.BidApproved(alice, address(0), STARTING_PRICE, 0, STARTING_PRICE, HASH_A);
        vm.prank(moderator);
        throne.approve();

        assertFalse(throne.hasPending());
        assertEq(_throneOwner(), alice);
        assertEq(_thronePrice(), STARTING_PRICE);
        (,, bytes32 contentHash,) = throne.throne();
        assertEq(contentHash, HASH_A);
        assertEq(token.balanceOf(treasury), treasuryBefore + STARTING_PRICE);
        assertEq(token.balanceOf(address(throne)), 0);
        assertEq(throne.minNextBid(), _expectedMin(STARTING_PRICE));
    }

    function test_happyPathSecondKingRefundPlusBonus() public {
        _seat(alice, STARTING_PRICE, HASH_A);

        uint256 minBid = throne.minNextBid();
        assertEq(minBid, 1_100_000); // 110% of 1 USDC, exact

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(bob);
        throne.bid(minBid, HASH_B);
        vm.prank(moderator);
        throne.approve();

        uint256 refund = _refundBonus(STARTING_PRICE); // 1_050_000
        uint256 toTreasury = minBid - refund; // 50_000

        assertEq(_throneOwner(), bob);
        assertEq(_thronePrice(), minBid);
        assertEq(token.balanceOf(alice), aliceBefore + refund);
        assertEq(token.balanceOf(treasury), treasuryBefore + toTreasury);
        assertEq(token.balanceOf(address(throne)), 0);
        assertEq(throne.minNextBid(), _expectedMin(minBid));
    }

    function test_overbidBecomesNewPriceAndExtraGoesToTreasury() public {
        _seat(alice, STARTING_PRICE, HASH_A);

        uint256 overbid = 2_000_000;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(bob);
        throne.bid(overbid, HASH_B);
        vm.prank(moderator);
        throne.approve();

        uint256 refund = _refundBonus(STARTING_PRICE);
        assertEq(_thronePrice(), overbid);
        assertEq(token.balanceOf(alice), aliceBefore + refund);
        assertEq(token.balanceOf(treasury), treasuryBefore + (overbid - refund));
    }

    function test_roundingAtTinyPrice() public {
        Throne tiny = new Throne(address(token), owner, moderator, treasury, 1, MAX_BID);
        vm.prank(alice);
        token.approve(address(tiny), type(uint256).max);
        vm.prank(alice);
        tiny.bid(1, HASH_A);
        vm.prank(moderator);
        tiny.approve();
        // ceil(1 * 1.10) = 2
        assertEq(tiny.minNextBid(), 2);
    }

    function test_roundingAtHugePrice() public {
        // Occupy at a price whose 110% still fits under maxBid.
        uint256 first = (MAX_BID * 10_000) / 11_000;
        _seat(alice, first, HASH_A);
        uint256 minBid = throne.minNextBid();
        assertLe(minBid, MAX_BID);
        assertEq(minBid, (first * 11_000 + 9_999) / 10_000);
        vm.prank(bob);
        throne.bid(minBid, HASH_B);
        assertEq(_pendingAmount(), minBid);
    }

    function testFuzz_minNextBidRoundsUp(uint256 price) public {
        price = bound(price, 1, MAX_BID / 2);
        uint256 first = price < STARTING_PRICE ? STARTING_PRICE : price;
        first = bound(first, STARTING_PRICE, MAX_BID);
        _seat(alice, first, HASH_A);

        uint256 minBid = throne.minNextBid();
        uint256 bps = throne.BPS();
        uint256 inc = throne.MIN_INCREMENT_BPS();

        // minBid is ceil(price * 1.10)
        assertEq(minBid, (first * (bps + inc) + bps - 1) / bps);
        assertGe(minBid * bps, first * (bps + inc));
        if (minBid > 0) {
            assertLt((minBid - 1) * bps, first * (bps + inc));
        }
    }

    function testFuzz_refundPlusTreasuryEqualsBid(uint256 first, uint256 second) public {
        first = bound(first, STARTING_PRICE, MAX_BID / 3);
        _seat(alice, first, HASH_A);

        uint256 minBid = throne.minNextBid();
        second = bound(second, minBid, MAX_BID);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(bob);
        throne.bid(second, HASH_B);
        vm.prank(moderator);
        throne.approve();

        uint256 refund = token.balanceOf(alice) - aliceBefore;
        uint256 profit = token.balanceOf(treasury) - treasuryBefore;
        assertEq(refund + profit, second);
        assertEq(refund, _refundBonus(first));
    }

    // ------------------------------------------------------------------
    // Bid guards
    // ------------------------------------------------------------------

    function test_bidRevertsEmptyContentHash() public {
        vm.prank(alice);
        vm.expectRevert(Throne.EmptyContentHash.selector);
        throne.bid(STARTING_PRICE, bytes32(0));
    }

    function test_secondBidWhilePendingReverts() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.prank(bob);
        vm.expectRevert(Throne.PendingBidExists.selector);
        throne.bid(STARTING_PRICE, HASH_B);
    }

    function test_bidTooLowAfterOccupied() public {
        _seat(alice, STARTING_PRICE, HASH_A);
        uint256 minBid = throne.minNextBid();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Throne.BidTooLow.selector, minBid));
        throne.bid(minBid - 1, HASH_B);
    }

    function test_bidTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Throne.BidTooHigh.selector, MAX_BID));
        throne.bid(MAX_BID + 1, HASH_A);
    }

    function test_bidAtMaxBidSucceeds() public {
        vm.prank(alice);
        throne.bid(MAX_BID, HASH_A);
        assertEq(_pendingAmount(), MAX_BID);
    }

    // ------------------------------------------------------------------
    // Reject / expire / approve window
    // ------------------------------------------------------------------

    function test_rejectRefundsBidderInFull() public {
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.expectEmit(true, false, false, true);
        emit Throne.BidRejected(alice, STARTING_PRICE);
        vm.prank(moderator);
        throne.reject();

        assertFalse(throne.hasPending());
        assertEq(_throneOwner(), address(0));
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(address(throne)), 0);
        assertEq(throne.minNextBid(), STARTING_PRICE);
    }

    function test_expireRevertsBeforeDeadline() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.prank(stranger);
        vm.expectRevert(Throne.ReviewWindowOpen.selector);
        throne.expire();

        vm.warp(_pendingDeadline());
        vm.prank(stranger);
        vm.expectRevert(Throne.ReviewWindowOpen.selector);
        throne.expire();
    }

    function test_expireRefundsAfterDeadline() public {
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);
        uint64 deadline = _pendingDeadline();

        vm.warp(uint256(deadline) + 1);
        vm.expectEmit(true, false, false, true);
        emit Throne.BidExpired(alice, STARTING_PRICE);
        vm.prank(stranger);
        throne.expire();

        assertFalse(throne.hasPending());
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(address(throne)), 0);
    }

    function test_approveRevertsAfterDeadline() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);
        vm.warp(uint256(_pendingDeadline()) + 1);

        vm.prank(moderator);
        vm.expectRevert(Throne.ReviewWindowClosed.selector);
        throne.approve();
    }

    function test_approveAllowedAtDeadline() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);
        vm.warp(_pendingDeadline());

        vm.prank(moderator);
        throne.approve();
        assertEq(_throneOwner(), alice);
    }

    function test_approveRejectExpireRevertWithNoPending() public {
        vm.prank(moderator);
        vm.expectRevert(Throne.NoPendingBid.selector);
        throne.approve();

        vm.prank(moderator);
        vm.expectRevert(Throne.NoPendingBid.selector);
        throne.reject();

        vm.expectRevert(Throne.NoPendingBid.selector);
        throne.expire();
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_nonModeratorCannotApproveOrReject() public {
        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.prank(stranger);
        vm.expectRevert(Throne.NotModerator.selector);
        throne.approve();

        vm.prank(owner);
        vm.expectRevert(Throne.NotModerator.selector);
        throne.reject();
    }

    function test_moderatorCannotChangeRules() public {
        vm.startPrank(moderator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        throne.setModerator(stranger);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        throne.setTreasury(stranger);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        throne.setMaxBid(MAX_BID * 2);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        throne.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        throne.unpause();
        vm.stopPrank();
    }

    function test_moderatorCannotWithdrawOthersFunds() public {
        vm.prank(moderator);
        vm.expectRevert(Throne.NothingToWithdraw.selector);
        throne.withdraw();
    }

    function test_ownerAdminSetters() public {
        address newMod = makeAddr("newMod");
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        throne.setModerator(newMod);
        assertEq(throne.moderator(), newMod);

        vm.prank(owner);
        throne.setTreasury(newTreasury);
        assertEq(throne.treasury(), newTreasury);

        vm.prank(owner);
        throne.setMaxBid(STARTING_PRICE);
        assertEq(throne.maxBid(), STARTING_PRICE);

        vm.prank(owner);
        vm.expectRevert(Throne.ZeroAddress.selector);
        throne.setModerator(address(0));

        vm.prank(owner);
        vm.expectRevert(Throne.ZeroAddress.selector);
        throne.setTreasury(address(0));

        vm.prank(owner);
        vm.expectRevert(Throne.InvalidConfig.selector);
        throne.setMaxBid(STARTING_PRICE - 1);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(Throne.RenounceDisabled.selector);
        throne.renounceOwnership();
        assertEq(throne.owner(), owner);
    }

    function test_strangerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        throne.pause();
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_pauseBlocksBidsOnly() public {
        vm.prank(owner);
        throne.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.prank(owner);
        throne.unpause();

        vm.prank(alice);
        throne.bid(STARTING_PRICE, HASH_A);

        vm.prank(owner);
        throne.pause();

        // approve still works
        vm.prank(moderator);
        throne.approve();
        assertEq(_throneOwner(), alice);

        // reject still works
        vm.prank(owner);
        throne.unpause();
        uint256 minBid = throne.minNextBid();
        vm.prank(bob);
        throne.bid(minBid, HASH_B);
        vm.prank(owner);
        throne.pause();
        vm.prank(moderator);
        throne.reject();
        assertFalse(throne.hasPending());

        // expire still works
        vm.prank(owner);
        throne.unpause();
        minBid = throne.minNextBid();
        vm.prank(bob);
        throne.bid(minBid, HASH_B);
        vm.prank(owner);
        throne.pause();
        vm.warp(uint256(_pendingDeadline()) + 1);
        vm.prank(stranger);
        throne.expire();
        assertFalse(throne.hasPending());
    }

    function test_pauseDoesNotBlockWithdraw() public {
        RevertingUSDC bad = new RevertingUSDC();
        Throne t = new Throne(address(bad), owner, moderator, treasury, STARTING_PRICE, MAX_BID);
        bad.mint(alice, STARTING_PRICE);
        vm.prank(alice);
        bad.approve(address(t), type(uint256).max);

        vm.prank(alice);
        t.bid(STARTING_PRICE, HASH_A);
        bad.setBlocked(treasury, true);
        vm.prank(moderator);
        t.approve();
        assertEq(t.claimable(treasury), STARTING_PRICE);

        vm.prank(owner);
        t.pause();

        bad.setBlocked(treasury, false);
        vm.prank(treasury);
        t.withdraw();
        assertEq(bad.balanceOf(treasury), STARTING_PRICE);
    }

    // ------------------------------------------------------------------
    // Deferred payouts
    // ------------------------------------------------------------------

    function test_failedPayoutGoesToClaimableAndWithdrawWorks() public {
        RevertingUSDC bad = new RevertingUSDC();
        Throne t = new Throne(address(bad), owner, moderator, treasury, STARTING_PRICE, MAX_BID);
        bad.mint(alice, STARTING_PRICE);
        bad.mint(bob, 2_000_000);
        vm.prank(alice);
        bad.approve(address(t), type(uint256).max);
        vm.prank(bob);
        bad.approve(address(t), type(uint256).max);

        vm.prank(alice);
        t.bid(STARTING_PRICE, HASH_A);
        vm.prank(moderator);
        t.approve();

        uint256 minBid = t.minNextBid();
        uint256 refund = _refundBonus(STARTING_PRICE);
        vm.prank(bob);
        t.bid(minBid, HASH_B);

        bad.setBlocked(alice, true);
        vm.expectEmit(true, false, false, true);
        emit Throne.PayoutDeferred(alice, refund);
        vm.prank(moderator);
        t.approve();

        assertEq(t.claimable(alice), refund);
        assertEq(bad.balanceOf(address(t)), refund);
        assertEq(bad.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(); // still blocked; SafeERC20 reverts
        t.withdraw();

        bad.setBlocked(alice, false);
        vm.expectEmit(true, false, false, true);
        emit Throne.Withdrawn(alice, refund);
        vm.prank(alice);
        t.withdraw();

        assertEq(t.claimable(alice), 0);
        assertEq(bad.balanceOf(alice), refund);
        assertEq(bad.balanceOf(address(t)), 0);

        vm.prank(alice);
        vm.expectRevert(Throne.NothingToWithdraw.selector);
        t.withdraw();
    }

    function test_falseReturningTransferIsDeferred() public {
        FalseReturningUSDC bad = new FalseReturningUSDC();
        Throne t = new Throne(address(bad), owner, moderator, treasury, STARTING_PRICE, MAX_BID);
        bad.mint(alice, STARTING_PRICE);
        vm.prank(alice);
        bad.approve(address(t), type(uint256).max);

        vm.prank(alice);
        t.bid(STARTING_PRICE, HASH_A);
        bad.setBlocked(treasury, true);
        vm.prank(moderator);
        t.approve();

        assertEq(t.claimable(treasury), STARTING_PRICE);
        assertEq(bad.balanceOf(address(t)), STARTING_PRICE);

        bad.setBlocked(treasury, false);
        vm.prank(treasury);
        t.withdraw();
        assertEq(bad.balanceOf(treasury), STARTING_PRICE);
    }

    function test_invariantHoldsAfterHappyPath() public {
        _seat(alice, STARTING_PRICE, HASH_A);
        uint256 minBid = throne.minNextBid();
        vm.prank(bob);
        throne.bid(minBid, HASH_B);
        assertEq(token.balanceOf(address(throne)), _pendingAmount() + throne.claimable(alice) + throne.claimable(treasury));
        vm.prank(moderator);
        throne.approve();
        assertEq(token.balanceOf(address(throne)), throne.claimable(alice) + throne.claimable(bob) + throne.claimable(treasury));
    }
}
