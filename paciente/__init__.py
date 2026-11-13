from flask import Blueprint

bp = Blueprint("paciente", __name__, url_prefix="/paciente")

from paciente import routes  # noqa: E402,F401
