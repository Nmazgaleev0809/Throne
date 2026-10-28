# The Throne: project brief

Put this file at the repo root (rename to `CLAUDE.md` if your editor reads that name). It is the single source of truth for decisions already made. **Do not change anything under "Locked decisions" without asking the owner first.**

## 1. What we're building

A viral website with ONE slot on the homepage: a message (≤256 chars) plus an optional image, held by the current "king". Anyone can take the throne by paying at least 10% more than the current price. The previous king is refunded what they paid plus 5%. The operator keeps the rest. Payments are USDC on Base, enforced by a smart contract in escrow. Content is moderated before it goes live.

Why it should spread: five-second concept, public price ladder, screenshots of takeovers, escalating price, a visible "someone is trying to take over" moment.

Operator constraints: works from Russia, crypto-only payments, no foreign legal entity. Hosting and services should be payable in crypto. Stablecoin issuers can freeze addresses, so treasury profits are swept out regularly. Check tax and legal exposure (including the refund bonus looking like a game of chance in some jurisdictions) before taking real money.

## 2. Locked decisions

**Pricing (fixed, compiled into the contract as constants)**
- Minimum bid = 110% of the current price (rounded up). Higher bids are allowed; the minimum is also the default.
- On approval the previous owner gets their payment + 5% back. Everything else goes to the treasury.
- First bid minimum = `startingPrice` (planned: 1 USDC).
- Single open throne. No teams.

**Flow and locking**
- A bid is escrowed in the contract. While a bid is pending, NO other bids are allowed (contract reverts). The site shows a public banner that someone is trying to take over, with a countdown. Pending content is never shown publicly.
- Review window: 15 minutes. After that, anyone can call `expire()` and the bidder is refunded in full.
- Rejected bid → full refund. Expired bid → full refund. Refund rules are published on a Terms page.

**Moderation**
- Text is checked at upload time (before any payment): Unicode normalization, 256-char limit, blocklist (leetspeak/homoglyph-aware skeleton matching, Latin + Cyrillic), links banned by default.
- Text-only bid that passes: auto-approved after a 120 s veto window; the owner gets a Telegram notice with a Veto button.
- Any bid with an image: NEVER auto-approved. Owner approves or rejects in Telegram. If untouched, the 15-minute timeout refunds the bidder.
- Bid whose content hash matches no upload, or whose stored content fails re-checks → rejected.

**Images**
- PNG/JPG/WebP only. Raw upload ≤ 5 MB. Larger dimensions are downscaled (never rejected) to fit within 1920x1080, keeping aspect ratio. No animation. Re-encoded to WebP server-side (strips all metadata). Only approved images are publicly served.

**Tech**
- Chain: Base. Token: USDC (6 decimals). **Verify the native USDC address on Base from Circle's official docs; never trust an address from memory or chat.**
- Contract: Solidity ^0.8.24 + OpenZeppelin v5. Escrow design with two keys: owner (cold key: admin, pause, set moderator/treasury/maxBid) and moderator (hot key in backend: can ONLY approve/reject).
- Backend: Python, FastAPI, SQLAlchemy (SQLite for launch), web3.py v7, python-telegram-bot v21, Pillow. Runs as ONE worker.
- Frontend: framework-based. Vite + React + TypeScript, wagmi + viem + RainbowKit, mobile-first, built as static files.

## 3. Repo layout (suggested)

```
/contracts   Throne.sol + Foundry project (src/, test/, script/)
/backend     FastAPI app (see backend README)
/frontend    Vite + React + TS app
PROJECT_BRIEF.md
```

## 4. Current status

| Piece | State |
|---|---|
| `Throne.sol` | Drafted, NOT compiled or tested |
| Backend (`throne-backend`) | Written, compiles, content logic smoke-tested. NOT run end-to-end (no chain/Telegram yet) |
| Frontend | Not started |
| Tests, Sepolia deploy, mainnet deploy | Not started |

## 5. Contract summary (`Throne.sol`)

Constants: `BPS=10000`, `MIN_INCREMENT_BPS=1000`, `REFUND_BONUS_BPS=500`, `REVIEW_TIMEOUT=15 minutes`.
Immutables: `token`, `startingPrice`. Admin-settable: `moderator`, `treasury`, `maxBid` (launch safety cap).

State: `throne {owner, price, contentHash, since}`, `pending {bidder, amount, contentHash, deadline}`, `claimable[address]`.

Functions
- `bid(uint256 amount, bytes32 contentHash)`: caller must first `approve` the contract for `amount` USDC. Reverts: `PendingBidExists`, `EmptyContentHash`, `BidTooLow(min)`, `BidTooHigh(max)`, paused.
- `approve()` (moderator, before deadline): pays previous owner `price + price*5%`, rest to treasury, sets new owner.
- `reject()` (moderator): full refund to bidder.
- `expire()` (anyone, after deadline): full refund to bidder.
- `withdraw()`: pull any deferred payout. Failed pushes (e.g. blacklisted recipient) are credited to `claimable` instead of reverting, so one bad address can never lock the throne.
- Views: `minNextBid()`, `hasPending()`, `throne()`, `pending()`, `claimable(addr)`.
- Admin: `setModerator`, `setTreasury`, `setMaxBid`, `pause`/`unpause` (pause only blocks new bids). `renounceOwnership` is disabled.
- Events: `BidPlaced`, `BidApproved`, `BidRejected`, `BidExpired`, `PayoutDeferred`, `Withdrawn`, admin events.

Invariant to fuzz-test: `token.balanceOf(contract) == pending.amount + sum(claimable)`.

## 6. Backend API

- `POST /api/upload` (multipart: `message`, optional `image`). Validates, processes, stores; returns `{content_hash, message, has_image, min_next_bid_units, min_next_bid_usdc, contract, chain_id}`. Rate limited per IP. The bidder passes `content_hash` to `bid()`.
- `GET /api/state` → `{throne|null, pending|null, min_next_bid_units, min_next_bid_usdc, contract, chain_id, server_time}`. `pending` has bidder_short, amount_usdc, deadline, seconds_left and NO content.
- `GET /api/history?limit&offset` → approved kings (Hall of Kings).
- `GET /images/<hash>.webp` → approved images only.
- `GET /health`.
- Amounts: `*_units` are integer strings in 6-decimal units; `*_usdc` are display strings.
- Content hash = sha256 over `"throne-v1\0" | len(message,4 bytes BE) | message utf-8 | sha256(image) or 32 zero bytes`. The backend computes it; the frontend must never compute its own.

## 7. Frontend requirements

Pages/states: Home (the throne), Hall of Kings, Terms, and a small "how it works" explainer.

Home
- Current king: message, image, price, reign timer, short owner address, link to the transaction.
- Live state polling `/api/state` every 3-5 s.
- **Pending banner** when `pending != null`: "Someone is trying to take over the throne…" with a live countdown; bid form disabled.
- Milestone/price-ladder visual (e.g. $100, $1,000, $10,000) and a "dethroned by" feed from history.
- Bid form: message (256-char counter), optional image (client-side preview and size check, but the server is authoritative), amount input defaulting to the minimum (allow higher; show the extra as an "overbid"), clear total cost.
- Bid flow: connect wallet → ensure Base network → `POST /api/upload` → show min bid → check USDC allowance, send `approve` if needed → `bid(amount, contentHash)` → show "waiting for review" state tied to `/api/state` → outcome (approved: you're king; rejected/expired: refunded, explain why).
- Re-fetch the minimum right before sending. Map contract errors to friendly messages (`PendingBidExists`, `BidTooLow`, `BidTooHigh`).
- If `claimable(address) > 0`, show a "Claim your refund" button calling `withdraw()`.
- Share image / share button for every takeover (planned).

Terms page (must state): fixed rules; 10% minimum increment; previous owner refunded +5%; rejected and expired bids refunded in full; moderation policy and banned content; images always manually reviewed (so can take up to 15 minutes); no other refunds; USDC on Base only; users are responsible for their own legal and tax obligations.

UX notes: mobile-first; show amounts to cents but send exact 6-decimal units; never show unapproved content; handle wallet rejections and wrong network gracefully.

## 8. Testing plan (next phase)

Contract (Foundry): happy path and price math; overbid; first bid; reject; expire (only after deadline); approve only before deadline; second bid while pending reverts; `BidTooLow` / `BidTooHigh`; moderator cannot withdraw or change rules; non-moderator can't approve/reject; pause blocks bids but not approve/reject/expire/withdraw; failed payout goes to `claimable` and `withdraw()` works (mock token that reverts); fuzz the balance invariant and rounding.

Backend: unit tests for normalization, blocklist, links, image processing (oversize, animated, corrupt, transparency), hashing stability, `min_bid_for` parity with the contract; watcher tests with fake events; moderation-loop tests with a fake chain.

End-to-end on Base Sepolia (test USDC): upload → bid → text auto-approve; image → Telegram approve; reject; veto; timeout/expire; blocked content; pending banner on the site.

## 9. Deployment checklist

1. Foundry deploy script: constructor args = USDC address (verified), owner (cold wallet), moderator (backend hot key), treasury, `startingPrice` (1 USDC = 1000000), `maxBid` (low at launch, raise later). Verify the contract source on the Base block explorer.
2. Backend `.env` (see `.env.example`): `START_BLOCK` = deployment block. Startup logs an error if the moderator key doesn't match the contract.
3. Fund the moderator wallet with a little ETH on Base (low-gas Telegram alert exists).
4. VPS paid in crypto, Cloudflare in front (DDoS, caching). Trust `CF-Connecting-IP` only if the origin is reachable solely via Cloudflare.
5. Back up `throne.db` and `data/images/`.
6. Fill `backend/app/blocklist.txt` (English and Russian terms).
7. Sweep treasury profits out regularly; don't let a large balance sit there.
8. Consider a professional audit once the site earns enough to justify it.

## 10. Launch plan (after testing)

Seed the first 3-5 bids from friends/communities so the price is already climbing; auto-generated share images per takeover; launch on X, Reddit, Telegram, Hacker News with the story "the price just keeps going up, who's next?"; track daily visitors, bids and referral sources.

## 11. Open items

- Terms page text, domain, hosting provider.
- Blocklist contents.
- How the operator converts earnings to spendable money; legal and tax review.
- Exact `startingPrice` and launch `maxBid`.
- Share-image generator design.

## 12. Working agreements for the AI editor

- Never change locked decisions or contract constants without asking.
- Never commit keys, `.env`, the database or uploaded images. Use `.gitignore`.
- Treat everything user-supplied (message, image, wallet address) as hostile.
- Keep the contract small and simple. Any change to `Throne.sol` needs matching tests.
- Run tests after every meaningful change and report results honestly, including failures.
- When something here is ambiguous or a decision is missing, ask instead of guessing.
