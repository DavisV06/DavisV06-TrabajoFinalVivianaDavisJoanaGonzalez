import os
from flask import Flask
from dotenv import load_dotenv

load_dotenv()


def create_app():
    app = Flask(__name__)

    # ── Config ────────────────────────────────────────────────────────────
    env = os.getenv("FLASK_ENV", "development")
    if env == "production":
        from config import ProductionConfig
        app.config.from_object(ProductionConfig)
    else:
        from config import DevelopmentConfig
        app.config.from_object(DevelopmentConfig)

    # ── Extensions ────────────────────────────────────────────────────────
    from extensions import db, login_manager, csrf, limiter
    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    limiter.init_app(app)

    from utils.auth_helpers import register_rls_hooks
    register_rls_hooks(app)

    # ── User loader ───────────────────────────────────────────────────────
    from models import Usuario

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(Usuario, int(user_id))

    # ── Upload folder ─────────────────────────────────────────────────────
    upload_dir = app.config.get("UPLOAD_FOLDER", "static/uploads")
    os.makedirs(upload_dir, exist_ok=True)

    # ── Blueprints ────────────────────────────────────────────────────────
    from auth import bp as auth_bp
    from paciente import bp as paciente_bp
    from medico import bp as medico_bp
    from admin import bp as admin_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(paciente_bp)
    app.register_blueprint(medico_bp)
    app.register_blueprint(admin_bp)

    # ── Notification endpoints (shared, all roles) ────────────────────────
    from flask import jsonify, abort as fl_abort, flash, redirect, url_for
    from flask_login import login_required as lr, current_user as cu
    from datetime import datetime, timezone
    from sqlalchemy import text as sqlt

    @app.route("/notif/lista")
    @lr
    def notif_lista():
        from models import Notificacion, TipoNotif, RolApp
        notifs = (
            Notificacion.query
            .filter_by(usuario_id=cu.id)
            .order_by(Notificacion.creada_en.desc())
            .limit(25)
            .all()
        )

        def _url(n):
            from flask import url_for as uf
            rol = cu.rol
            if rol == RolApp.medico:
                return uf("medico.agenda")
            if rol == RolApp.admin:
                return uf("admin.dashboard")
            # paciente
            if n.tipo in (TipoNotif.estudio_cargado, TipoNotif.diagnostico_listo):
                return uf("paciente.estudios")
            return uf("paciente.dashboard")

        return jsonify({"notificaciones": [{
            "id":        n.id,
            "mensaje":   n.mensaje,
            "tipo":      n.tipo.value,
            "leida":     n.leida_en is not None,
            "creada_en": n.creada_en.strftime("%d/%m/%Y %H:%M") if n.creada_en else "",
            "url":       _url(n),
        } for n in notifs]})

    @app.route("/notif/count")
    @lr
    def notif_count():
        from extensions import db
        count = db.session.execute(sqlt("""
            SELECT COUNT(*) FROM oftalmologia.notificacion
            WHERE usuario_id = :uid AND leida_en IS NULL
        """), {"uid": cu.id}).scalar() or 0
        return jsonify({"count": int(count)})

    @app.route("/notif/<int:nid>/leer", methods=["POST"])
    @lr
    def notif_leer(nid):
        from models import Notificacion
        from extensions import db
        n = db.session.get(Notificacion, nid)
        if not n or n.usuario_id != cu.id:
            fl_abort(403)
        if not n.leida_en:
            n.leida_en = datetime.now(timezone.utc)
            db.session.commit()
        return jsonify({"ok": True})

    @app.route("/notif/leer-todas", methods=["POST"])
    @lr
    def notif_leer_todas():
        from extensions import db
        db.session.execute(sqlt("""
            UPDATE oftalmologia.notificacion
            SET leida_en = NOW()
            WHERE usuario_id = :uid AND leida_en IS NULL
        """), {"uid": cu.id})
        db.session.commit()
        return jsonify({"ok": True})

    # ── Protección de datos personales (Ley 81 de 2019) ──────────────────
    from flask import request as _rq, abort as _abort, send_from_directory
    from flask_login import logout_user as _logout

    _SIN_CONSENTIMIENTO = {"auth.privacidad", "auth.aceptar_privacidad", "auth.logout", "static"}

    @app.before_request
    def _proteccion_datos():
        # Las retinografías no se sirven como archivos públicos: solo mediante /imagen/<id>.
        if _rq.path.startswith("/static/uploads/"):
            _abort(404)
        if not cu.is_authenticated:
            return None
        # Una cuenta desactivada o anonimizada pierde la sesión abierta.
        if not cu.is_active:
            _logout()
            flash("Tu cuenta no está activa.", "error")
            return redirect(url_for("auth.login"))
        # Consentimiento expreso antes de usar el sistema.
        if cu.consentimiento_en is None and _rq.endpoint not in _SIN_CONSENTIMIENTO:
            if _rq.path.startswith("/notif/"):
                return jsonify({"error": "consentimiento pendiente"}), 403
            return redirect(url_for("auth.privacidad"))
        return None

    @app.route("/imagen/<int:imagen_id>")
    @lr
    def ver_imagen(imagen_id):
        """Entrega una retinografía solo si el usuario puede ver el estudio al que pertenece.
        La seguridad a nivel de fila decide la visibilidad: el paciente ve las suyas, el médico
        las de sus pacientes asignados y el administrador todas."""
        from models import Estudio, Imagen
        est = Estudio.query.filter_by(imagen_id=imagen_id).first()
        img = db.session.get(Imagen, imagen_id) if est else None
        if not est or not img:
            _abort(404)
        directorio = app.config.get("UPLOAD_FOLDER")
        nombre = os.path.basename(img.ruta)
        if not os.path.isfile(os.path.join(directorio, nombre)):
            _abort(404)
        resp = send_from_directory(directorio, nombre, max_age=0)
        resp.headers["Cache-Control"] = "private, no-store"
        return resp

    # ── Context processor: sidebar counts ────────────────────────────────
    @app.context_processor
    def sidebar_counts():
        try:
            from flask_login import current_user as _cu
            if _cu.is_authenticated:
                from models import RolApp
                if _cu.rol == RolApp.paciente:
                    from sqlalchemy import text as _t
                    n = db.session.execute(_t("""
                        SELECT COUNT(*) FROM oftalmologia.consulta c
                        WHERE c.paciente_id = :pid
                          AND c.estado = 'agendada'
                          AND NOT EXISTS (
                              SELECT 1 FROM oftalmologia.estudio e
                              WHERE e.consulta_id = c.id
                          )
                    """), {"pid": _cu.id}).scalar() or 0
                    return {"n_citas_sin_imagenes": int(n)}
        except Exception:
            pass
        return {"n_citas_sin_imagenes": 0}

    # ── Root redirect ─────────────────────────────────────────────────────
    from flask import redirect, url_for
    from flask_login import current_user

    @app.route("/")
    def index():
        if current_user.is_authenticated:
            from models import RolApp
            dest = {
                RolApp.paciente: "paciente.dashboard",
                RolApp.medico:   "medico.dashboard",
                RolApp.admin:    "admin.dashboard",
            }
            return redirect(url_for(dest.get(current_user.rol, "auth.login")))
        return redirect(url_for("auth.login"))

    # ── Error handlers ────────────────────────────────────────────────────
    from flask import render_template as rt

    @app.errorhandler(403)
    def forbidden(e):
        return rt("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(e):
        return rt("errors/404.html"), 404

    @app.errorhandler(429)
    def too_many(e):
        return rt("errors/429.html"), 429

    @app.errorhandler(500)
    def server_error(e):
        return rt("errors/500.html"), 500

    # ── AI inference engine ───────────────────────────────────────────────
    from inference.predict import init_inference
    init_inference(app)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.getenv("PORT", 5000)),
        debug=app.config.get("DEBUG", False),
    )
