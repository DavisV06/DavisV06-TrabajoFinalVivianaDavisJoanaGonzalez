from collections import defaultdict
from datetime import datetime, timezone, timedelta, date
from flask import render_template, redirect, url_for, flash, request, abort, jsonify
from flask_login import login_required, current_user
from sqlalchemy import text

from medico import bp
from extensions import db
from models import (
    Consulta, Estudio, Diagnostico, ModeloIA, Medico, Usuario,
    Notificacion, ClaseDx, EstadoDx, EstadoConsulta, TipoNotif,
)
from utils.auth_helpers import role_required, set_rls_context

CLASE_LABELS = {c.value: c.label for c in ClaseDx}


# ── Dashboard (overview) ─────────────────────────────────────────────────────

@bp.route("/")
@bp.route("/dashboard")
@login_required
@role_required("medico")
def dashboard():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    mid = current_user.id

    kpis = db.session.execute(text("""
        SELECT
            COUNT(*) FILTER (WHERE c.fecha::date = CURRENT_DATE)     AS hoy,
            COUNT(*) FILTER (
                WHERE c.estado = 'agendada'
                  AND EXISTS (SELECT 1 FROM oftalmologia.estudio e WHERE e.consulta_id = c.id)
                  AND NOT EXISTS (
                      SELECT 1 FROM oftalmologia.estudio e2
                      JOIN oftalmologia.diagnostico dxx ON dxx.estudio_id = e2.id AND dxx.vigente
                      WHERE e2.consulta_id = c.id
                  )
            )                                                          AS por_revisar,
            COUNT(*) FILTER (
                WHERE c.consulta_padre_id IS NOT NULL
                  AND c.estado = 'agendada'
                  AND c.fecha > NOW()
            )                                                          AS seguimientos,
            COUNT(DISTINCT c.paciente_id) FILTER (
                WHERE c.fecha >= date_trunc('month', NOW())
            )                                                          AS pacientes_mes
        FROM oftalmologia.consulta c
        WHERE c.medico_id = :mid
    """), {"mid": mid}).fetchone()

    citas_hoy = db.session.execute(text("""
        SELECT c.id, c.fecha, c.motivo, c.estado::text,
               u.nombre AS paciente_nombre, COUNT(e.id) AS n_estudios
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p  ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u   ON u.id = p.usuario_id
        LEFT JOIN oftalmologia.estudio e ON e.consulta_id = c.id
        WHERE c.medico_id = :mid AND c.fecha::date = CURRENT_DATE
        GROUP BY c.id, c.fecha, c.motivo, c.estado, u.nombre
        ORDER BY c.fecha
    """), {"mid": mid}).fetchall()

    revisiones = db.session.execute(text("""
        SELECT c.id, c.fecha, c.motivo, u.nombre AS paciente_nombre,
               COUNT(e.id) AS n_estudios
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p  ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u   ON u.id = p.usuario_id
        JOIN oftalmologia.estudio e   ON e.consulta_id = c.id
        WHERE c.medico_id = :mid AND c.estado = 'agendada'
          AND NOT EXISTS (
              SELECT 1 FROM oftalmologia.estudio e2
              JOIN oftalmologia.diagnostico dxx ON dxx.estudio_id = e2.id AND dxx.vigente
              WHERE e2.consulta_id = c.id
          )
        GROUP BY c.id, c.fecha, c.motivo, u.nombre
        ORDER BY c.fecha LIMIT 8
    """), {"mid": mid}).fetchall()

    edad_rows = db.session.execute(text("""
        SELECT
            CASE
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 18  THEN '<18'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 31  THEN '18-30'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 46  THEN '31-45'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 61  THEN '46-60'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 76  THEN '61-75'
                ELSE '75+'
            END AS grupo,
            COUNT(DISTINCT p.usuario_id) AS total
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u  ON u.id = p.usuario_id
        WHERE c.medico_id = :mid AND p.fecha_nac IS NOT NULL
        GROUP BY grupo
    """), {"mid": mid}).fetchall()
    edad_labels = ['<18', '18-30', '31-45', '46-60', '61-75', '75+']
    edad_map    = {r.grupo: int(r.total) for r in edad_rows}
    edad_data   = [edad_map.get(g, 0) for g in edad_labels]

    sexo_rows = db.session.execute(text("""
        SELECT p.sexo, COUNT(DISTINCT p.usuario_id) AS total
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u  ON u.id = p.usuario_id
        WHERE c.medico_id = :mid AND p.sexo IS NOT NULL
        GROUP BY p.sexo
    """), {"mid": mid}).fetchall()
    sexo_data = {r.sexo: int(r.total) for r in sexo_rows}

    dx_edad_rows = db.session.execute(text("""
        SELECT
            CASE
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 31  THEN '≤30'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 46  THEN '31-45'
                WHEN EXTRACT(YEAR FROM AGE(p.fecha_nac)) < 61  THEN '46-60'
                ELSE '60+'
            END AS grupo,
            d.clase::text AS clase, COUNT(*) AS total
        FROM oftalmologia.diagnostico d
        JOIN oftalmologia.estudio e   ON e.id = d.estudio_id
        JOIN oftalmologia.consulta c  ON c.id = e.consulta_id
        JOIN oftalmologia.paciente p  ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u   ON u.id = p.usuario_id
        WHERE c.medico_id = :mid AND d.vigente AND p.fecha_nac IS NOT NULL
        GROUP BY grupo, d.clase
    """), {"mid": mid}).fetchall()
    dx_edad_groups = ['≤30', '31-45', '46-60', '60+']
    dx_clases_list = ['normal', 'rd', 'glaucoma', 'catarata']
    dx_edad_data   = {g: {c: 0 for c in dx_clases_list} for g in dx_edad_groups}
    for r in dx_edad_rows:
        if r.grupo in dx_edad_data and r.clase in dx_clases_list:
            dx_edad_data[r.grupo][r.clase] = int(r.total)

    return render_template(
        "medico/dashboard.html",
        modelo_activo=modelo_activo,
        kpis=kpis,
        citas_hoy=citas_hoy,
        revisiones=revisiones,
        edad_labels=edad_labels,
        edad_data=edad_data,
        sexo_data=sexo_data,
        dx_edad_groups=dx_edad_groups,
        dx_clases_list=dx_clases_list,
        dx_edad_data=dx_edad_data,
        hoy=datetime.now(timezone.utc).date().isoformat(),
    )


# ── Agenda (appointment list) ────────────────────────────────────────────────

@bp.route("/agenda")
@login_required
@role_required("medico")
def agenda():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    mid = current_user.id

    stats = db.session.execute(text("""
        SELECT
            COUNT(*)                                                   AS total,
            COUNT(*) FILTER (WHERE fecha >= date_trunc('month', NOW())
                               AND fecha <  date_trunc('month', NOW()) + INTERVAL '1 month')
                                                                       AS mes_total,
            COUNT(*) FILTER (WHERE estado = 'agendada')                AS agendadas,
            COUNT(*) FILTER (WHERE estado = 'atendida')                AS atendidas,
            COUNT(*) FILTER (WHERE estado = 'cancelada')               AS canceladas,
            COUNT(*) FILTER (WHERE estado = 'referida')                AS referidas
        FROM oftalmologia.consulta
        WHERE medico_id = :mid
    """), {"mid": mid}).fetchone()

    rows = db.session.execute(text("""
        SELECT c.id, c.fecha, c.motivo, c.estado::text, c.referida_a,
               u_pac.nombre  AS paciente_nombre,
               u_ref.nombre  AS referida_a_nombre,
               COUNT(e.id)   AS n_estudios,
               SUM(CASE WHEN e.id IS NOT NULL AND NOT EXISTS (
                   SELECT 1 FROM oftalmologia.diagnostico d
                   WHERE d.estudio_id = e.id AND d.vigente
               ) THEN 1 ELSE 0 END) AS n_pendientes
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p    ON p.usuario_id  = c.paciente_id
        JOIN oftalmologia.usuario u_pac ON u_pac.id      = p.usuario_id
        LEFT JOIN oftalmologia.medico   m_ref ON m_ref.usuario_id = c.referida_a
        LEFT JOIN oftalmologia.usuario  u_ref ON u_ref.id         = m_ref.usuario_id
        LEFT JOIN oftalmologia.estudio  e     ON e.consulta_id    = c.id
        WHERE c.medico_id = :mid
        GROUP BY c.id, c.fecha, c.motivo, c.estado, c.referida_a,
                 u_pac.nombre, u_ref.nombre
        ORDER BY
            (c.estado = 'agendada') DESC,
            c.fecha DESC
    """), {"mid": mid}).fetchall()

    colegas = db.session.execute(text("""
        SELECT m.usuario_id, u.nombre, m.especialidad
        FROM oftalmologia.medico m
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        WHERE u.activo = true
          AND m.usuario_id != :mid
          AND (m.vigente_hasta IS NULL OR m.vigente_hasta >= CURRENT_DATE)
        ORDER BY u.nombre
    """), {"mid": mid}).fetchall()

    por_revisar = sum(
        1 for r in rows
        if r.estado == 'agendada' and (r.n_pendientes or 0) > 0
    )

    return render_template(
        "medico/agenda.html",
        consultas=rows,
        stats=stats,
        por_revisar=por_revisar,
        colegas=colegas,
        modelo_activo=modelo_activo,
        hoy=datetime.now(timezone.utc).date().isoformat(),
        EstadoConsulta=EstadoConsulta,
    )


# ── Consultas por paciente ────────────────────────────────────────────────────

@bp.route("/consultas")
@login_required
@role_required("medico")
def consultas():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    mid = current_user.id

    pac_rows = db.session.execute(text("""
        SELECT p.usuario_id, u.nombre,
               COUNT(c.id)                                              AS n_consultas,
               MAX(c.fecha)                                             AS ultima_cita,
               COUNT(c.id) FILTER (WHERE c.estado = 'agendada')         AS agendadas,
               COUNT(c.id) FILTER (WHERE c.estado = 'atendida')         AS atendidas
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p ON p.usuario_id = c.paciente_id
        JOIN oftalmologia.usuario u  ON u.id = p.usuario_id
        WHERE c.medico_id = :mid
        GROUP BY p.usuario_id, u.nombre
        ORDER BY ultima_cita DESC
    """), {"mid": mid}).fetchall()

    pids = [r.usuario_id for r in pac_rows]
    citas_map = defaultdict(list)
    if pids:
        c_rows = db.session.execute(text("""
            SELECT c.id, c.paciente_id, c.fecha, c.motivo,
                   c.estado::text AS estado, c.consulta_padre_id,
                   COUNT(e.id) AS n_estudios,
                   COALESCE(SUM(CASE WHEN dxx.vigente THEN 1 ELSE 0 END), 0) AS n_dx
            FROM oftalmologia.consulta c
            LEFT JOIN oftalmologia.estudio e ON e.consulta_id = c.id
            LEFT JOIN oftalmologia.diagnostico dxx ON dxx.estudio_id = e.id
            WHERE c.medico_id = :mid AND c.paciente_id = ANY(:pids)
            GROUP BY c.id, c.paciente_id, c.fecha, c.motivo, c.estado, c.consulta_padre_id
            ORDER BY c.fecha DESC
        """), {"mid": mid, "pids": pids}).fetchall()
        for r in c_rows:
            citas_map[r.paciente_id].append(r)

    return render_template(
        "medico/consultas.html",
        modelo_activo=modelo_activo,
        pacientes=pac_rows,
        citas_map=citas_map,
        hoy=datetime.now(timezone.utc).date().isoformat(),
        EstadoConsulta=EstadoConsulta,
    )


# ── Ver estudios de una consulta ─────────────────────────────────────────────

@bp.route("/consulta/<int:consulta_id>")
@login_required
@role_required("medico")
def consulta(consulta_id):
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    c = Consulta.query.get_or_404(consulta_id)
    if c.medico_id != current_user.id:
        abort(403)
    # Full ancestor chain: [immediate_parent, grandparent, ...] (most recent first)
    historial = []
    node = c.padre
    while node is not None:
        historial.append(node)
        node = node.padre
    # Side-by-side comparison uses immediate parent's studies
    prev_map = {e.ojo: e for e in historial[0].estudios} if historial else {}
    # Resto del historial del paciente (otros médicos, otras líneas de seguimiento).
    # RLS limita el resultado a lo que este médico puede ver por su asignación.
    en_hilo = {c.id} | {h.id for h in historial}
    otras_consultas = [
        o for o in Consulta.query
            .filter(Consulta.paciente_id == c.paciente_id,
                    Consulta.estado != EstadoConsulta.cancelada)
            .order_by(Consulta.fecha.desc())
        if o.id not in en_hilo
    ]
    # Si esta cita llegó por referencia, la consulta original de la que proviene
    origen_ref = (Consulta.query
                  .filter(Consulta.paciente_id == c.paciente_id,
                          Consulta.referida_a == current_user.id,
                          Consulta.estado == EstadoConsulta.referida,
                          Consulta.fecha == c.fecha)
                  .first())
    return render_template(
        "medico/consulta.html",
        consulta=c,
        historial=historial,
        otras_consultas=otras_consultas,
        origen_ref=origen_ref,
        consulta_padre=historial[0] if historial else None,
        prev_estudios_map=prev_map,
        modelo_activo=modelo_activo,
        ClaseDx=ClaseDx,
        hoy=datetime.now(timezone.utc).date().isoformat(),
    )


# ── Modificar cita ───────────────────────────────────────────────────────────

@bp.route("/consulta/<int:cid>/modificar", methods=["POST"])
@login_required
@role_required("medico")
def modificar_consulta(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    if c.estado != EstadoConsulta.agendada:
        flash("Solo se pueden modificar citas agendadas.", "error")
        return redirect(url_for("medico.agenda"))

    fecha_str = request.form.get("fecha", "").strip()
    hora_str  = request.form.get("hora", "").strip()
    motivo    = request.form.get("motivo", "").strip() or None

    if not fecha_str or not hora_str:
        flash("Fecha y hora son obligatorias.", "error")
        return redirect(url_for("medico.agenda"))

    try:
        nueva_fecha = datetime.strptime(
            f"{fecha_str} {hora_str}", "%Y-%m-%d %H:%M"
        ).replace(tzinfo=timezone.utc)
    except ValueError:
        flash("Formato de fecha u hora inválido.", "error")
        return redirect(url_for("medico.agenda"))

    # Verificar que el slot no esté tomado por otra consulta
    ocupado = db.session.execute(text("""
        SELECT id FROM oftalmologia.consulta
        WHERE medico_id = :mid
          AND id != :cid
          AND estado = 'agendada'
          AND fecha >= :inicio AND fecha < :fin
        LIMIT 1
    """), {
        "mid": current_user.id, "cid": cid,
        "inicio": nueva_fecha,
        "fin": nueva_fecha + timedelta(hours=1),
    }).fetchone()

    if ocupado:
        flash("Ese horario ya está ocupado. Elige otra hora.", "error")
        return redirect(url_for("medico.agenda"))

    c.fecha         = nueva_fecha
    c.motivo        = motivo
    c.modificada_en = datetime.now(timezone.utc)
    db.session.commit()

    # Notificar al paciente
    db.session.add(Notificacion(
        usuario_id=c.paciente_id,
        tipo=TipoNotif.sistema,
        mensaje=(
            f"Tu cita fue reprogramada al "
            f"{nueva_fecha.strftime('%d/%m/%Y a las %H:%M')}."
            + (f" Motivo: {motivo}" if motivo else "")
        ),
    ))
    db.session.commit()
    flash("Cita modificada y paciente notificado.", "success")
    return redirect(url_for("medico.agenda"))


# ── Cancelar cita ────────────────────────────────────────────────────────────

@bp.route("/consulta/<int:cid>/cancelar", methods=["POST"])
@login_required
@role_required("medico")
def cancelar_consulta(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    if c.estado not in (EstadoConsulta.agendada,):
        flash("Solo se pueden cancelar citas agendadas.", "error")
        return redirect(url_for("medico.agenda"))

    notas = request.form.get("notas_cancel", "").strip() or None
    c.estado       = EstadoConsulta.cancelada
    c.notas_cancel = notas
    c.modificada_en = datetime.now(timezone.utc)

    db.session.add(Notificacion(
        usuario_id=c.paciente_id,
        tipo=TipoNotif.sistema,
        mensaje=(
            f"Tu cita del {c.fecha.strftime('%d/%m/%Y a las %H:%M')} fue cancelada."
            + (f" Motivo: {notas}" if notas else "")
        ),
    ))
    db.session.commit()
    flash("Cita cancelada y paciente notificado.", "success")
    return redirect(url_for("medico.agenda"))


# ── Referir a colega ─────────────────────────────────────────────────────────

@bp.route("/consulta/<int:cid>/referir", methods=["POST"])
@login_required
@role_required("medico")
def referir_consulta(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    if c.estado != EstadoConsulta.agendada:
        flash("Solo se pueden referir citas agendadas.", "error")
        return redirect(url_for("medico.agenda"))

    colega_id = request.form.get("colega_id", type=int)
    notas     = request.form.get("notas_referido", "").strip() or None

    if not colega_id or colega_id == current_user.id:
        flash("Selecciona un colega válido.", "error")
        return redirect(url_for("medico.agenda"))

    colega = db.session.get(Medico, colega_id)
    if not colega:
        abort(404)

    # Marcar como referida en la consulta original
    c.estado      = EstadoConsulta.referida
    c.referida_a  = colega_id
    c.modificada_en = datetime.now(timezone.utc)

    # Crear nueva consulta para el colega con los mismos datos
    nueva = Consulta(
        paciente_id=c.paciente_id,
        medico_id=colega_id,
        fecha=c.fecha,
        motivo=c.motivo,
        notas=notas,
        estado=EstadoConsulta.agendada,
    )
    db.session.add(nueva)
    db.session.flush()

    # Asignación de interconsulta: sin ella, RLS le oculta al colega la consulta
    # nueva y el historial del paciente.
    asig_existe = db.session.execute(text("""
        SELECT 1 FROM oftalmologia.asignacion
        WHERE medico_id = :mid AND paciente_id = :pid
          AND (hasta IS NULL OR hasta >= CURRENT_DATE)
        LIMIT 1
    """), {"mid": colega_id, "pid": c.paciente_id}).fetchone()
    if not asig_existe:
        db.session.execute(text("""
            INSERT INTO oftalmologia.asignacion (medico_id, paciente_id, tipo, desde)
            VALUES (:mid, :pid, 'interconsulta', CURRENT_DATE)
            ON CONFLICT DO NOTHING
        """), {"mid": colega_id, "pid": c.paciente_id})

    # Notificar al colega
    db.session.add(Notificacion(
        usuario_id=colega_id,
        tipo=TipoNotif.asignacion_nueva,
        mensaje=(
            f"El Dr./Dra. {current_user.nombre} te refirió una cita de "
            f"{c.paciente.usuario.nombre} para el "
            f"{c.fecha.strftime('%d/%m/%Y a las %H:%M')}."
            + (f" Notas: {notas}" if notas else "")
        ),
    ))

    # Notificar al paciente
    db.session.add(Notificacion(
        usuario_id=c.paciente_id,
        tipo=TipoNotif.sistema,
        mensaje=(
            f"Tu cita fue referida al Dr./Dra. {colega.usuario.nombre} "
            f"({colega.especialidad or 'oftalmólogo'})."
            + (f" Notas: {notas}" if notas else "")
        ),
    ))
    db.session.commit()
    flash(f"Cita referida a {colega.usuario.nombre} correctamente.", "success")
    return redirect(url_for("medico.agenda"))


# ── Ver diagnóstico de un estudio ────────────────────────────────────────────

def _es_referido(consulta):
    """El médico actual recibió esta consulta por referencia."""
    return (consulta.estado == EstadoConsulta.referida
            and consulta.referida_a == current_user.id)


def _puede_diagnosticar(consulta):
    """Médico de la consulta o médico al que se refirió. Los estudios se quedan
    en la consulta original; el referido puede revisar y rectificar su diagnóstico."""
    return consulta.medico_id == current_user.id or _es_referido(consulta)


@bp.route("/diagnostico/<int:estudio_id>")
@login_required
@role_required("medico")
def diagnostico(estudio_id):
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    estudio  = Estudio.query.get_or_404(estudio_id)
    consulta = estudio.consulta
    if not _puede_diagnosticar(consulta):
        abort(403)

    # Para el médico referido: su propia consulta (la creada al referir)
    consulta_propia = None
    if _es_referido(consulta):
        consulta_propia = (Consulta.query
                           .filter(Consulta.paciente_id == consulta.paciente_id,
                                   Consulta.medico_id == current_user.id,
                                   Consulta.fecha == consulta.fecha)
                           .first())

    return render_template(
        "medico/diagnostico.html",
        estudio=estudio,
        consulta=consulta,
        es_referido=_es_referido(consulta),
        consulta_propia=consulta_propia,
        pred=estudio.prediccion_principal,
        dx_vigente=estudio.diagnostico_vigente,
        historial=estudio.diagnosticos,
        modelo_activo=modelo_activo,
        CLASE_LABELS=CLASE_LABELS,
        ClaseDx=ClaseDx,
    )


# ── Confirmar diagnóstico IA ─────────────────────────────────────────────────

@bp.route("/diagnostico/<int:estudio_id>/confirmar", methods=["POST"])
@login_required
@role_required("medico")
def confirmar(estudio_id):
    estudio = Estudio.query.get_or_404(estudio_id)
    if not _puede_diagnosticar(estudio.consulta):
        abort(403)

    pred = estudio.prediccion_principal
    if not pred:
        flash("No hay resultado del modelo predictivo para confirmar.", "error")
        return redirect(url_for("medico.diagnostico", estudio_id=estudio_id))

    set_rls_context()
    dx = Diagnostico(
        estudio_id=estudio_id,
        version=0,
        clase=pred.clase,
        estado=EstadoDx.confirmado,
        medico_id=current_user.id,
        observaciones=request.form.get("observaciones", "").strip() or None,
        motivo_cambio=None,
    )
    db.session.add(dx)
    db.session.flush()

    _notificar_paciente(
        estudio.consulta.paciente_id, dx.id,
        f"Tu diagnóstico para {estudio.ojo_label} está listo: {pred.clase.label}.",
    )
    _auto_marcar_atendida(estudio.consulta)
    db.session.commit()
    flash("Diagnóstico confirmado correctamente.", "success")
    return redirect(url_for("medico.agenda"))


# ── Rectificar diagnóstico ───────────────────────────────────────────────────

@bp.route("/diagnostico/<int:estudio_id>/rectificar", methods=["POST"])
@login_required
@role_required("medico")
def rectificar(estudio_id):
    estudio = Estudio.query.get_or_404(estudio_id)
    if not _puede_diagnosticar(estudio.consulta):
        abort(403)

    clase_str     = request.form.get("clase", "")
    observaciones = request.form.get("observaciones", "").strip() or None
    motivo        = request.form.get("motivo_cambio", "").strip()

    if not clase_str or clase_str not in [c.value for c in ClaseDx]:
        flash("Selecciona una clase de diagnóstico válida.", "error")
        return redirect(url_for("medico.diagnostico", estudio_id=estudio_id))
    if not motivo:
        flash("El motivo de rectificación es obligatorio.", "error")
        return redirect(url_for("medico.diagnostico", estudio_id=estudio_id))

    set_rls_context()
    dx = Diagnostico(
        estudio_id=estudio_id,
        version=0,
        clase=ClaseDx(clase_str),
        estado=EstadoDx.rectificado,
        medico_id=current_user.id,
        observaciones=observaciones,
        motivo_cambio=motivo,
    )
    db.session.add(dx)
    db.session.flush()

    _notificar_paciente(
        estudio.consulta.paciente_id, dx.id,
        f"Tu diagnóstico para {estudio.ojo_label} fue actualizado: {ClaseDx(clase_str).label}.",
    )
    _auto_marcar_atendida(estudio.consulta)
    db.session.commit()
    flash("Diagnóstico rectificado y registrado.", "success")
    return redirect(url_for("medico.agenda"))


# ── Guardar notas clínicas y plan de tratamiento ─────────────────────────────

@bp.route("/consulta/<int:cid>/notas", methods=["POST"])
@login_required
@role_required("medico")
def guardar_notas(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    c.notas_medico     = request.form.get("notas_medico", "").strip() or None
    c.plan_tratamiento = request.form.get("plan_tratamiento", "").strip() or None
    c.modificada_en    = datetime.now(timezone.utc)
    db.session.commit()
    flash("Notas y plan de tratamiento guardados.", "success")
    return redirect(url_for("medico.consulta", consulta_id=cid))


# ── Solicitar / cancelar retinografía ────────────────────────────────────────

@bp.route("\consulta\<int:cid>/retinografia", methods=["POST"])
@login_required
@role_required("medico")
def toggle_retinografia(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    c.solicitar_retinografia = not c.solicitar_retinografia
    c.modificada_en = datetime.now(timezone.utc)
    db.session.commit()
    if c.solicitar_retinografia:
        flash("Retinografía solicitada al paciente.", "success")
    else:
        flash("Solicitud de retinografía cancelada.", "info")
    return redirect(url_for("medico.consulta", consulta_id=cid))


# ── Marcar consulta como atendida ────────────────────────────────────────────

@bp.route("\consulta\<int:cid>/marcar-atendida", methods=["POST"])
@login_required
@role_required("medico")
def marcar_atendida(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)
    if c.estado != EstadoConsulta.atendida:
        c.estado        = EstadoConsulta.atendida
        c.modificada_en = datetime.now(timezone.utc)
        db.session.commit()
        flash("Consulta marcada como atendida.", "success")
    return redirect(url_for("medico.consulta", consulta_id=cid))


# ── Helpers ──────────────────────────────────────────────────────────────────

def _notificar_paciente(paciente_id, diagnostico_id, mensaje):
    db.session.add(Notificacion(
        usuario_id=paciente_id,
        diagnostico_id=diagnostico_id,
        tipo=TipoNotif.diagnostico_listo,
        mensaje=mensaje,
    ))


def _auto_marcar_atendida(consulta):
    """Marca la consulta como atendida si todos sus estudios tienen diagnóstico vigente.
    Usa SQL directo para leer estado post-flush y evitar el cache ORM."""
    if consulta.estado != EstadoConsulta.agendada:
        return
    row = db.session.execute(text("""
        SELECT
            COUNT(e.id) AS total,
            COUNT(*) FILTER (WHERE EXISTS (
                SELECT 1 FROM oftalmologia.diagnostico d
                WHERE d.estudio_id = e.id AND d.vigente = true
            )) AS con_dx
        FROM oftalmologia.estudio e
        WHERE e.consulta_id = :cid
    """), {"cid": consulta.id}).fetchone()
    if row and row.total > 0 and row.total == row.con_dx:
        consulta.estado = EstadoConsulta.atendida


# ── Agendar cita de seguimiento ─────────────────────────────────────────────

@bp.route("/consulta/<int:cid>/seguimiento", methods=["POST"])
@login_required
@role_required("medico")
def agendar_seguimiento(cid):
    c = Consulta.query.get_or_404(cid)
    if c.medico_id != current_user.id:
        abort(403)

    fecha_str = request.form.get("fecha", "").strip()
    hora_str  = request.form.get("hora",  "").strip()
    motivo    = request.form.get("motivo", "").strip() or f"Seguimiento — consulta #{cid}"

    if not fecha_str or not hora_str:
        flash("Fecha y hora son obligatorias.", "error")
        return redirect(url_for("medico.consulta", consulta_id=cid))

    try:
        nueva_fecha = datetime.strptime(
            f"{fecha_str} {hora_str}", "%Y-%m-%d %H:%M"
        ).replace(tzinfo=timezone.utc)
    except ValueError:
        flash("Formato de fecha u hora inválido.", "error")
        return redirect(url_for("medico.consulta", consulta_id=cid))

    set_rls_context()
    nueva = Consulta(
        paciente_id=c.paciente_id,
        medico_id=current_user.id,
        fecha=nueva_fecha,
        motivo=motivo,
        estado=EstadoConsulta.agendada,
        consulta_padre_id=cid,
        solicitar_retinografia=False,   # el doctor activa explícitamente si la necesita
    )
    db.session.add(nueva)
    db.session.flush()

    db.session.add(Notificacion(
        usuario_id=c.paciente_id,
        tipo=TipoNotif.sistema,
        mensaje=(
            f"El Dr./Dra. {current_user.nombre} agendó una cita de seguimiento "
            f"para el {nueva_fecha.strftime('%d/%m/%Y a las %H:%M')}."
            + (f" Motivo: {motivo}" if motivo else "")
        ),
    ))
    db.session.commit()
    flash(f"Cita de seguimiento agendada para el {nueva_fecha.strftime('%d/%m/%Y a las %H:%M')}.", "success")
    return redirect(url_for("medico.agenda"))


# ── Analytics del médico ─────────────────────────────────────────────────────

_PROV_NOMBRES = {
    '1': 'Bocas del Toro', '2': 'Coclé', '3': 'Colón', '4': 'Chiriquí',
    '5': 'Darién', '6': 'Herrera', '7': 'Los Santos', '8': 'Panamá',
    '9': 'Veraguas', '10': 'Guna Yala', '11': 'Emberá-Wounaan',
    '12': 'Ngäbe-Buglé', '13': 'Panamá Oeste',
}
_PROV_COORDS = {
    'Panamá':          (9.10, -79.40), 'Coclé':           (8.50, -80.40),
    'Colón':           (9.35, -79.90), 'Chiriquí':        (8.39, -82.26),
    'Darién':          (7.90, -77.90), 'Herrera':         (7.96, -80.52),
    'Los Santos':      (7.60, -80.37), 'Veraguas':        (8.00, -81.10),
    'Bocas del Toro':  (9.33, -82.24), 'Ngäbe-Buglé':     (8.65, -81.73),
    'Emberá-Wounaan':  (8.10, -77.60), 'Panamá Oeste':    (8.80, -79.60),
    'Guna Yala':       (9.40, -78.60),
}


def _ultimos_12_meses():
    today = date.today()
    yr, mo = today.year, today.month
    result = []
    for _ in range(12):
        result.append(f"{yr:04d}-{mo:02d}")
        mo -= 1
        if mo == 0:
            mo, yr = 12, yr - 1
    return list(reversed(result))


@bp.route("/analytics")
@login_required
@role_required("medico")
def analytics():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    mid = current_user.id

    # KPIs
    kpis = db.session.execute(text("""
        SELECT
            (SELECT COUNT(DISTINCT a.paciente_id)
             FROM oftalmologia.asignacion a
             WHERE a.medico_id = :mid
               AND (a.hasta IS NULL OR a.hasta >= CURRENT_DATE))      AS pac_activos,
            (SELECT COUNT(DISTINCT c.paciente_id)
             FROM oftalmologia.consulta c
             WHERE c.medico_id = :mid AND c.estado = 'atendida')      AS pac_atendidos,
            (SELECT COUNT(*)
             FROM oftalmologia.diagnostico d
             JOIN oftalmologia.estudio e ON e.id = d.estudio_id
             JOIN oftalmologia.consulta c ON c.id = e.consulta_id
             WHERE c.medico_id = :mid AND d.vigente = true)           AS total_dx,
            (SELECT ROUND(AVG(pr.confianza)::numeric * 100, 1)
             FROM oftalmologia.prediccion pr
             JOIN oftalmologia.estudio e ON e.id = pr.estudio_id
             JOIN oftalmologia.consulta c ON c.id = e.consulta_id
             WHERE c.medico_id = :mid)                                AS conf_prom,
            (SELECT COUNT(*)
             FROM oftalmologia.consulta c
             WHERE c.medico_id = :mid AND c.estado = 'agendada')      AS citas_pendientes
    """), {"mid": mid}).fetchone()

    # Prevalencia de diagnósticos
    clase_labels = {
        'normal': 'Normal', 'rd': 'Retinopatía Diabética',
        'glaucoma': 'Glaucoma', 'catarata': 'Cataratas',
    }
    prev_rows = db.session.execute(text("""
        SELECT d.clase::text AS clase, COUNT(*) AS total
        FROM oftalmologia.diagnostico d
        JOIN oftalmologia.estudio e ON e.id = d.estudio_id
        JOIN oftalmologia.consulta c ON c.id = e.consulta_id
        WHERE c.medico_id = :mid AND d.vigente = true
        GROUP BY d.clase ORDER BY total DESC
    """), {"mid": mid}).fetchall()
    prevalencia = [
        {'clase': clase_labels.get(r.clase, r.clase), 'total': int(r.total)}
        for r in prev_rows
    ]

    # Tendencia mensual
    meses = _ultimos_12_meses()
    dx_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', d.creado_en), 'YYYY-MM') AS mes,
               COUNT(*) AS total
        FROM oftalmologia.diagnostico d
        JOIN oftalmologia.estudio e ON e.id = d.estudio_id
        JOIN oftalmologia.consulta c ON c.id = e.consulta_id
        WHERE c.medico_id = :mid
          AND d.creado_en >= NOW() - INTERVAL '13 months'
        GROUP BY mes
    """), {"mid": mid}).fetchall()
    citas_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', c.fecha), 'YYYY-MM') AS mes,
               COUNT(*) AS total
        FROM oftalmologia.consulta c
        WHERE c.medico_id = :mid
          AND c.fecha >= NOW() - INTERVAL '13 months'
        GROUP BY mes
    """), {"mid": mid}).fetchall()
    dx_dict    = {r.mes: int(r.total) for r in dx_rows}
    citas_dict = {r.mes: int(r.total) for r in citas_rows}
    tendencia = [
        {'mes': m, 'diagnosticos': dx_dict.get(m, 0), 'citas': citas_dict.get(m, 0)}
        for m in meses
    ]

    # Distribución geográfica de pacientes
    geo_rows = db.session.execute(text("""
        SELECT UPPER(SPLIT_PART(p.cedula, '-', 1)) AS cod_prov,
               COUNT(DISTINCT p.usuario_id)        AS n_pac
        FROM oftalmologia.consulta c
        JOIN oftalmologia.paciente p ON p.usuario_id = c.paciente_id
        WHERE c.medico_id = :mid
          AND p.cedula IS NOT NULL AND p.cedula <> ''
        GROUP BY cod_prov ORDER BY n_pac DESC
    """), {"mid": mid}).fetchall()
    geo_data = []
    for row in geo_rows:
        nombre = _PROV_NOMBRES.get(row.cod_prov, f'Prov. {row.cod_prov}')
        coords = _PROV_COORDS.get(nombre)
        if coords:
            geo_data.append({
                'provincia':   nombre,
                'lat':         coords[0],
                'lon':         coords[1],
                'n_pacientes': int(row.n_pac),
            })

    return render_template(
        "medico/analytics.html",
        modelo_activo=modelo_activo,
        kpis=kpis,
        prevalencia=prevalencia,
        tendencia=tendencia,
        geo_data=geo_data,
    )
