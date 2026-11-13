"""Role-based access control decorators and RLS context helpers."""

from functools import wraps
from flask import abort, request
from flask_login import current_user
from sqlalchemy import text
from extensions import db


def role_required(*roles):
    """Decorator that restricts a route to users with specified roles."""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if not current_user.is_authenticated:
                abort(401)
            if current_user.rol.value not in roles:
                abort(403)
            return f(*args, **kwargs)
        return decorated
    return decorator


def set_rls_context():
    """Push current user context into PostgreSQL session for RLS and audit triggers.
    Must be called inside an active SQLAlchemy transaction.
    """
    if current_user.is_authenticated:
        try:
            db.session.execute(
                text("SET LOCAL app.usuario_id = :uid"),
                {"uid": str(current_user.id)},
            )
            db.session.execute(
                text("SET LOCAL app.rol = :rol"),
                {"rol": current_user.rol.value},
            )
            ip = request.remote_addr or ""
            db.session.execute(
                text("SET LOCAL app.ip = :ip"),
                {"ip": ip},
            )
        except Exception:
            pass


_SQL_CTX = text(
    "SELECT set_config('app.usuario_id', :uid, true),"
    "       set_config('app.rol', :rol, true),"
    "       set_config('app.ip', :ip, true)"
)


def register_rls_hooks(app):
    """Propagate the user context to every transaction, not only to the routes
    that call set_rls_context(). Required once the app connects with a
    non-superuser role, because RLS policies are no longer bypassed.
    """
    from flask import g, has_request_context
    from sqlalchemy import event, inspect
    from sqlalchemy.orm import Session

    def _identidad():
        """(uid, rol) of the logged-in user without triggering a database load.

        After a commit the user's attributes are expired; reading user.id here
        would start a refresh while the session is still opening the connection
        for another refresh, which SQLAlchemy rejects ("session is provisioning
        a new connection"). So the identity is cached in g the first time the
        attributes are available, and an expired user is never touched.
        """
        cache = g.get("_rls_identidad")
        if cache is not None:
            return cache
        # g._login_user is only set after Flask-Login finished loading the user;
        # reading current_user here would recurse into the user loader.
        user = g.get("_login_user")
        if user is None or not user.is_authenticated:
            return None
        estado = inspect(user)
        if estado.expired_attributes & {"id", "rol"}:
            return None
        g._rls_identidad = (str(user.id), user.rol.value)
        return g._rls_identidad

    @event.listens_for(Session, "after_begin")
    def _ctx_por_transaccion(session, transaction, connection):
        if not has_request_context():
            return
        ident = _identidad()
        if ident is None:
            return
        connection.execute(_SQL_CTX, {
            "uid": ident[0],
            "rol": ident[1],
            "ip": request.remote_addr or "",
        })

    @app.before_request
    def _ctx_primera_transaccion():
        # Loading current_user opens the first transaction before g._login_user
        # exists, so that transaction gets its context here.
        if current_user.is_authenticated:
            _identidad()
            set_rls_context()


def hash_password(password: str) -> str:
    from werkzeug.security import generate_password_hash
    return generate_password_hash(password, method="pbkdf2:sha256:600000")


def check_password(password_hash: str, password: str) -> bool:
    from werkzeug.security import check_password_hash
    return check_password_hash(password_hash, password)
