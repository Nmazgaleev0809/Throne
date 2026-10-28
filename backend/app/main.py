import asyncio
import logging
import re
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from sqlalchemy import delete, select

from .chain import ThroneChain
from .config import settings
from .content import ContentError, check_text, compute_content_hash, image_path, normalize_message, process_image
from .db import Bid, SessionLocal, Upload, init_db, now
from .moderation import Notifier, moderation_loop
from .util import fmt_usdc, min_bid_for, short_addr
from .watcher import run_watcher

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("throne")


async def cleanup_loop() -> None:
    """Delete uploads that never became a bid (bidder uploaded, then walked away)."""
    while True:
        try:
            cutoff = now() - settings.orphan_upload_ttl
            with SessionLocal() as db:
                bid_hashes = set(db.scalars(select(Bid.content_hash)))
                stale = db.scalars(select(Upload).where(Upload.created_at < cutoff)).all()
                for up in stale:
                    if up.content_hash in bid_hashes:
                        continue
                    image_path(up.content_hash).unlink(missing_ok=True)
                    db.execute(delete(Upload).where(Upload.id == up.id))
                db.commit()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("cleanup error")
        await asyncio.sleep(3600)


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    (Path(settings.data_dir) / "images").mkdir(parents=True, exist_ok=True)
    chain = ThroneChain()
    app.state.chain = chain
    app.state.starting_price = await asyncio.to_thread(chain.starting_price)
    on_chain_mod = await asyncio.to_thread(chain.on_chain_moderator)
    if on_chain_mod.lower() != chain.account.address.lower():
        log.error("MODERATOR_PRIVATE_KEY (%s) is NOT the contract's moderator (%s)!", chain.account.address, on_chain_mod)
    notifier = Notifier(chain)
    await notifier.start()
    tasks = [
        asyncio.create_task(run_watcher(chain)),
        asyncio.create_task(moderation_loop(chain, notifier)),
        asyncio.create_task(cleanup_loop()),
    ]
    yield
    for t in tasks:
        t.cancel()
    await notifier.stop()


app = FastAPI(title="The Throne", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",")],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# --- naive per-IP rate limit for uploads (in-memory; run ONE worker) -------------
_hits: dict[str, deque] = defaultdict(deque)


def _client_ip(request: Request) -> str:
    # Only trust this header if the server is reachable exclusively through Cloudflare.
    return request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "?")


def _rate_limited(ip: str) -> bool:
    q, t = _hits[ip], time.time()
    while q and t - q[0] > 3600:
        q.popleft()
    if len(q) >= settings.uploads_per_hour:
        return True
    q.append(t)
    return False


# --- serializers -----------------------------------------------------------------
def _content_payload(db, content_hash: str) -> dict:
    up = db.scalar(select(Upload).where(Upload.content_hash == content_hash))
    if up is None:
        return {"message": "", "image_url": None}
    return {
        "message": up.message,
        "image_url": f"/images/{content_hash[2:]}.webp" if up.has_image else None,
    }


def _king(db, bid: Bid) -> dict:
    return {
        "owner": bid.bidder,
        "owner_short": short_addr(bid.bidder),
        "price_units": str(bid.amount),
        "price_usdc": fmt_usdc(bid.amount),
        "since": bid.decided_at,
        "content_hash": bid.content_hash,
        "tx_hash": bid.tx_hash,
        **_content_payload(db, bid.content_hash),
    }


# --- API -------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/api/state")
async def state(request: Request):
    starting = request.app.state.starting_price
    with SessionLocal() as db:
        cur = db.scalar(select(Bid).where(Bid.status == "approved").order_by(Bid.id.desc()))
        pend = db.scalar(select(Bid).where(Bid.status == "pending").order_by(Bid.id.desc()))
        throne = _king(db, cur) if cur else None
        pending = None
        if pend:  # deliberately NO content here: unmoderated content is never shown publicly
            pending = {
                "bidder_short": short_addr(pend.bidder),
                "amount_usdc": fmt_usdc(pend.amount),
                "deadline": pend.deadline,
                "seconds_left": max(0, pend.deadline - now()),
            }
    min_next = min_bid_for(cur.amount if cur else 0, starting)
    return {
        "throne": throne,
        "pending": pending,
        "min_next_bid_units": str(min_next),
        "min_next_bid_usdc": fmt_usdc(min_next),
        "contract": settings.contract_address,
        "chain_id": settings.chain_id,
        "server_time": now(),
    }


@app.get("/api/history")
async def history(limit: int = 50, offset: int = 0):
    limit, offset = max(1, min(limit, 100)), max(0, offset)
    with SessionLocal() as db:
        rows = db.scalars(
            select(Bid).where(Bid.status == "approved").order_by(Bid.id.desc()).limit(limit).offset(offset)
        ).all()
        return {"kings": [_king(db, b) for b in rows]}


@app.post("/api/upload")
async def upload(request: Request, message: str = Form(""), image: UploadFile | None = File(None)):
    if _rate_limited(_client_ip(request)):
        raise HTTPException(429, "Too many uploads. Try again later.")
    try:
        msg = normalize_message(message)
        check_text(msg)
        img_bytes = None
        if image is not None and image.filename:
            raw = await image.read(settings.max_upload_bytes + 1)
            if raw:
                img_bytes = await asyncio.to_thread(process_image, raw)
        if not msg and not img_bytes:
            raise ContentError("Add a message or an image.")
    except ContentError as e:
        raise HTTPException(400, str(e))

    content_hash = compute_content_hash(msg, img_bytes)
    with SessionLocal() as db:
        up = db.scalar(select(Upload).where(Upload.content_hash == content_hash))
        if up:
            up.created_at = now()  # keep it alive for another TTL
        else:
            db.add(Upload(content_hash=content_hash, message=msg, has_image=img_bytes is not None))
        db.commit()
    if img_bytes:
        path = image_path(content_hash)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(img_bytes)

    with SessionLocal() as db:
        cur = db.scalar(select(Bid).where(Bid.status == "approved").order_by(Bid.id.desc()))
    min_next = min_bid_for(cur.amount if cur else 0, request.app.state.starting_price)
    return {
        "content_hash": content_hash,
        "message": msg,
        "has_image": img_bytes is not None,
        "min_next_bid_units": str(min_next),
        "min_next_bid_usdc": fmt_usdc(min_next),
        "contract": settings.contract_address,
        "chain_id": settings.chain_id,
    }


_IMG_RE = re.compile(r"^[0-9a-f]{64}\.webp$")


@app.get("/images/{name}")
async def get_image(name: str):
    """Only images of APPROVED bids are public."""
    if not _IMG_RE.match(name):
        raise HTTPException(404)
    content_hash = "0x" + name[:-5]
    with SessionLocal() as db:
        ok = db.scalar(select(Bid.id).where(Bid.status == "approved", Bid.content_hash == content_hash))
    path = image_path(content_hash)
    if not ok or not path.exists():
        raise HTTPException(404)
    return FileResponse(path, media_type="image/webp", headers={"Cache-Control": "public, max-age=31536000, immutable"})
