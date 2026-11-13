from flask import Blueprint

bp = Blueprint("admin", __name__, url_prefix="/admin")

from admin import routes  # noqa: E402,F401
