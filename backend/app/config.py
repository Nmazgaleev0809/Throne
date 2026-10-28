from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # chain
    rpc_url: str
    chain_id: int = 8453
    contract_address: str
    start_block: int  # required: deployment block of the contract
    confirmations: int = 2
    moderator_private_key: str

    # telegram
    telegram_bot_token: str = ""
    telegram_admin_chat_id: int = 0

    # rules
    text_auto_approve_delay: int = 120  # seconds a clean text bid waits (veto window)
    allow_links: bool = False
    max_message_chars: int = 256
    max_upload_bytes: int = 5 * 1024 * 1024
    max_image_w: int = 1920
    max_image_h: int = 1080
    uploads_per_hour: int = 20
    orphan_upload_ttl: int = 24 * 3600

    # misc
    database_url: str = "sqlite:///./throne.db"
    data_dir: str = "./data"
    cors_origins: str = "*"


settings = Settings()
