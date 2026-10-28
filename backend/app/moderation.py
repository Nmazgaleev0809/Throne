"""Moderation worker + Telegram bot.

Policy:
  * Bid whose content hash matches no upload, or whose stored content fails the checks again -> reject (full refund).
  * Text-only bid that passes: Telegram notice with a Veto button; auto-approved after TEXT_AUTO_APPROVE_DELAY.
  * Bid with an image: NEVER auto-approved. Needs Approve in Telegram. If untouched, the contract's
    15-minute timeout refunds the bidder (this worker also calls expire() so the throne unlocks promptly).
"""
import asyncio
import logging

from sqlalchemy import select
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import Application, CallbackQueryHandler, ContextTypes

from .chain import ThroneChain
from .config import settings
from .content import ContentError, check_text, image_path, jpeg_preview
from .db import Bid, SessionLocal, Upload, now
from .util import fmt_usdc, short_addr

log = logging.getLogger("throne.moderation")
LOOP_SECONDS = 3
RETRY_AFTER = 60  # seconds before re-sending an action whose result hasn't shown up on-chain
MAX_ATTEMPTS = 5
LOW_GAS_ETH = 0.002


async def act(chain: ThroneChain, bid_id: int, action: str) -> str:
    """Send approve/reject/expire for a pending bid, guarded against double-sends."""
    with SessionLocal() as db:
        bid = db.get(Bid, bid_id)
        if bid is None or bid.status != "pending":
            return "Bid is no longer pending."
        if bid.action_sent_at and now() - bid.action_sent_at < RETRY_AFTER:
            return "Action already sent, waiting for confirmation."
        if bid.attempts >= MAX_ATTEMPTS:
            return "Too many failed attempts; check logs."
        bid.action_sent_at = now()
        bid.attempts += 1
        db.commit()
    try:
        tx = await asyncio.to_thread(getattr(chain, action))
        log.info("%s bid #%s tx=%s", action, bid_id, tx)
        return f"{action} sent ({tx[:10]}…)."
    except Exception as e:  # revert on estimation, RPC failure, out of gas, ...
        log.exception("%s failed for bid #%s", action, bid_id)
        return f"{action} failed: {str(e)[:120]}"


class Notifier:
    def __init__(self, chain: ThroneChain) -> None:
        self.chain = chain
        self.app: Application | None = None

    @property
    def enabled(self) -> bool:
        return self.app is not None

    async def start(self) -> None:
        if not settings.telegram_bot_token or not settings.telegram_admin_chat_id:
            log.warning("Telegram not configured: image bids can't be approved and will time out.")
            return
        self.app = Application.builder().token(settings.telegram_bot_token).build()
        self.app.add_handler(CallbackQueryHandler(self._on_button))
        await self.app.initialize()
        await self.app.start()
        await self.app.updater.start_polling()

    async def stop(self) -> None:
        if self.app:
            await self.app.updater.stop()
            await self.app.stop()
            await self.app.shutdown()

    async def alert(self, text: str) -> None:
        if self.app:
            try:
                await self.app.bot.send_message(settings.telegram_admin_chat_id, text)
            except Exception:
                log.exception("telegram alert failed")

    async def notify_new_bid(self, bid: Bid, upload: Upload | None) -> None:
        if not self.app or upload is None:
            return
        head = f"Bid #{bid.id}: ${fmt_usdc(bid.amount)} from {short_addr(bid.bidder)}\n\n"
        body = f"Message: {upload.message or '(none)'}\n"
        if upload.has_image:
            text = head + body + "\nHas an image. Approve or reject (auto-refund after the timeout)."
            kb = [[InlineKeyboardButton("✅ Approve", callback_data=f"approve:{bid.id}"),
                   InlineKeyboardButton("⛔ Reject", callback_data=f"reject:{bid.id}")]]
        else:
            text = head + body + f"\nText only. Auto-approves in {settings.text_auto_approve_delay}s unless vetoed."
            kb = [[InlineKeyboardButton("⛔ Veto", callback_data=f"veto:{bid.id}")]]
        markup = InlineKeyboardMarkup(kb)
        try:
            if upload.has_image:
                data = await asyncio.to_thread(lambda: jpeg_preview(image_path(upload.content_hash).read_bytes()))
                await self.app.bot.send_photo(settings.telegram_admin_chat_id, photo=data, caption=text[:1000], reply_markup=markup)
            else:
                await self.app.bot.send_message(settings.telegram_admin_chat_id, text, reply_markup=markup)
        except Exception:
            log.exception("telegram notify failed for bid #%s", bid.id)

    async def _on_button(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        q = update.callback_query
        if q is None or q.from_user.id != settings.telegram_admin_chat_id:
            if q:
                await q.answer("Not allowed.", show_alert=True)
            return
        try:
            kind, raw_id = (q.data or "").split(":")
            bid_id = int(raw_id)
        except ValueError:
            await q.answer("Bad request.")
            return
        action = {"approve": "approve", "reject": "reject", "veto": "reject"}.get(kind)
        if action is None:
            await q.answer("Unknown action.")
            return
        result = await act(self.chain, bid_id, action)
        await q.answer(result[:190], show_alert=True)
        try:
            await q.edit_message_reply_markup(reply_markup=None)
        except Exception:
            pass


def _passes_checks(upload: Upload) -> bool:
    try:
        check_text(upload.message)
    except ContentError:
        return False
    return not upload.has_image or image_path(upload.content_hash).exists()


async def _handle_pending(chain: ThroneChain, notifier: Notifier) -> None:
    with SessionLocal() as db:
        bid = db.scalar(select(Bid).where(Bid.status == "pending").order_by(Bid.id.desc()))
        if bid is None:
            return
        upload = db.scalar(select(Upload).where(Upload.content_hash == bid.content_hash))
    chain_now = await asyncio.to_thread(chain.latest_timestamp)

    # 1) Review window over: unlock the throne (anyone may call expire()).
    if chain_now > bid.deadline:
        await act(chain, bid.id, "expire")
        return

    # 2) Content missing or no longer passes: reject, bidder is refunded in full.
    if upload is None or not _passes_checks(upload):
        await act(chain, bid.id, "reject")
        return

    # 3) First time we see it: tell the moderator.
    if not bid.notified:
        await notifier.notify_new_bid(bid, upload)
        with SessionLocal() as db:
            row = db.get(Bid, bid.id)
            row.notified = True
            db.commit()
        return

    # 4) Images wait for a human. Text auto-approves after the veto window.
    if upload.has_image:
        return
    if now() - bid.seen_at >= settings.text_auto_approve_delay and chain_now < bid.deadline - 30:
        await act(chain, bid.id, "approve")


async def moderation_loop(chain: ThroneChain, notifier: Notifier) -> None:
    last_gas_check = 0.0
    while True:
        try:
            await _handle_pending(chain, notifier)
            if asyncio.get_event_loop().time() - last_gas_check > 600:
                last_gas_check = asyncio.get_event_loop().time()
                eth = await asyncio.to_thread(chain.moderator_eth_balance)
                if eth < LOW_GAS_ETH:
                    await notifier.alert(f"⚠️ Moderator wallet is low on gas: {eth:.5f} ETH")
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("moderation loop error")
        await asyncio.sleep(LOOP_SECONDS)
