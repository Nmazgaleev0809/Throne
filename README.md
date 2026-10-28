# The Throne

One homepage slot. Pay at least 10% more than the current king (USDC on Base) to take it. Content is moderated before it goes live.

Decisions: `PROJECT_BRIEF.md`. Build order: `BUILD_PLAN.md`. Log: `PROGRESS.md`.

## Prerequisites (Windows)

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` on PATH). Windows binaries work; Git is required for some Foundry workflows.
- Python 3.11+ (`py -3`)
- Node.js 20+ (frontend, later)

From PowerShell, repo root:

## Test the contract

```powershell
cd contracts
forge test
```

Coverage:

```powershell
cd contracts
forge coverage --report summary
```

Export / check the ABI (writes `backend/app/abi/Throne.json` and `frontend/src/abi/Throne.json`):

```powershell
powershell -File scripts/export_abi.ps1
powershell -File scripts/export_abi.ps1 -Check
```

## Run the backend

Needs a deployed contract and a filled `backend/.env` (see `backend/.env.example`). One worker only.

```powershell
cd backend
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## Run the frontend

Not scaffolded yet (Phase 4). Placeholder:

```powershell
cd frontend
npm install
npm run dev
```

## Layout

```
contracts/    Throne.sol, Foundry tests, deploy script
backend/     FastAPI app
frontend/     Vite + React (not started)
deployments/  Saved addresses and start blocks
docs/         Security notes, runbook
```
