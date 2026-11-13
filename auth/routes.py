from flask import render_template, redirect, url_for, flash, request, current_app
from flask_login import login_user, logout_user, login_required, current_user
from sqlalchemy.exc import IntegrityError
from datetime import date, datetime, timezone

from auth import bp
from extensions import db, limiter
from models import Usuario, Paciente, Medico, RolApp, Notificacion, TipoNotif
from utils.auth_helpers import hash_password, check_password, set_rls_context


@bp.route("/login", methods=["GET", "POST"])
@limiter.limit("10 per minute")
def login():
    if current_user.is_authenticated:
        return _redirect_by_role(current_user.rol)

    if request.method == "POST":
        email    = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        remember = bool(request.form.get("remember"))

        user = Usuario.query.filter_by(email=email).first()

        if not user or not check_password(user.password_hash, password):
            flash("Correo o contraseña incorrectos.", "error")
            return render_template("auth/login.html")

        if not user.activo:
            flash("Tu cuenta está desactivada. Contacta al administrador.", "error")
            return render_template("auth/login.html")

        # Extra check for medico: idoneidad must be valid
        if user.rol == RolApp.medico and user.medico_data:
            if not user.medico_data.idoneidad_vigente:
                flash("Tu idoneidad profesional está vencida. Contacta al administrador.", "error")
                return render_template("auth/login.html")

        login_user(user, remember=remember)
        next_page = request.args.get("next")
        if next_page and next_page.startswith("/"):
            return redirect(next_page)
        return _redirect_by_role(user.rol)

    return render_template("auth/login.html")


@bp.route("/register", methods=["GET", "POST"])
@limiter.limit("5 per minute")
def register():
    if current_user.is_authenticated:
        return _redirect_by_role(current_user.rol)

    if request.method == "POST":
        nombre    = request.form.get("nombre", "").strip()
        email     = request.form.get("email", "").strip().lower()
        password  = request.form.get("password", "")
        confirm   = request.form.get("confirm", "")
        cedula    = request.form.get("cedula", "").strip() or None
        fecha_nac = request.form.get("fecha_nac") or None
        sexo      = request.form.get("sexo") or None
        acepta    = bool(request.form.get("acepto_privacidad"))

        if not acepta:
            flash("Debes leer y aceptar el aviso de privacidad para crear la cuenta.", "error")
            return render_template("auth/register.html")

        if not all([nombre, email, password]):
            flash("Nombre, correo y contraseña son obligatorios.", "error")
            return render_template("auth/register.html")

        if password != confirm:
            flash("Las contraseñas no coinciden.", "error")
            return render_template("auth/register.html")

        if len(password) < 8:
            flash("La contraseña debe tener al menos 8 caracteres.", "error")
            return render_template("auth/register.html")

        try:
            user = Usuario(
                email=email,
                password_hash=hash_password(password),
                rol=RolApp.paciente,
                nombre=nombre,
                consentimiento_en=datetime.now(timezone.utc),
                consentimiento_version=current_app.config["PRIVACIDAD_VERSION"],
            )
            db.session.add(user)
            db.session.flush()  # get user.id

            paciente = Paciente(
                usuario_id=user.id,
                cedula=cedula,
                fecha_nac=date.fromisoformat(fecha_nac) if fecha_nac else None,
                sexo=sexo,
            )
            db.session.add(paciente)
            db.session.commit()

            flash("Cuenta creada exitosamente. Inicia sesión.", "success")
            return redirect(url_for("auth.login"))

        except IntegrityError:
            db.session.rollback()
            flash("Ya existe una cuenta con ese correo o cédula.", "error")

    return render_template("auth/register.html")


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("Sesión cerrada correctamente.", "info")
    return redirect(url_for("auth.login"))


def _redirect_by_role(rol):
    dest = {
        RolApp.paciente: "paciente.dashboard",
        RolApp.medico:   "medico.dashboard",
        RolApp.admin:    "admin.dashboard",
    }
    return redirect(url_for(dest.get(rol, "auth.login")))


# ── Protección de datos personales (Ley 81 de 2019) ──────────────────────────

@bp.route("/privacidad")
def privacidad():
    """Aviso de privacidad. Público; si el usuario no ha dado su consentimiento, ofrece aceptarlo."""
    pendiente = current_user.is_authenticated and current_user.consentimiento_en is None
    return render_template("auth/privacidad.html", pendiente=pendiente,
                           version=current_app.config["PRIVACIDAD_VERSION"])


@bp.route("/privacidad/aceptar", methods=["POST"])
@login_required
def aceptar_privacidad():
    if not request.form.get("acepto_privacidad"):
        flash("Marca la casilla para confirmar que aceptas el aviso de privacidad.", "error")
        return redirect(url_for("auth.privacidad"))
    set_rls_context()
    current_user.consentimiento_en = datetime.now(timezone.utc)
    current_user.consentimiento_version = current_app.config["PRIVACIDAD_VERSION"]
    destino = url_for("index")
    flash("Gracias. Registramos tu consentimiento.", "success")
    db.session.commit()
    return redirect(destino)


@bp.route("/perfil", methods=["GET", "POST"])
@login_required
def perfil():
    """Derechos de acceso y rectificación: el usuario consulta y corrige sus datos personales."""
    pac = current_user.paciente_data
    if request.method == "POST":
        nombre   = request.form.get("nombre", "").strip()
        telefono = request.form.get("telefono", "").strip() or None
        if not nombre:
            flash("El nombre es obligatorio.", "error")
            return redirect(url_for("auth.perfil"))
        set_rls_context()
        current_user.nombre = nombre[:120]
        current_user.telefono = telefono[:30] if telefono else None
        if pac is not None:
            cedula = request.form.get("cedula", "").strip() or None
            fnac   = request.form.get("fecha_nac") or None
            sexo   = request.form.get("sexo") or None
            if sexo not in (None, "M", "F"):
                flash("Valor de sexo no válido.", "error")
                return redirect(url_for("auth.perfil"))
            try:
                fnac_d = date.fromisoformat(fnac) if fnac else None
            except ValueError:
                flash("Fecha de nacimiento no válida.", "error")
                return redirect(url_for("auth.perfil"))
            if fnac_d and fnac_d > date.today():
                flash("La fecha de nacimiento no puede ser futura.", "error")
                return redirect(url_for("auth.perfil"))
            if cedula and Paciente.query.filter(Paciente.cedula == cedula,
                                                Paciente.usuario_id != current_user.id).first():
                flash("Esa cédula ya está registrada en otra cuenta.", "error")
                return redirect(url_for("auth.perfil"))
            pac.cedula, pac.fecha_nac, pac.sexo = cedula, fnac_d, sexo
        destino = url_for("auth.perfil")
        flash("Tus datos fueron actualizados.", "success")
        db.session.commit()
        return redirect(destino)
    return render_template("auth/perfil.html", pac=pac)


@bp.route("/perfil/cancelacion", methods=["POST"])
@login_required
def solicitar_cancelacion():
    """Derechos de cancelación y oposición: el paciente pide que se anonimicen sus datos."""
    pac = current_user.paciente_data
    if pac is None:
        flash("Esta solicitud solo está disponible para pacientes.", "error")
        return redirect(url_for("auth.perfil"))
    if pac.cancelacion_solicitada_en:
        flash("Ya tienes una solicitud de cancelación en trámite.", "info")
        return redirect(url_for("auth.perfil"))
    set_rls_context()
    pac.cancelacion_solicitada_en = datetime.now(timezone.utc)
    for admin in Usuario.query.filter_by(rol=RolApp.admin, activo=True).all():
        db.session.add(Notificacion(
            usuario_id=admin.id, tipo=TipoNotif.sistema,
            mensaje=(f"Solicitud de cancelación de datos personales del paciente #{current_user.id}. "
                     "Revísala en Gestión de usuarios."),
        ))
    destino = url_for("auth.perfil")
    flash("Recibimos tu solicitud. Un administrador anonimizará tus datos personales; "
          "tu historial clínico se conservará sin datos que te identifiquen.", "success")
    db.session.commit()
    return redirect(destino)
