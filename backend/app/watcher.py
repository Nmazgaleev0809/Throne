"""Mirrors contract events into the database. The chain is the source of truth."""
import asyncio
import logging

from sqlalchemy import select
from web3 import Web3

from .chain import ThroneChain
from .config import settings
from .db import Bid, Meta, SessionLocal, now

log = logging.getLogger("throne.watcher")
CHUNK = 1500  # blocks per get_logs call (stay under RPC provider limits)
POLL_SECONDS = 5


def _get_cursor(db) -> int:
    row = db.get(Meta, "cursor")
    return int(row.value) if row else settings.start_block - 1


def _set_cursor(db, block: int) -> None:
    row = db.get(Meta, "cursor")
    if row:
        row.value = str(block)
    else:
        db.add(Meta(key="cursor", value=str(block)))


def _latest_pending(db):
    return db.scalar(select(Bid).where(Bid.status == "pending").order_by(Bid.id.desc()))


def apply_event(db, ev: dict) -> None:
    name, a = ev["event"], ev["args"]
    if name == "BidPlaced":
        if db.scalar(select(Bid).where(Bid.tx_hash == ev["tx_hash"])):
            return
        db.add(
            Bid(
                tx_hash=ev["tx_hash"],
                block_number=ev["block"],
                bidder=a["bidder"],
                amount=int(a["amount"]),
                content_hash=Web3.to_hex(a["contentHash"]),
                deadline=int(a["deadline"]),
                status="pending",
                seen_at=now(),
            )
        )
        log.info("BidPlaced %s amount=%s", a["bidder"], a["amount"])
        return

    bid = _latest_pending(db)
    if bid is None:
        log.warning("%s event with no pending bid in DB (tx %s)", name, ev["tx_hash"])
        return
    bid.decided_at = now()
    if name == "BidApproved":
        bid.status = "approved"
        bid.previous_owner = a["previousOwner"]
        bid.refund_to_previous = int(a["refundToPrevious"])
    elif name == "BidRejected":
        bid.status = "rejected"
    elif name == "BidExpired":
        bid.status = "expired"
    log.info("%s bid #%s", name, bid.id)


def sync_once(chain: ThroneChain) -> None:
    with SessionLocal() as db:
        cursor = _get_cursor(db)
        head = chain.latest_block() - settings.confirmations
        while cursor < head:
            end = min(cursor + CHUNK, head)
            for ev in chain.get_events(cursor + 1, end):
                apply_event(db, ev)
            _set_cursor(db, end)
            db.commit()  # events + cursor commit atomically, so a crash never replays or skips
            cursor = end


async def run_watcher(chain: ThroneChain) -> None:
    while True:
        try:
            await asyncio.to_thread(sync_once, chain)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("watcher error")
        await asyncio.sleep(POLL_SECONDS)
