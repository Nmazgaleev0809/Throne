# The Throne: backend

FastAPI service that sits between the web page and the `Throne` contract.

## What it does
- `POST /api/upload`: validates the message (normalize, 256 chars, blocklist, link ban) and image (PNG/JPG/WebP, ≤5 MB, no animation, downscaled to fit 1920x1080, re-encoded to WebP, metadata stripped). Returns a `content_hash` to pass to the contract's `bid(amount, contentHash)`.
- Watcher mirrors contract events (`BidPlaced/Approved/Rejected/Expired`) into SQLite. The chain is the source of truth.
- Moderation worker: text-only bids auto-approve after a veto window; image bids need your Telegram approval; anything unmatched or failing re-checks is rejected (full refund); stale bids are expired.
- `GET /api/state`, `GET /api/history`, `GET /images/<hash>.webp` (approved content only; pending content is never public).

## Setup
```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # fill it in; START_BLOCK = contract deployment block
uvicorn app.main:app --host 0.0.0.0 --port 8000   # ONE worker only
```
Run exactly one worker: the watcher, moderation loop, Telegram bot and rate limiter are in-process.

## Before going live
1. The moderator key in `.env` must equal the contract's `moderator`; the app logs an error at startup if not.
2. Fund the moderator wallet with a little ETH on Base for gas; you get a Telegram alert when it runs low.
3. Fill `app/blocklist.txt` with your own terms (slurs, hate terms, doxxing patterns, Russian and English).
4. Put the server behind Cloudflare, and only trust `CF-Connecting-IP` if the origin is reachable only via Cloudflare.
5. Back up `throne.db` and `data/images/` (they hold the content behind each on-chain hash).

## Known limits (MVP)
- SQLite and in-memory rate limiting are fine for launch; move to Postgres/Redis if traffic grows.
- Blocklist matching is substring-based on a normalized "skeleton", so very short terms over-block.
- No automated NSFW classifier: images rely on your manual approval.
