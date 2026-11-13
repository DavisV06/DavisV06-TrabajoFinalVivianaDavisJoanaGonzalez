from flask import Blueprint

bp = Blueprint("medico", __name__, url_prefix="/medico")

from medico import routes  # noqa: E402,F401
