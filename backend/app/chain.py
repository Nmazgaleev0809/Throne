"""Thin web3 wrapper around the Throne contract. All methods are synchronous (call via to_thread)."""
import json
import threading
from pathlib import Path

from eth_account import Account
from web3 import Web3

from .config import settings

_ABI_PATH = Path(__file__).resolve().parent / "abi" / "Throne.json"
ABI = json.loads(_ABI_PATH.read_text(encoding="utf-8"))

EVENT_NAMES = ["BidPlaced", "BidApproved", "BidRejected", "BidExpired"]


class ThroneChain:
    def __init__(self) -> None:
        self.w3 = Web3(Web3.HTTPProvider(settings.rpc_url, request_kwargs={"timeout": 20}))
        self.contract = self.w3.eth.contract(address=Web3.to_checksum_address(settings.contract_address), abi=ABI)
        self.account = Account.from_key(settings.moderator_private_key)
        self._tx_lock = threading.Lock()

    # --- reads -------------------------------------------------------------
    def latest_block(self) -> int:
        return self.w3.eth.block_number

    def latest_timestamp(self) -> int:
        return int(self.w3.eth.get_block("latest")["timestamp"])

    def starting_price(self) -> int:
        return int(self.contract.functions.startingPrice().call())

    def on_chain_moderator(self) -> str:
        return self.contract.functions.moderator().call()

    def moderator_eth_balance(self) -> float:
        return float(self.w3.from_wei(self.w3.eth.get_balance(self.account.address), "ether"))

    def get_events(self, from_block: int, to_block: int) -> list[dict]:
        out = []
        for name in EVENT_NAMES:
            ev = getattr(self.contract.events, name)
            for log in ev.get_logs(from_block=from_block, to_block=to_block):
                out.append(
                    {
                        "event": name,
                        "args": dict(log["args"]),
                        "block": int(log["blockNumber"]),
                        "log_index": int(log["logIndex"]),
                        "tx_hash": Web3.to_hex(log["transactionHash"]),
                    }
                )
        out.sort(key=lambda e: (e["block"], e["log_index"]))
        return out

    # --- writes (moderator key) ---------------------------------------------
    def _send(self, fn) -> str:
        with self._tx_lock:
            tx = fn.build_transaction(
                {
                    "from": self.account.address,
                    "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
                    "chainId": settings.chain_id,
                }
            )  # gas estimation here also simulates the call, so a would-be revert raises before sending
            signed = self.account.sign_transaction(tx)
            raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
            return Web3.to_hex(self.w3.eth.send_raw_transaction(raw))

    def approve(self) -> str:
        return self._send(self.contract.functions.approve())

    def reject(self) -> str:
        return self._send(self.contract.functions.reject())

    def expire(self) -> str:
        return self._send(self.contract.functions.expire())
