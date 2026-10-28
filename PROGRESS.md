# Progress log

Follows `BUILD_PLAN.md`. Newest entries at the top of each phase.

## Phase 0: Repo hygiene

- [x] 0.3 Root `README.md` with Windows PowerShell commands. `cd contracts; forge test` → 32 passed (31 unit + invariant suite, 0 failed).
- [x] 0.2 Layout confirmed: `contracts/`, `backend/`, `frontend/` (`.gitkeep`), `deployments/` (`.gitkeep`), `docs/` (`.gitkeep`).
- [x] 0.1 `PROGRESS.md` present. `.gitignore` covers env, keys, db, images, Foundry `out/`/`cache/`/`broadcast/`, `node_modules`, `.venv`, `__pycache__`, `dist/`. Added `.gitattributes` (`* text=auto eol=lf`).

## Phase 1: Contract hardening

- [ ] 1.1 `forge coverage` and close gaps
- [ ] 1.2 Invariant/fuzz already in `test/ThroneInvariant.t.sol`; re-run
- [ ] 1.3 Slither → `docs/security-notes.md`
- [ ] 1.4 Re-read `Throne.sol` vs brief §5
- [ ] 1.5 Deploy script (already at `contracts/script/Deploy.s.sol`)
- [ ] 1.6 ABI export + drift check

**GATE 1:** not reached.
