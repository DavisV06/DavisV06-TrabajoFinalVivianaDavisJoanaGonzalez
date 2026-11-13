import os
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = os.path.abspath(os.path.dirname(__file__))


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-in-production")
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL",
        "postgresql://api_backend:CAMBIAR_ESTA_CLAVE@localhost:5432/bd_oftalmologia",
    )
    SQLALCHEMY_ENGINE_OPTIONS = {
        "connect_args": {"options": "-csearch_path=oftalmologia,public"},
        "pool_pre_ping": True,
        "pool_recycle": 1800,
    }
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    UPLOAD_FOLDER = os.path.join(
        BASE_DIR, os.environ.get("UPLOAD_FOLDER", "static/uploads")
    )
    MAX_CONTENT_LENGTH = int(os.environ.get("MAX_CONTENT_MB", 10)) * 1024 * 1024

    MODEL_MV2_PATH = os.path.join(
        BASE_DIR, os.environ.get("MODEL_MV2_PATH", "modelos_tesis3/mejor_mv2.keras")
    )
    MODEL_RN50_PATH = os.path.join(
        BASE_DIR, os.environ.get("MODEL_RN50_PATH", "modelos_tesis3/mejor_rn50.keras")
    )

    ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "bmp"}

    # Versión del aviso de privacidad que el usuario acepta (Ley 81 de 2019)
    PRIVACIDAD_VERSION = "1.0 (noviembre de 2026)"
    WTF_CSRF_ENABLED = True

    # Limiter
    RATELIMIT_DEFAULT = "200 per day;50 per hour"
    RATELIMIT_STORAGE_URL = "memory://"


class DevelopmentConfig(Config):
    DEBUG = True
    WTF_CSRF_ENABLED = True


class ProductionConfig(Config):
    DEBUG = False
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"


config = {
    "development": DevelopmentConfig,
    "production": ProductionConfig,
    "default": DevelopmentConfig,
}
