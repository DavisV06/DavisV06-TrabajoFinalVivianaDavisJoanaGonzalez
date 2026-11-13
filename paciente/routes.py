import os
import hashlib
from datetime import datetime, timezone, date, timedelta

from flask import (
    render_template, redirect, url_for, flash, request, abort,
    send_file, current_app, jsonify,
)
from flask_login import login_required, current_user
from sqlalchemy import text
from io import BytesIO

from paciente import bp
from extensions import db
from models import (
    Consulta, Estudio, Imagen, ModeloIA, Medico, Usuario,
    Notificacion, Prediccion, PrediccionProb, Asignacion,
    ClaseDx, TipoNotif, EstadoConsulta,
)
from utils.auth_helpers import role_required, set_rls_context
from inference.predict import predict_image
from utils.pdf_gen import build_pdf_report


ALLOWED_EXT = {"png", "jpg", "jpeg", "bmp"}
HORARIO_INICIO = 8   # 08:00
HORARIO_FIN    = 17  # 17:00 (último slot a las 16:00)


def _allowed(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXT


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _imagen_repetida(sha, vistos):
    """True si la imagen ya está registrada en el sistema (de cualquier paciente)
    o si se envió dos veces en el mismo formulario. La tabla imagen no tiene RLS
    y sha256 es UNIQUE: sin esta revisión, la inserción falla en la base."""
    if sha in vistos:
        return True
    vistos.add(sha)
    return db.session.query(Imagen.id).filter_by(sha256=sha).first() is not None


MSG_YA_TIENE = ("Esta cita ya tiene retinografías analizadas y forman parte de tu expediente; "
                "no se pueden reemplazar. Si tu médico necesita imágenes nuevas, te las "
                "solicitará en una cita de seguimiento.")

MSG_REPETIDA = ("La imagen del {} ya está registrada en el sistema. "
                "Sube una retinografía nueva.")


def _validate_image(path):
    from PIL import Image as PILImage
    try:
        with PILImage.open(path) as im:
            w, h = im.size
            fmt = im.format
        return w, h, fmt
    except Exception:
        return None, None, None


# ── Dashboard ────────────────────────────────────────────────────────────────

@bp.route("/")
@bp.route("/dashboard")
@login_required
@role_required("paciente")
def dashboard():
    ahora = datetime.now(timezone.utc)
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    # Próxima cita (agendada futura más cercana)
    proxima_row = db.session.execute(text("""
        SELECT c.id, c.fecha, c.motivo, c.estado::text, c.consulta_padre_id,
               u.nombre AS medico_nombre, m.especialidad
        FROM oftalmologia.consulta c
        JOIN oftalmologia.medico m  ON m.usuario_id = c.medico_id
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        WHERE c.paciente_id = :pid
          AND c.estado = 'agendada'
          AND c.fecha > :ahora
        ORDER BY c.fecha ASC
        LIMIT 1
    """), {"pid": current_user.id, "ahora": ahora}).fetchone()

    # Último resultado con diagnóstico vigente
    ultima_id = db.session.execute(text("""
        SELECT c.id FROM oftalmologia.consulta c
        JOIN oftalmologia.estudio e  ON e.consulta_id = c.id
        JOIN oftalmologia.diagnostico d ON d.estudio_id = e.id AND d.vigente
        WHERE c.paciente_id = :pid AND c.estado = 'atendida'
        ORDER BY c.fecha DESC
        LIMIT 1
    """), {"pid": current_user.id}).scalar()

    ultimo_consulta = None
    if ultima_id:
        ultimo_consulta = db.session.get(Consulta, ultima_id)

    return render_template(
        "paciente/dashboard.html",
        proxima_cita=proxima_row,
        ultimo_consulta=ultimo_consulta,
        modelo_activo=modelo_activo,
    )


# ── Solicitar cita ───────────────────────────────────────────────────────────

@bp.route("/cita", methods=["GET", "POST"])
@login_required
@role_required("paciente")
def cita():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    # Todos los médicos activos con idoneidad vigente
    medicos = db.session.execute(text("""
        SELECT m.usuario_id, u.nombre, m.especialidad, m.vigente_hasta
        FROM oftalmologia.medico m
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        WHERE u.activo = true
          AND (m.vigente_hasta IS NULL OR m.vigente_hasta >= CURRENT_DATE)
        ORDER BY u.nombre
    """)).fetchall()

    if request.method == "POST":
        medico_id = request.form.get("medico_id", type=int)
        fecha_str = request.form.get("fecha", "").strip()
        hora_str  = request.form.get("hora", "").strip()
        motivo    = request.form.get("motivo", "").strip() or None

        errors = []
        if not medico_id:
            errors.append("Debes seleccionar un médico.")
        if not fecha_str:
            errors.append("Debes seleccionar una fecha.")
        if not hora_str:
            errors.append("Debes seleccionar una hora.")

        if not errors:
            try:
                fecha_hora = datetime.strptime(
                    f"{fecha_str} {hora_str}", "%Y-%m-%d %H:%M"
                ).replace(tzinfo=timezone.utc)
            except ValueError:
                errors.append("Formato de fecha u hora inválido.")

        if errors:
            for e in errors:
                flash(e, "error")
            return render_template("paciente/cita.html",
                                   medicos=medicos, modelo_activo=modelo_activo)

        # Verificar que el slot no esté ya ocupado
        ocupado = db.session.execute(text("""
            SELECT id FROM oftalmologia.consulta
            WHERE medico_id = :mid
              AND estado <> 'cancelada'
              AND fecha >= :inicio AND fecha < :fin
            LIMIT 1
        """), {
            "mid": medico_id,
            "inicio": fecha_hora,
            "fin": fecha_hora + timedelta(hours=1),
        }).fetchone()

        if ocupado:
            flash("Ese horario ya está ocupado. Elige otra hora.", "error")
            return render_template("paciente/cita.html",
                                   medicos=medicos, modelo_activo=modelo_activo)

        set_rls_context()
        consulta = Consulta(
            paciente_id=current_user.id,
            medico_id=medico_id,
            fecha=fecha_hora,
            motivo=motivo,
        )
        db.session.add(consulta)
        db.session.flush()

        # Auto-crear asignación tratante si no existe una vigente
        asig_existe = db.session.execute(text("""
            SELECT id FROM oftalmologia.asignacion
            WHERE medico_id = :mid AND paciente_id = :pid
              AND (hasta IS NULL OR hasta >= CURRENT_DATE)
            LIMIT 1
        """), {"mid": medico_id, "pid": current_user.id}).fetchone()

        if not asig_existe:
            db.session.execute(text("""
                INSERT INTO oftalmologia.asignacion
                    (medico_id, paciente_id, tipo, desde)
                VALUES (:mid, :pid, 'tratante', CURRENT_DATE)
                ON CONFLICT DO NOTHING
            """), {"mid": medico_id, "pid": current_user.id})

        # Notificar al médico
        medico_usuario_id = medico_id
        notif = Notificacion(
            usuario_id=medico_usuario_id,
            diagnostico_id=None,
            tipo=TipoNotif.asignacion_nueva,
            mensaje=(
                f"Nueva cita agendada con {current_user.nombre} "
                f"para el {fecha_hora.strftime('%d/%m/%Y a las %H:%M')}."
                + (f" Motivo: {motivo}" if motivo else "")
            ),
        )
        db.session.add(notif)
        db.session.commit()

        # ── Optional image upload at appointment creation ─────────────────
        file_od = request.files.get("imagen_od")
        file_oi = request.files.get("imagen_oi")
        any_file = (file_od and file_od.filename) or (file_oi and file_oi.filename)

        if any_file:
            has_od = bool(file_od and file_od.filename and _allowed(file_od.filename))
            has_oi = bool(file_oi and file_oi.filename and _allowed(file_oi.filename))
            if not has_od or not has_oi:
                flash("Para subir imágenes necesitas incluir ambos ojos. Puedes subirlas desde Citas pendientes.", "info")
            else:
                upload_dir = current_app.config["UPLOAD_FOLDER"]
                ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
                upload_ok = True
                vistos, guardados = set(), []
                for fobj, ojo_code in [(file_od, "R"), (file_oi, "L")]:
                    if not upload_ok:
                        break
                    ext   = fobj.filename.rsplit(".", 1)[1].lower()
                    fname = f"pac{current_user.id}_{ts}_{ojo_code}.{ext}"
                    fpath = os.path.join(upload_dir, fname)
                    fobj.save(fpath)
                    guardados.append(fpath)
                    w, h, fmt = _validate_image(fpath)
                    if w is None:
                        upload_ok = False
                        flash("Una imagen no es válida. Puedes subirlas después desde Citas pendientes.", "warning")
                        break
                    sha = _sha256(fpath)
                    if _imagen_repetida(sha, vistos):
                        upload_ok = False
                        flash(MSG_REPETIDA.format("Ojo Derecho" if ojo_code == "R" else "Ojo Izquierdo")
                              + " Puedes subirlas después desde Citas pendientes.", "warning")
                        break
                    set_rls_context()
                    img_row = Imagen(
                        ruta=f"uploads/{fname}", sha256=sha,
                        ancho=w, alto=h, formato=fmt,
                        bytes=os.path.getsize(fpath),
                    )
                    db.session.add(img_row)
                    db.session.flush()
                    est = Estudio(
                        consulta_id=consulta.id,
                        imagen_id=img_row.id,
                        ojo=ojo_code,
                        subido_por=current_user.id,
                    )
                    db.session.add(est)
                    db.session.flush()
                    result = predict_image(fpath)
                    if modelo_activo and result.get("clase"):
                        pred = Prediccion(
                            estudio_id=est.id,
                            modelo_id=modelo_activo.id,
                            clase=ClaseDx(result["clase"]),
                            confianza=result["confianza"],
                            ms_computo=result.get("ms_computo"),
                        )
                        db.session.add(pred)
                        db.session.flush()
                        for cls_key, prob_val in result["probabilidades"].items():
                            db.session.add(PrediccionProb(
                                prediccion_id=pred.id,
                                clase=ClaseDx(cls_key),
                                valor=prob_val,
                            ))
                if upload_ok:
                    db.session.add(Notificacion(
                        usuario_id=medico_usuario_id,
                        tipo=TipoNotif.estudio_cargado,
                        mensaje=(
                            f"{current_user.nombre} subió retinografías al agendar "
                            f"la cita del {fecha_hora.strftime('%d/%m/%Y')}."
                        ),
                    ))
                    db.session.commit()
                    flash("Imágenes analizadas con el modelo predictivo. El médico las revisará pronto.", "success")
                else:
                    db.session.rollback()
                    for fp in guardados:
                        if os.path.exists(fp):
                            os.remove(fp)

        flash("Cita agendada correctamente.", "success")
        return redirect(url_for("paciente.citas_pendientes"))

    return render_template("paciente/cita.html",
                           medicos=medicos,
                           modelo_activo=modelo_activo,
                           today=date.today().isoformat())


# ── Disponibilidad (AJAX) ────────────────────────────────────────────────────

@bp.route("/doctor/<int:mid>/disponibilidad")
@login_required
@role_required("paciente")
def disponibilidad(mid):
    """Devuelve las horas ocupadas para un médico en una fecha."""
    fecha_str = request.args.get("fecha", "")
    try:
        dia = datetime.strptime(fecha_str, "%Y-%m-%d").date()
    except ValueError:
        return jsonify({"horas_ocupadas": [], "error": "Fecha inválida"})

    # No permitir fechas pasadas
    if dia < date.today():
        return jsonify({"horas_ocupadas": list(range(HORARIO_INICIO, HORARIO_FIN))})

    rows = db.session.execute(text("""
        SELECT EXTRACT(HOUR FROM fecha AT TIME ZONE 'UTC')::int AS hora
        FROM oftalmologia.consulta
        WHERE medico_id = :mid
          AND estado <> 'cancelada'
          AND fecha::date = :dia
    """), {"mid": mid, "dia": dia}).fetchall()

    horas_ocupadas = [r[0] for r in rows]
    return jsonify({
        "horas_ocupadas": horas_ocupadas,
        "horario_inicio": HORARIO_INICIO,
        "horario_fin": HORARIO_FIN,
    })


# ── Citas pendientes ─────────────────────────────────────────────────────────

@bp.route("/citas-pendientes")
@login_required
@role_required("paciente")
def citas_pendientes():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    citas = (
        Consulta.query
        .filter_by(paciente_id=current_user.id)
        .filter(Consulta.estado == EstadoConsulta.agendada)
        .order_by(Consulta.fecha.asc())
        .all()
    )
    return render_template(
        "paciente/citas_pendientes.html",
        citas=citas,
        modelo_activo=modelo_activo,
        today=date.today(),
    )


@bp.route("/citas-pendientes/<int:consulta_id>/subir", methods=["POST"])
@login_required
@role_required("paciente")
def subir_desde_cita(consulta_id):
    consulta = Consulta.query.get_or_404(consulta_id)
    if consulta.paciente_id != current_user.id:
        abort(403)

    # Las retinografías ya analizadas no se reemplazan: son parte del expediente
    if consulta.estudios:
        flash(MSG_YA_TIENE, "warning")
        return redirect(url_for("paciente.citas_pendientes"))

    file_od = request.files.get("imagen_od")
    file_oi = request.files.get("imagen_oi")
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    if not file_od or not file_od.filename:
        flash("La imagen del Ojo Derecho es obligatoria.", "error")
        return redirect(url_for("paciente.citas_pendientes"))
    if not file_oi or not file_oi.filename:
        flash("La imagen del Ojo Izquierdo es obligatoria.", "error")
        return redirect(url_for("paciente.citas_pendientes"))
    if not _allowed(file_od.filename) or not _allowed(file_oi.filename):
        flash("Formato no permitido. Use PNG, JPG o BMP.", "error")
        return redirect(url_for("paciente.citas_pendientes"))

    upload_dir = current_app.config["UPLOAD_FOLDER"]
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    errors = []
    estudios_creados = []
    vistos, guardados = set(), []

    set_rls_context()

    for file_obj, ojo_code, label in [
        (file_od, "R", "OD"),
        (file_oi, "L", "OI"),
    ]:
        ext   = file_obj.filename.rsplit(".", 1)[1].lower()
        fname = f"pac{current_user.id}_{ts}_{ojo_code}.{ext}"
        fpath = os.path.join(upload_dir, fname)
        file_obj.save(fpath)
        guardados.append(fpath)

        w, h, fmt = _validate_image(fpath)
        if w is None:
            errors.append(f"Archivo {label} no es una imagen válida.")
            continue

        sha = _sha256(fpath)
        if _imagen_repetida(sha, vistos):
            errors.append(MSG_REPETIDA.format("Ojo Derecho" if ojo_code == "R" else "Ojo Izquierdo"))
            continue
        imagen = Imagen(
            ruta=f"uploads/{fname}", sha256=sha,
            ancho=w, alto=h, formato=fmt,
            bytes=os.path.getsize(fpath),
        )
        db.session.add(imagen)
        db.session.flush()

        estudio = Estudio(
            consulta_id=consulta_id,
            imagen_id=imagen.id,
            ojo=ojo_code,
            subido_por=current_user.id,
        )
        db.session.add(estudio)
        db.session.flush()

        result = predict_image(fpath)
        if modelo_activo and result.get("clase"):
            pred = Prediccion(
                estudio_id=estudio.id,
                modelo_id=modelo_activo.id,
                clase=ClaseDx(result["clase"]),
                confianza=result["confianza"],
                ms_computo=result["ms_computo"],
            )
            db.session.add(pred)
            db.session.flush()
            for cls_key, prob_val in result["probabilidades"].items():
                db.session.add(PrediccionProb(
                    prediccion_id=pred.id,
                    clase=ClaseDx(cls_key),
                    valor=prob_val,
                ))

        estudios_creados.append((estudio, result))

    if errors:
        db.session.rollback()
        for fp in guardados:
            if os.path.exists(fp):
                os.remove(fp)
        for e in errors:
            flash(e, "error")
    else:
        if estudios_creados:
            ojo_labels = " y ".join(
                "Ojo Derecho" if e.ojo == "R" else "Ojo Izquierdo"
                for e, _ in estudios_creados
            )
            db.session.add(Notificacion(
                usuario_id=consulta.medico_id,
                tipo=TipoNotif.estudio_cargado,
                mensaje=(
                    f"{current_user.nombre} subió retinografías ({ojo_labels}). "
                    f"Pendiente de revisión diagnóstica."
                ),
            ))
            db.session.add(Notificacion(
                usuario_id=current_user.id,
                tipo=TipoNotif.estudio_cargado,
                mensaje=(
                    f"Tus retinografías ({ojo_labels}) fueron analizadas por el modelo predictivo. "
                    f"El médico las revisará pronto."
                ),
            ))
        db.session.commit()
        flash("Imágenes cargadas y analizadas. El médico fue notificado.", "success")

    return redirect(url_for("paciente.citas_pendientes"))


@bp.route("/citas-pendientes/<int:consulta_id>/cancelar", methods=["POST"])
@login_required
@role_required("paciente")
def cancelar_cita_paciente(consulta_id):
    consulta = Consulta.query.get_or_404(consulta_id)
    if consulta.paciente_id != current_user.id:
        abort(403)
    if consulta.estado != EstadoConsulta.agendada:
        flash("Esta cita no puede cancelarse.", "error")
        return redirect(url_for("paciente.citas_pendientes"))

    set_rls_context()
    consulta.estado = EstadoConsulta.cancelada
    db.session.add(Notificacion(
        usuario_id=consulta.medico_id,
        tipo=TipoNotif.sistema,
        mensaje=(
            f"{current_user.nombre} canceló la cita del "
            f"{consulta.fecha.strftime('%d/%m/%Y a las %H:%M')}."
        ),
    ))
    db.session.commit()
    flash("Cita cancelada.", "success")
    return redirect(url_for("paciente.citas_pendientes"))


# ── Upload retinografías ─────────────────────────────────────────────────────

@bp.route("/upload", methods=["GET", "POST"])
@login_required
@role_required("paciente")
def upload():
    consultas_disponibles = _consultas_disponibles()
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    if request.method == "POST":
        consulta_id = request.form.get("consulta_id", type=int)
        file_od = request.files.get("imagen_od")
        file_oi = request.files.get("imagen_oi")

        if not file_od or not file_od.filename:
            flash("La imagen del Ojo Derecho es obligatoria.", "error")
            return render_template("paciente/upload.html",
                                   consultas=consultas_disponibles,
                                   modelo_activo=modelo_activo)
        if not file_oi or not file_oi.filename:
            flash("La imagen del Ojo Izquierdo es obligatoria.", "error")
            return render_template("paciente/upload.html",
                                   consultas=consultas_disponibles,
                                   modelo_activo=modelo_activo)
        if not _allowed(file_od.filename) or not _allowed(file_oi.filename):
            flash("Formato no permitido. Use PNG, JPG o BMP.", "error")
            return render_template("paciente/upload.html",
                                   consultas=consultas_disponibles,
                                   modelo_activo=modelo_activo)

        consulta = Consulta.query.get_or_404(consulta_id)
        if consulta.paciente_id != current_user.id:
            abort(403)
        if consulta.estudios:
            flash(MSG_YA_TIENE, "warning")
            return render_template("paciente/upload.html",
                                   consultas=consultas_disponibles,
                                   modelo_activo=modelo_activo)

        upload_dir = current_app.config["UPLOAD_FOLDER"]
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        errors = []
        estudios_creados = []
        vistos, guardados = set(), []

        for file_obj, ojo_code, label in [
            (file_od, "R", "OD"),
            (file_oi, "L", "OI"),
        ]:
            ext   = file_obj.filename.rsplit(".", 1)[1].lower()
            fname = f"pac{current_user.id}_{ts}_{ojo_code}.{ext}"
            fpath = os.path.join(upload_dir, fname)
            file_obj.save(fpath)
            guardados.append(fpath)

            w, h, fmt = _validate_image(fpath)
            if w is None:
                errors.append(f"Archivo {label} no es una imagen válida.")
                continue

            sha = _sha256(fpath)
            if _imagen_repetida(sha, vistos):
                errors.append(MSG_REPETIDA.format("Ojo Derecho" if ojo_code == "R" else "Ojo Izquierdo"))
                continue

            set_rls_context()
            imagen = Imagen(
                ruta=f"uploads/{fname}", sha256=sha,
                ancho=w, alto=h,
                formato=fmt,
                bytes=os.path.getsize(fpath),
            )
            db.session.add(imagen)
            db.session.flush()

            estudio = Estudio(
                consulta_id=consulta_id,
                imagen_id=imagen.id,
                ojo=ojo_code,
                subido_por=current_user.id,
            )
            db.session.add(estudio)
            db.session.flush()

            result = predict_image(fpath)
            if modelo_activo and result.get("clase"):
                pred = Prediccion(
                    estudio_id=estudio.id,
                    modelo_id=modelo_activo.id,
                    clase=ClaseDx(result["clase"]),
                    confianza=result["confianza"],
                    ms_computo=result["ms_computo"],
                )
                db.session.add(pred)
                db.session.flush()
                for cls_key, prob_val in result["probabilidades"].items():
                    db.session.add(PrediccionProb(
                        prediccion_id=pred.id,
                        clase=ClaseDx(cls_key),
                        valor=prob_val,
                    ))

            estudios_creados.append((estudio, result))

        if errors:
            db.session.rollback()
            for fp in guardados:
                if os.path.exists(fp):
                    os.remove(fp)
            for e in errors:
                flash(e, "error")
        else:
            # Notificar al médico que hay estudios listos para revisar
            if estudios_creados:
                ojo_labels = " y ".join(
                    "Ojo Derecho" if e.ojo == "R" else "Ojo Izquierdo"
                    for e, _ in estudios_creados
                )
                notif_medico = Notificacion(
                    usuario_id=consulta.medico_id,
                    diagnostico_id=None,
                    tipo=TipoNotif.estudio_cargado,
                    mensaje=(
                        f"{current_user.nombre} subió retinografías ({ojo_labels}). "
                        f"Pendiente de revisión diagnóstica."
                    ),
                )
                db.session.add(notif_medico)

                # Notificar al paciente también
                notif_pac = Notificacion(
                    usuario_id=current_user.id,
                    diagnostico_id=None,
                    tipo=TipoNotif.estudio_cargado,
                    mensaje=(
                        f"Tus retinografías ({ojo_labels}) fueron analizadas por el modelo predictivo. "
                        f"El médico las revisará pronto."
                    ),
                )
                db.session.add(notif_pac)

            db.session.commit()
            flash(
                "Imágenes cargadas y analizadas con el modelo predictivo. "
                "El médico fue notificado y revisará los resultados.",
                "success",
            )
            return redirect(url_for("paciente.estudios"))

    return render_template("paciente/upload.html",
                           consultas=consultas_disponibles,
                           modelo_activo=modelo_activo)


# ── Mis estudios ─────────────────────────────────────────────────────────────

@bp.route("/estudios")
@login_required
@role_required("paciente")
def estudios():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    all_c = (
        Consulta.query
        .filter_by(paciente_id=current_user.id)
        .order_by(Consulta.fecha.asc())
        .all()
    )
    # Group into threads: each thread is [root, followup1, followup2, ...]
    c_map = {c.id: c for c in all_c}
    children: dict = {}
    for c in all_c:
        if c.consulta_padre_id:
            children.setdefault(c.consulta_padre_id, []).append(c)

    def _chain(cid):
        chain = [c_map[cid]]
        for child in sorted(children.get(cid, []), key=lambda x: x.fecha):
            chain.extend(_chain(child.id))
        return chain

    # Within each thread: most recent node first. Threads list: most recent thread first.
    threads = [list(reversed(_chain(c.id))) for c in all_c if not c.consulta_padre_id]
    threads.reverse()
    return render_template("paciente/estudios.html",
                           threads=threads,
                           modelo_activo=modelo_activo)


# ── Notificación leída ───────────────────────────────────────────────────────

@bp.route("/notificacion/<int:nid>/leer", methods=["POST"])
@login_required
@role_required("paciente")
def leer_notificacion(nid):
    notif = Notificacion.query.get_or_404(nid)
    if notif.usuario_id != current_user.id:
        abort(403)
    notif.leida_en = datetime.now(timezone.utc)
    db.session.commit()
    return redirect(request.referrer or url_for("paciente.dashboard"))


@bp.route("/notificaciones/count")
@login_required
@role_required("paciente")
def notificaciones_count():
    count = db.session.execute(text("""
        SELECT COUNT(*) FROM oftalmologia.notificacion
        WHERE usuario_id = :uid AND leida_en IS NULL
    """), {"uid": current_user.id}).scalar() or 0
    return jsonify({"count": int(count)})


# ── PDF ──────────────────────────────────────────────────────────────────────

@bp.route("/pdf")
@login_required
@role_required("paciente")
def descargar_pdf():
    pac = current_user.paciente_data
    consultas = (
        Consulta.query
        .filter_by(paciente_id=current_user.id)
        .order_by(Consulta.fecha.desc())
        .all()
    )
    pdf_bytes = build_pdf_report(pac, consultas)
    return send_file(
        BytesIO(pdf_bytes),
        mimetype="application/pdf",
        as_attachment=True,
        download_name=f"expediente_{current_user.id}.pdf",
    )


# ── Helper ───────────────────────────────────────────────────────────────────

def _consultas_disponibles():
    """Consultas del paciente con retinografía solicitada y sin estudios subidos."""
    rows = db.session.execute(text("""
        SELECT c.id, c.fecha, c.motivo,
               u.nombre AS medico_nombre,
               COUNT(e.id) AS n_estudios
        FROM oftalmologia.consulta c
        JOIN oftalmologia.medico m  ON m.usuario_id = c.medico_id
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        LEFT JOIN oftalmologia.estudio e ON e.consulta_id = c.id
        WHERE c.paciente_id = :pid
          AND c.solicitar_retinografia = TRUE
        GROUP BY c.id, c.fecha, c.motivo, u.nombre
        HAVING COUNT(e.id) = 0
        ORDER BY c.fecha DESC
    """), {"pid": current_user.id}).fetchall()
    return rows
