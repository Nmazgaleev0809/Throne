import time
from sqlalchemy import BigInteger, Boolean, Integer, String, Text, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

from .config import settings

_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=_connect_args)
SessionLocal = sessionmaker(engine, expire_on_commit=False)


def now() -> int:
    return int(time.time())


class Base(DeclarativeBase):
    pass


class Upload(Base):
    """Content uploaded BEFORE the on-chain bid. Matched to a bid by content_hash."""

    __tablename__ = "uploads"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    content_hash: Mapped[str] = mapped_column(String(66), unique=True, index=True)
    message: Mapped[str] = mapped_column(Text, default="")
    has_image: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[int] = mapped_column(Integer, default=now)


class Bid(Base):
    """Mirror of on-chain bids. The chain is the source of truth; this is a cache."""

    __tablename__ = "bids"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    tx_hash: Mapped[str] = mapped_column(String(66), unique=True)
    block_number: Mapped[int] = mapped_column(Integer)
    bidder: Mapped[str] = mapped_column(String(42))
    amount: Mapped[int] = mapped_column(BigInteger)
    content_hash: Mapped[str] = mapped_column(String(66), index=True)
    deadline: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    seen_at: Mapped[int] = mapped_column(Integer, default=now)
    decided_at: Mapped[int | None] = mapped_column(Integer, nullable=True)
    previous_owner: Mapped[str | None] = mapped_column(String(42), nullable=True)
    refund_to_previous: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    # moderation bookkeeping
    notified: Mapped[bool] = mapped_column(Boolean, default=False)
    action_sent_at: Mapped[int | None] = mapped_column(Integer, nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)


class Meta(Base):
    __tablename__ = "meta"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(String(256))


def init_db() -> None:
    Base.metadata.create_all(engine)
