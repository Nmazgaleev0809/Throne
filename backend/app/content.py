"""Message normalization, blocklist, image processing and content hashing."""
import hashlib
import io
import re
import unicodedata
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

from .config import settings

Image.MAX_IMAGE_PIXELS = 40_000_000  # decompression-bomb guard


class ContentError(ValueError):
    """Raised for user-fixable content problems. The message is safe to show."""


# ----------------------------------------------------------------------------
# Text
# ----------------------------------------------------------------------------
# Control (Cc), format/zero-width/bidi (Cf), surrogate (Cs), private-use (Co), unassigned (Cn)
_STRIP_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Cn"}


def normalize_message(raw: str) -> str:
    text = unicodedata.normalize("NFC", raw or "")
    out = []
    for ch in text:
        if ch in "\n\r\t":
            out.append(" ")
        elif unicodedata.category(ch) in _STRIP_CATEGORIES:
            continue
        else:
            out.append(ch)
    text = re.sub(r"\s+", " ", "".join(out)).strip()
    if len(text) > settings.max_message_chars:
        raise ContentError(f"Message is too long (max {settings.max_message_chars} characters).")
    return text


_LEET = str.maketrans(
    {"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i", "|": "i", "€": "e"}
)


def _skeleton(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).casefold()
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.translate(_LEET)
    s = re.sub(r"[^a-z0-9\u0400-\u04ff]", "", s)  # keep Latin, digits, Cyrillic
    return re.sub(r"(.)\1+", r"\1", s)


@lru_cache(maxsize=1)
def _blocked_skeletons() -> tuple[str, ...]:
    path = Path(__file__).with_name("blocklist.txt")
    terms = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            sk = _skeleton(line)
            if sk:
                terms.append(sk)
    return tuple(terms)


_LINK_RE = re.compile(
    r"(https?://|www\.|t\.me/|\b[\w-]+\.(?:com|net|org|io|ru|xyz|app|dev|co|me|ly|gg|ai|info|biz|top|site|online|link)\b)",
    re.IGNORECASE,
)


def check_text(text: str) -> None:
    """Raise ContentError if the (already normalized) text is not allowed."""
    if not text:
        return
    if not settings.allow_links and _LINK_RE.search(text):
        raise ContentError("Links are not allowed in messages.")
    sk = _skeleton(text)
    for term in _blocked_skeletons():
        if term in sk:
            raise ContentError("This message contains content that isn't allowed.")


# ----------------------------------------------------------------------------
# Images
# ----------------------------------------------------------------------------
_ALLOWED_FORMATS = {"PNG", "JPEG", "WEBP"}


def process_image(data: bytes) -> bytes:
    """Validate, downscale to fit within the max size, strip metadata, return WebP bytes."""
    if len(data) > settings.max_upload_bytes:
        raise ContentError(f"Image is too large (max {settings.max_upload_bytes // (1024 * 1024)} MB).")
    try:
        Image.open(io.BytesIO(data)).verify()
        img = Image.open(io.BytesIO(data))  # verify() invalidates the object, so reopen
        fmt = img.format
        if fmt not in _ALLOWED_FORMATS:
            raise ContentError("Only PNG, JPG and WebP images are allowed.")
        if getattr(img, "n_frames", 1) > 1:
            raise ContentError("Animated images are not allowed.")
        if img.width * img.height > Image.MAX_IMAGE_PIXELS:
            raise ContentError("Image dimensions are too large.")
        img.load()
    except ContentError:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, Image.DecompressionBombError, ValueError):
        raise ContentError("That file isn't a valid image.")

    img = ImageOps.exif_transpose(img)
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.split()[3])
        img = flat
    else:
        img = img.convert("RGB")

    img.thumbnail((settings.max_image_w, settings.max_image_h), Image.LANCZOS)  # only ever shrinks
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=85, method=4)  # re-encoded: no EXIF/ICC/hidden data survives
    return buf.getvalue()


def jpeg_preview(webp_bytes: bytes) -> bytes:
    """Small JPEG for Telegram previews."""
    img = Image.open(io.BytesIO(webp_bytes)).convert("RGB")
    img.thumbnail((1280, 1280))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue()


# ----------------------------------------------------------------------------
# Hash
# ----------------------------------------------------------------------------
def compute_content_hash(message: str, image: bytes | None) -> str:
    """bytes32 (as 0x-hex) the bidder submits on-chain. Covers the exact message + processed image."""
    h = hashlib.sha256()
    h.update(b"throne-v1\x00")
    m = message.encode("utf-8")
    h.update(len(m).to_bytes(4, "big"))
    h.update(m)
    h.update(hashlib.sha256(image).digest() if image else b"\x00" * 32)
    return "0x" + h.hexdigest()


def image_path(content_hash: str) -> Path:
    return Path(settings.data_dir) / "images" / f"{content_hash[2:]}.webp"
