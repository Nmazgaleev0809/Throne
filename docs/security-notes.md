# Security notes (Throne.sol)

Phase 1. Slither did **not** run on this machine: no Python, Docker, or WSL. Findings below are a line-by-line review against `PROJECT_BRIEF.md` §5 plus the items Slither usually flags on this design. Re-run Slither when a toolchain exists and append the raw report.

**HUMAN — to run Slither:** install Python 3.12 (or WSL/Docker), then from the repo root:

```powershell
python -m pip install slither-analyzer
cd contracts
slither . --filter-paths "lib/"
```

Paste the report here (or leave it next to this file as `docs/slither.txt`) so each detector can be marked fixed / accepted.

## Brief §5 vs source

| Brief | Source | Status |
|---|---|---|
| `BPS=10000`, `MIN_INCREMENT_BPS=1000`, `REFUND_BONUS_BPS=500`, `REVIEW_TIMEOUT=15 minutes` | `Throne.sol` constants | Match. Not changed. |
| Immutables `token`, `startingPrice`; admin `moderator`, `treasury`, `maxBid` | yes | Match |
| `throne {owner, price, contentHash, since}`, `pending {bidder, amount, contentHash, deadline}`, `claimable` | yes | Match |
| `bid`: approve first; reverts PendingBidExists, EmptyContentHash, BidTooLow, BidTooHigh, paused | yes | Match |
| `approve` (moderator, before deadline): previous owner `price + 5%`, rest treasury, new owner | yes | Match |
| `reject` full refund; `expire` anyone after deadline full refund; `withdraw` pull claimable | yes | Match |
| Failed pushes credit `claimable` instead of reverting | `_payout` try/catch + bool false | Match |
| Views `minNextBid`, `hasPending`, `throne`, `pending`, `claimable` | yes | Match |
| Admin: setModerator/Treasury/MaxBid, pause/unpause (pause only new bids), renounce disabled | yes | Match |
| Events BidPlaced/Approved/Rejected/Expired, PayoutDeferred, Withdrawn, admin events | yes | Match |
| Invariant `balance == pending.amount + sum(claimable)` | fuzzed in `ThroneInvariant.t.sol` | Match |

## Triage (manual)

| Item | Verdict | Why |
|---|---|---|
| Reentrancy on `bid` (pending written before `safeTransferFrom`) | **Accepted** | `nonReentrant` + pending lock: a reentering `bid` hits `PendingBidExists`. Failed transfer reverts the whole tx. |
| Reentrancy on `approve`/`reject`/`expire` | **Accepted** | Effects (delete pending / write throne / zero claimable) before `_payout` / `safeTransfer`. `nonReentrant`. |
| `_payout` uses `transfer` not `safeTransfer` | **Accepted** | Need try/catch so a blacklisted USDC recipient cannot jam the throne. `withdraw` uses `safeTransfer`. Token is USDC, not an arbitrary ERC20. |
| Fee-on-transfer / rebasing tokens break the invariant | **Accepted** | Locked to USDC on Base. |
| `price * 11000` overflow if `maxBid` is near `type(uint256).max` | **Accepted** | Launch `maxBid` is a small USDC cap. Owner must not set `maxBid` near 2^256. |
| Moderator can ignore a bid until timeout (grief 15 min) | **Accepted** | Trust model: hot key can only approve/reject; timeout refunds. Do not reuse this key. |
| `reject()` allowed after the deadline | **Accepted** | Brief does not restrict it. Outcome is the same as `expire` (full refund). |
| Approve at `timestamp == deadline`, expire only after | **Accepted** | Matches the inequalities in source. |
| `Ownable2Step` + `renounceOwnership` disabled | **Accepted** | Prevents a stuck ownerless contract. |
| Constructor allows `owner == moderator` | **Accepted** | Testnet convenience; production should use distinct cold/hot keys. |
| Pause does not freeze approve/reject/expire/withdraw | **Accepted** | Brief: pause only blocks new bids. |
| Timestamp `uint64` deadline | **Accepted** | `block.timestamp + 15 minutes` fits `uint64` for the lifetime of the chain. |
| No on-chain content checks | **Accepted** | Hash only; backend + moderator are the content gate. |
| Inherited OZ `transferOwnership` not covered by Throne tests | **Accepted** | OZ Ownable2Step; not custom logic. |

Do not treat this table as a Slither run. When Slither works, add a new section with detector name, severity, and fixed/accepted.
