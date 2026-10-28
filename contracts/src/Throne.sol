// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Throne
 * @notice A single homepage slot anyone can take over by paying at least 10% more
 *         than the current owner paid. Bids sit in escrow while a moderator reviews
 *         the content (off-chain; only its hash is stored here).
 *
 * Rules (fixed, compiled in as constants):
 *  - Minimum bid: 110% of the current price (higher bids allowed).
 *  - On approval, the previous owner is refunded their payment + 5%.
 *  - The remainder goes to the treasury.
 *  - A pending bid locks the throne; other bids revert until it resolves.
 *  - If not approved within 15 minutes, anyone can call expire() to refund the bidder.
 *
 * Trust model:
 *  - The moderator key can only approve or reject the pending bid. It cannot
 *    withdraw funds or change the rules.
 *  - Funds only ever move to: the previous owner, the bidder, or the treasury.
 *  - Payouts that fail (e.g. a blacklisted recipient) are credited to `claimable`
 *    instead of reverting, so one bad address can never lock the throne.
 *
 * Invariant: token.balanceOf(this) == pending.amount + sum(claimable).
 */
contract Throne is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Fixed rules
    // ---------------------------------------------------------------------
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_INCREMENT_BPS = 1_000; // 10%
    uint256 public constant REFUND_BONUS_BPS = 500; // 5%
    uint256 public constant REVIEW_TIMEOUT = 15 minutes;

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------
    IERC20 public immutable token; // USDC (6 decimals on Base)
    uint256 public immutable startingPrice; // minimum first bid, in token units

    address public moderator; // hot key held by the backend
    address public treasury; // where profits go; sweep regularly
    uint256 public maxBid; // launch safety cap on a single bid

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    struct Reign {
        address owner;
        uint256 price;
        bytes32 contentHash;
        uint64 since;
    }

    struct Pending {
        address bidder;
        uint256 amount;
        bytes32 contentHash;
        uint64 deadline;
    }

    Reign public throne;
    Pending public pending;
    mapping(address => uint256) public claimable;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event BidPlaced(address indexed bidder, uint256 amount, bytes32 contentHash, uint64 deadline);
    event BidApproved(
        address indexed newOwner,
        address indexed previousOwner,
        uint256 amount,
        uint256 refundToPrevious,
        uint256 toTreasury,
        bytes32 contentHash
    );
    event BidRejected(address indexed bidder, uint256 amount);
    event BidExpired(address indexed bidder, uint256 amount);
    event PayoutDeferred(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ModeratorChanged(address indexed newModerator);
    event TreasuryChanged(address indexed newTreasury);
    event MaxBidChanged(uint256 newMaxBid);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ZeroAddress();
    error InvalidConfig();
    error NotModerator();
    error PendingBidExists();
    error NoPendingBid();
    error EmptyContentHash();
    error BidTooLow(uint256 minimum);
    error BidTooHigh(uint256 maximum);
    error ReviewWindowClosed();
    error ReviewWindowOpen();
    error NothingToWithdraw();
    error RenounceDisabled();

    modifier onlyModerator() {
        if (msg.sender != moderator) revert NotModerator();
        _;
    }

    constructor(
        address _token,
        address _owner,
        address _moderator,
        address _treasury,
        uint256 _startingPrice,
        uint256 _maxBid
    ) Ownable(_owner) {
        if (_token == address(0) || _moderator == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        if (_startingPrice == 0 || _maxBid < _startingPrice) revert InvalidConfig();

        token = IERC20(_token);
        moderator = _moderator;
        treasury = _treasury;
        startingPrice = _startingPrice;
        maxBid = _maxBid;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The lowest amount that can currently be bid (rounded up).
    function minNextBid() public view returns (uint256) {
        if (throne.owner == address(0)) return startingPrice;
        return (throne.price * (BPS + MIN_INCREMENT_BPS) + BPS - 1) / BPS;
    }

    function hasPending() external view returns (bool) {
        return pending.bidder != address(0);
    }

    // ---------------------------------------------------------------------
    // Bidding
    // ---------------------------------------------------------------------

    /**
     * @notice Place a bid. Caller must first approve this contract for `amount` tokens.
     * @param amount Tokens to pay (>= minNextBid()). Anything above the minimum
     *               becomes the new price, and is pure margin beyond the refund.
     * @param contentHash Hash of the message + image uploaded to the backend.
     */
    function bid(uint256 amount, bytes32 contentHash) external nonReentrant whenNotPaused {
        if (pending.bidder != address(0)) revert PendingBidExists();
        if (contentHash == bytes32(0)) revert EmptyContentHash();

        uint256 minimum = minNextBid();
        if (amount < minimum) revert BidTooLow(minimum);
        if (amount > maxBid) revert BidTooHigh(maxBid);

        uint64 deadline = uint64(block.timestamp + REVIEW_TIMEOUT);
        pending = Pending({bidder: msg.sender, amount: amount, contentHash: contentHash, deadline: deadline});

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit BidPlaced(msg.sender, amount, contentHash, deadline);
    }

    /// @notice Moderator approves the pending bid before its deadline.
    function approve() external onlyModerator nonReentrant {
        Pending memory p = pending;
        if (p.bidder == address(0)) revert NoPendingBid();
        if (block.timestamp > p.deadline) revert ReviewWindowClosed();

        Reign memory prev = throne;

        // Effects
        delete pending;
        throne = Reign({owner: p.bidder, price: p.amount, contentHash: p.contentHash, since: uint64(block.timestamp)});

        uint256 refund = 0;
        if (prev.owner != address(0)) {
            // Safe: p.amount >= 110% of prev.price > 105% of prev.price.
            refund = prev.price + (prev.price * REFUND_BONUS_BPS) / BPS;
        }
        uint256 toTreasury = p.amount - refund;

        emit BidApproved(p.bidder, prev.owner, p.amount, refund, toTreasury, p.contentHash);

        // Interactions
        if (refund > 0) _payout(prev.owner, refund);
        if (toTreasury > 0) _payout(treasury, toTreasury);
    }

    /// @notice Moderator rejects the pending bid; the bidder is refunded in full.
    function reject() external onlyModerator nonReentrant {
        Pending memory p = _clearPending();
        emit BidRejected(p.bidder, p.amount);
        _payout(p.bidder, p.amount);
    }

    /// @notice Anyone can expire a pending bid after the review window; bidder is refunded in full.
    function expire() external nonReentrant {
        Pending memory p = pending;
        if (p.bidder == address(0)) revert NoPendingBid();
        if (block.timestamp <= p.deadline) revert ReviewWindowOpen();

        delete pending;
        emit BidExpired(p.bidder, p.amount);
        _payout(p.bidder, p.amount);
    }

    /// @notice Pull any deferred payout (only needed if a push transfer failed).
    function withdraw() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Admin (owner = cold key)
    // ---------------------------------------------------------------------

    function setModerator(address newModerator) external onlyOwner {
        if (newModerator == address(0)) revert ZeroAddress();
        moderator = newModerator;
        emit ModeratorChanged(newModerator);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function setMaxBid(uint256 newMaxBid) external onlyOwner {
        if (newMaxBid < startingPrice) revert InvalidConfig();
        maxBid = newMaxBid;
        emit MaxBidChanged(newMaxBid);
    }

    /// @notice Pausing only blocks new bids. Approve/reject/expire/withdraw keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Disabled: renouncing would leave the contract with no admin.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _clearPending() private returns (Pending memory p) {
        p = pending;
        if (p.bidder == address(0)) revert NoPendingBid();
        delete pending;
    }

    /// @dev Try to push tokens; if the transfer fails (e.g. recipient blacklisted),
    ///      credit the recipient so they can withdraw later. Never reverts.
    function _payout(address to, uint256 amount) private {
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) _defer(to, amount);
        } catch {
            _defer(to, amount);
        }
    }

    function _defer(address to, uint256 amount) private {
        claimable[to] += amount;
        emit PayoutDeferred(to, amount);
    }
}
