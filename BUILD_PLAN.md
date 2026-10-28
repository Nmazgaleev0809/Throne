# Build plan: from passing contract tests to launch-ready

Status at start: Foundry project set up, contract tests from the brief pass. Backend written (`/backend`), never run end-to-end. Frontend not started.
Rules of engagement are in `.cursor/rules/throne.mdc`. Decisions are in `PROJECT_BRIEF.md`. Log progress in `PROGRESS.md`.

**GATE** = stop, summarize results, and wait for the user before continuing.
**HUMAN** = a step only the user can do (accounts, keys, funds, legal). Tell them exactly what to do.

---

## Phase 0: Repo hygiene
1. Create `PROGRESS.md`, `.gitignore` (env, keys, db, images, `out/`, `cache/`, `broadcast/` secrets, `node_modules`, `.venv`, `__pycache__`, `dist/`), and `.gitattributes` (`* text=auto eol=lf`).
2. Confirm layout: `/contracts`, `/backend`, `/frontend`, `/deployments`, `/docs`.
3. Add a root `README.md` with one-command-per-task instructions (test contracts, run backend, run frontend) that work on Windows.
**Done when:** a fresh clone can follow the README to run the contract tests.

## Phase 1: Contract hardening
1. Run `forge coverage`. Close gaps, especially: failed-payout path (use a mock token that reverts on transfer), pause behavior, approve-after-deadline, expire-before-deadline, first bid, overbid, rounding at tiny and huge prices, `maxBid`.
2. Add a Foundry invariant/fuzz test: `token.balanceOf(throne) == pending.amount + sum(claimable)` across random sequences of bid/approve/reject/expire/withdraw.
3. Run Slither (use WSL or Docker if native Windows fails). Triage every finding in `docs/security-notes.md` (fixed / accepted + why).
4. Re-read `Throne.sol` line by line against the brief section 5. Do not alter the fixed constants.
5. Write a deploy script `contracts/script/Deploy.s.sol` reading constructor args from env (token, owner, moderator, treasury, startingPrice, maxBid).
6. Add a script that exports the ABI to `/backend` and `/frontend` (single source: forge artifacts), and a check that fails if they drift.
**GATE 1:** show coverage numbers, Slither triage, and invariant results.

## Phase 2: Base Sepolia deployment
1. **HUMAN:** create 3 throwaway wallets (owner, moderator, treasury) used only for testnet; get Base Sepolia ETH from a faucet; get a Base Sepolia RPC URL (Alchemy/QuickNode); confirm the testnet USDC address from Circle's docs. Put values in `contracts/.env` (gitignored).
2. Deploy with the script (tiny `startingPrice` e.g. 1 USDC, low `maxBid` e.g. 100 USDC). Verify the source on the explorer.
3. Save addresses and the deployment block in `deployments/base-sepolia.json`.
**GATE 2:** user confirms the deployment and explorer link.

## Phase 3: Backend end-to-end
1. Set up venv, install requirements, fill `backend/.env` (deployment block, moderator key, Telegram). **HUMAN:** create the Telegram bot via BotFather and get their numeric Telegram user ID.
2. Start the backend. Confirm startup: moderator key matches the contract, watcher syncs, no errors. Fix real bugs you find (the code has never run against a chain). Keep a log of each bug in `PROGRESS.md`.
3. Write `scripts/sim_bidder.py` (dev tool): uploads content, approves USDC, calls `bid()`, with flags for text/image, custom amount, and a second wallet.
4. Walk this checklist and record results: text bid auto-approves after the veto window; text bid vetoed in Telegram → full refund; image bid approved in Telegram; image bid rejected; image bid untouched → refunded after 15 min; blocked text rejected at upload; second bid while pending reverts and `/api/state` shows `pending` without content; previous owner receives price + 5%; overbid works; `/images` only serves approved images; backend restart resumes from the cursor without duplicates.
5. Write the pytest suite from the brief section 8 (normalization, blocklist, links, image edge cases, hashing, min-bid parity with the contract, watcher with fake events, moderation loop with a fake chain).
**GATE 3:** checklist results and passing tests.

## Phase 4: Frontend
1. Scaffold `/frontend`: Vite + React + TypeScript, wagmi + viem + RainbowKit, mobile-first, static build. ABI comes from the exported file. Config via `VITE_*` env (API base URL, chain, contract).
2. Build exactly what brief section 7 specifies: the king display with reign timer, live polling, pending banner with countdown, bid form (message counter, image preview, amount defaulting to the minimum with overbid allowed), full bid flow (connect → network check → upload → allowance → bid → waiting for review → outcome), friendly error mapping, "Claim your refund" when `claimable > 0`, Hall of Kings, Terms, How it works.
3. Handle edge states: no king yet, loading, API down, wallet rejected, wrong network, image too large, pending bid by someone else.
4. Add Playwright (or similar) tests for the main flows with the API mocked; manual e2e on Sepolia through the real page using two wallets.
**GATE 4:** user tries the full flow in a browser (desktop and phone) and approves the look and feel. Ask them for design preferences (colors, tone, logo) before polishing.

## Phase 5: Robustness and security pass
1. Backend: structured logging, graceful RPC failures and retries, request size limits, strict CORS (only the real domain), security headers, rate limits reviewed, startup config validation with clear errors, DB backup script.
2. Frontend: CSP-friendly build, no secrets, sanitized rendering (messages are plain text, never HTML), accessible markup.
3. Re-run all tests. Run `pip-audit` / `npm audit` and address findings.
4. Write `docs/runbook.md`: how to pause the contract, rotate the moderator key (`setModerator`), change treasury, raise `maxBid`, sweep treasury profits, restore from backup, what to do if the RPC or Telegram is down.
**GATE 5:** user reviews the runbook.

## Phase 6: Content and growth assets
1. Terms page text from the brief (fixed rules, refunds, moderation, banned content, no other refunds, own tax/legal responsibility). Mark it "draft: needs legal review". **HUMAN:** decide final wording.
2. **HUMAN:** fill `backend/app/blocklist.txt` with real terms (English and Russian). Do not generate slurs yourself; give a category checklist and let the user fill it.
3. Share-image generator for each takeover (server-side image: king's message, price, "dethroned X"), Open Graph tags, and a one-tap share button.
4. Basic privacy-respecting analytics (visitors, bids, referrer) with no third-party trackers by default.
**GATE 6:** user approves the Terms draft and the share image.

## Phase 7: Deployment preparation (no mainnet yet)
1. Backend: Dockerfile + `docker-compose.yml` (or systemd unit), single worker, persistent volumes for DB and images, healthcheck, restart policy.
2. Reverse proxy config (Caddy or nginx), HTTPS, Cloudflare notes (trust `CF-Connecting-IP` only if the origin accepts traffic solely from Cloudflare).
3. Frontend static build and hosting instructions.
4. **HUMAN:** buy the domain and VPS (crypto-payable provider), set up Cloudflare, create the real Telegram bot, prepare REAL wallets (cold owner, hot moderator, treasury) and keep the cold key offline.
5. Write `docs/mainnet-checklist.md` with exact commands and a go/no-go list.
**GATE 7:** user confirms infrastructure is ready.

## Phase 8: Mainnet launch (explicit confirmation required at every step)
1. **HUMAN:** verify the native USDC address on Base from Circle's official docs; send it in chat so it goes into the deploy env.
2. Deploy with a LOW `maxBid` and the real `startingPrice`; verify the source on the explorer.
3. Point the backend at mainnet (`START_BLOCK` = deployment block), fund the moderator wallet with a little ETH, deploy frontend and backend.
4. Smoke test with the user's own small bids from two wallets, then reject/expire/refund paths once.
5. Seed the first bids (user's plan), then public launch per `PROJECT_BRIEF.md` section 10.
6. First week: watch logs and Telegram alerts, sweep the treasury regularly, raise `maxBid` only in steps.

---

## Definition of done (launch-ready)
- [ ] All contract tests, the invariant fuzz test and backend tests pass; frontend e2e passes.
- [ ] Slither triage complete; `npm audit` / `pip-audit` clean or justified.
- [ ] Full Sepolia cycle verified through the real page on desktop and phone.
- [ ] Runbook written and rehearsed (pause, rotate moderator key, restore backup).
- [ ] Terms reviewed by the user; blocklist filled; legal/tax check done by the user.
- [ ] Infra ready: HTTPS, Cloudflare, backups, monitoring/alerts.
- [ ] Mainnet contract deployed and verified with a low `maxBid`; smoke test passed.
