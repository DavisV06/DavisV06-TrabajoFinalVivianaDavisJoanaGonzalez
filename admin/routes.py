from datetime import date
from flask import render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user
from sqlalchemy import text

from admin import bp
from extensions import db
from models import Usuario, ModeloIA, RolApp
from utils.auth_helpers import role_required, set_rls_context


# ── Resumen general (Clínica) ────────────────────────────────────────────────

@bp.route("/")
@bp.route("/dashboard")
@login_required
@role_required("admin")
def dashboard():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    kpis = db.session.execute(text("""
        SELECT
            (SELECT COUNT(*) FROM oftalmologia.paciente)              AS total_pacientes,
            (SELECT COUNT(*) FROM oftalmologia.medico
             WHERE vigente_hasta IS NULL OR vigente_hasta >= CURRENT_DATE)
                                                                      AS medicos_activos,
            (SELECT COUNT(*) FROM oftalmologia.consulta)              AS total_citas,
            (SELECT COUNT(*) FROM oftalmologia.diagnostico WHERE vigente)
                                                                      AS dx_total,
            (SELECT COUNT(*) FROM oftalmologia.diagnostico
             WHERE vigente AND estado = 'pendiente')                  AS dx_pendientes,
            (SELECT ROUND(
                100.0 * COUNT(*) FILTER (WHERE estado = 'rectificado')
                / NULLIF(COUNT(*), 0), 1
             ) FROM oftalmologia.diagnostico WHERE vigente)           AS pct_rectificados,
            (SELECT COUNT(*) FROM oftalmologia.consulta
             WHERE estado = 'agendada')                               AS citas_agendadas
    """)).fetchone()

    citas_mes_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', fecha), 'YYYY-MM') AS mes,
               COUNT(*) AS total
        FROM oftalmologia.consulta
        WHERE fecha >= NOW() - INTERVAL '7 months'
        GROUP BY mes ORDER BY mes
    """)).fetchall()

    actividad = db.session.execute(text("""
        SELECT a.ocurrido_en, a.operacion, a.tabla, a.usuario_id,
               u.nombre AS nombre_usuario, u.rol
        FROM oftalmologia.auditoria a
        LEFT JOIN oftalmologia.usuario u ON u.id = a.usuario_id
        ORDER BY a.ocurrido_en DESC
        LIMIT 10
    """)).fetchall()

    medicos_tabla = db.session.execute(text("""
        SELECT u.nombre, m.especialidad,
               COUNT(DISTINCT c.paciente_id) AS pacientes,
               COUNT(c.id) FILTER (
                   WHERE c.fecha >= date_trunc('month', NOW())
               ) AS citas_mes,
               COUNT(d.id) AS total_dx,
               ROUND(100.0 * COUNT(d.id) FILTER (WHERE d.estado = 'rectificado')
                     / NULLIF(COUNT(d.id), 0), 1) AS tasa_rect
        FROM oftalmologia.medico m
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        LEFT JOIN oftalmologia.consulta c ON c.medico_id = m.usuario_id
        LEFT JOIN oftalmologia.estudio e ON e.consulta_id = c.id
        LEFT JOIN oftalmologia.diagnostico d ON d.estudio_id = e.id AND d.vigente
        WHERE u.activo = true
        GROUP BY u.nombre, m.especialidad
        ORDER BY citas_mes DESC NULLS LAST
    """)).fetchall()

    return render_template(
        "admin/dashboard.html",
        kpis=kpis,
        citas_mes_rows=citas_mes_rows,
        actividad=actividad,
        medicos_tabla=medicos_tabla,
        modelo_activo=modelo_activo,
    )


# ── Diagnósticos (concordancia IA) ───────────────────────────────────────────

@bp.route("/diagnosticos")
@login_required
@role_required("admin")
def diagnosticos():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    concordancia = db.session.execute(text("""
        SELECT
            COUNT(*) FILTER (WHERE estado = 'confirmado')  AS confirmados,
            COUNT(*) FILTER (WHERE estado = 'rectificado') AS rectificados,
            COUNT(*)                                        AS total,
            ROUND(100.0 * COUNT(*) FILTER (WHERE estado = 'confirmado')
                  / NULLIF(COUNT(*), 0), 1)                AS pct_concordancia
        FROM oftalmologia.diagnostico WHERE vigente
    """)).fetchone()

    clase_rows = db.session.execute(text("""
        SELECT d.clase::text AS clase,
               COUNT(*) AS total,
               COUNT(*) FILTER (WHERE d.estado = 'confirmado')  AS confirmados,
               COUNT(*) FILTER (WHERE d.estado = 'rectificado') AS rectificados
        FROM oftalmologia.diagnostico d
        WHERE d.vigente
        GROUP BY d.clase ORDER BY total DESC
    """)).fetchall()

    trend_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', d.creado_en), 'YYYY-MM') AS mes,
               COUNT(*) FILTER (WHERE d.estado = 'confirmado')  AS confirmados,
               COUNT(*) FILTER (WHERE d.estado = 'rectificado') AS rectificados
        FROM oftalmologia.diagnostico d
        WHERE d.vigente AND d.creado_en >= NOW() - INTERVAL '7 months'
        GROUP BY mes ORDER BY mes
    """)).fetchall()

    # Mapa de calor de actividad: día de la semana y hora, por tipo de usuario
    actividad_calor = db.session.execute(text("""
        SELECT rol, dia, hora, COUNT(*) AS total
        FROM (
            SELECT 'medico' AS rol,
                   EXTRACT(ISODOW FROM d.creado_en AT TIME ZONE 'America/Panama')::int AS dia,
                   EXTRACT(HOUR FROM d.creado_en AT TIME ZONE 'America/Panama')::int AS hora
            FROM oftalmologia.diagnostico d
            UNION ALL
            SELECT u.rol::text,
                   EXTRACT(ISODOW FROM e.tomado_en AT TIME ZONE 'America/Panama')::int,
                   EXTRACT(HOUR FROM e.tomado_en AT TIME ZONE 'America/Panama')::int
            FROM oftalmologia.estudio e
            JOIN oftalmologia.usuario u ON u.id = e.subido_por
            WHERE u.rol::text IN ('medico', 'paciente')
        ) eventos
        GROUP BY rol, dia, hora
    """)).fetchall()

    return render_template(
        "admin/diagnosticos.html",
        concordancia=concordancia,
        clase_rows=clase_rows,
        trend_rows=trend_rows,
        actividad_calor=[{'rol': r.rol, 'dia': r.dia, 'hora': r.hora, 'total': int(r.total)} for r in actividad_calor],
        modelo_activo=modelo_activo,
    )


# ── Equipo médico ────────────────────────────────────────────────────────────

@bp.route("/equipo")
@login_required
@role_required("admin")
def equipo():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    medicos = db.session.execute(text("""
        SELECT u.id, u.nombre, u.email, u.activo,
               m.especialidad, m.vigente_hasta,
               COUNT(DISTINCT c.paciente_id) FILTER (
                   WHERE c.fecha >= date_trunc('month', NOW())
               ) AS pac_activos,
               COUNT(c.id) FILTER (
                   WHERE c.fecha >= date_trunc('month', NOW())
               ) AS citas_mes,
               COUNT(d.id) AS total_dx,
               ROUND(100.0 * COUNT(d.id) FILTER (WHERE d.estado = 'rectificado')
                     / NULLIF(COUNT(d.id), 0), 1) AS tasa_rect
        FROM oftalmologia.medico m
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        LEFT JOIN oftalmologia.consulta c ON c.medico_id = m.usuario_id
        LEFT JOIN oftalmologia.estudio e ON e.consulta_id = c.id
        LEFT JOIN oftalmologia.diagnostico d ON d.estudio_id = e.id AND d.vigente
        GROUP BY u.id, u.nombre, u.email, u.activo, m.especialidad, m.vigente_hasta
        ORDER BY u.nombre
    """)).fetchall()

    return render_template(
        "admin/equipo.html",
        medicos=medicos,
        modelo_activo=modelo_activo,
    )


# ── Gestión de usuarios ──────────────────────────────────────────────────────

@bp.route("/usuarios")
@login_required
@role_required("admin")
def usuarios():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    q = request.args.get("q", "").strip()
    rol_filter = request.args.get("rol", "")

    query = Usuario.query
    if q:
        query = query.filter(
            (Usuario.nombre.ilike(f"%{q}%")) | (Usuario.email.ilike(f"%{q}%"))
        )
    if rol_filter and rol_filter in [r.value for r in RolApp]:
        query = query.filter_by(rol=RolApp(rol_filter))

    users = query.order_by(Usuario.creado_en.desc()).all()
    return render_template(
        "admin/usuarios.html",
        users=users,
        q=q,
        rol_filter=rol_filter,
        RolApp=RolApp,
        modelo_activo=modelo_activo,
    )


@bp.route("/usuarios/<int:uid>/toggle", methods=["POST"])
@login_required
@role_required("admin")
def toggle_usuario(uid):
    if uid == current_user.id:
        flash("No puedes desactivar tu propia cuenta.", "error")
        return redirect(url_for("admin.usuarios"))

    user = Usuario.query.get_or_404(uid)
    set_rls_context()
    user.activo = not user.activo
    db.session.commit()
    estado = "activada" if user.activo else "desactivada"
    flash(f"Cuenta de {user.nombre} {estado}.", "success")
    return redirect(url_for("admin.usuarios"))


# ── Cancelación de datos personales: anonimización (Ley 81 de 2019) ─────────

@bp.route("/pacientes/<int:uid>/anonimizar", methods=["POST"])
@login_required
@role_required("admin")
def anonimizar_paciente(uid):
    """Sustituye los datos identificativos del paciente y conserva su historial clínico.
    La operación la hace la función de base de datos fn_anonimizar_paciente, que además
    elimina esos datos de las copias guardadas en la auditoría y en los avisos."""
    from sqlalchemy.exc import DBAPIError
    destino = url_for("admin.usuarios")
    try:
        set_rls_context()
        db.session.execute(text("SELECT oftalmologia.fn_anonimizar_paciente(:p)"), {"p": uid})
        flash(f"Paciente #{uid} anonimizado. Su historial clínico se conserva sin datos identificativos.", "success")
        db.session.commit()
    except DBAPIError:
        db.session.rollback()
        flash("No se pudo anonimizar: el paciente no existe o ya estaba anonimizado.", "error")
    return redirect(destino)


# ── Modelos IA ───────────────────────────────────────────────────────────────

@bp.route("/modelos")
@login_required
@role_required("admin")
def modelos():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    modelos_all = ModeloIA.query.order_by(ModeloIA.entrenado_en.desc().nulls_last()).all()
    return render_template(
        "admin/modelos.html",
        modelos=modelos_all,
        modelo_activo=modelo_activo,
    )


# El modelo activo es fijo (ResNet50, seleccionado en la evaluación de modelos):
# el servidor solo carga ResNet50 para la inferencia, así que permitir activar otro
# registraría predicciones a nombre de un modelo que no las generó.


# ── Auditoría ────────────────────────────────────────────────────────────────

@bp.route("/auditoria")
@login_required
@role_required("admin")
def auditoria():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()
    operacion = request.args.get("operacion", "")
    tabla     = request.args.get("tabla", "")
    usuario_q = request.args.get("usuario", "").strip()
    page      = request.args.get("page", 1, type=int)
    per_page  = 30

    base = """
        SELECT a.id, a.ocurrido_en, a.operacion, a.tabla,
               a.registro_id, a.usuario_id,
               a.ip, u.nombre AS nombre_usuario, u.rol
        FROM oftalmologia.auditoria a
        LEFT JOIN oftalmologia.usuario u ON u.id = a.usuario_id
        WHERE 1=1
    """
    params: dict = {}
    if operacion:
        base += " AND a.operacion = :op"
        params["op"] = operacion
    if tabla:
        base += " AND a.tabla = :tabla"
        params["tabla"] = tabla
    if usuario_q:
        base += " AND u.nombre ILIKE :uq"
        params["uq"] = f"%{usuario_q}%"

    count_sql = f"SELECT COUNT(*) FROM ({base}) sub"
    total = db.session.execute(text(count_sql), params).scalar() or 0

    base += " ORDER BY a.ocurrido_en DESC LIMIT :limit OFFSET :offset"
    params["limit"]  = per_page
    params["offset"] = (page - 1) * per_page
    registros = db.session.execute(text(base), params).fetchall()

    total_pages = max(1, (total + per_page - 1) // per_page)
    tablas_disponibles = db.session.execute(
        text("SELECT DISTINCT tabla FROM oftalmologia.auditoria ORDER BY tabla")
    ).scalars().all()

    return render_template(
        "admin/auditoria.html",
        registros=registros,
        page=page,
        total_pages=total_pages,
        total=total,
        operacion=operacion,
        tabla=tabla,
        usuario_q=usuario_q,
        tablas_disponibles=tablas_disponibles,
        modelo_activo=modelo_activo,
    )


# ── Tableros analíticos ──────────────────────────────────────────────────────

_PROV_NOMBRES = {
    '1': 'Bocas del Toro', '2': 'Coclé', '3': 'Colón', '4': 'Chiriquí',
    '5': 'Darién', '6': 'Herrera', '7': 'Los Santos', '8': 'Panamá',
    '9': 'Veraguas', '10': 'Guna Yala', '11': 'Emberá-Wounaan',
    '12': 'Ngäbe-Buglé', '13': 'Panamá Oeste',
}
_PROV_COORDS = {
    'Panamá':          (9.10, -79.40),
    'Coclé':           (8.50, -80.40),
    'Colón':           (9.35, -79.90),
    'Chiriquí':        (8.39, -82.26),
    'Darién':          (7.90, -77.90),
    'Herrera':         (7.96, -80.52),
    'Los Santos':      (7.60, -80.37),
    'Veraguas':        (8.00, -81.10),
    'Bocas del Toro':  (9.33, -82.24),
    'Ngäbe-Buglé':     (8.65, -81.73),
    'Emberá-Wounaan':  (8.10, -77.60),
    'Panamá Oeste':    (8.80, -79.60),
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
@role_required("admin")
def analytics():
    modelo_activo = ModeloIA.query.filter_by(activo=True).first()

    # KPIs
    kpis = db.session.execute(text("""
        SELECT
            (SELECT COUNT(*) FROM oftalmologia.paciente)                  AS total_pacientes,
            (SELECT COUNT(*) FROM oftalmologia.estudio)                   AS total_estudios,
            (SELECT COUNT(*) FROM oftalmologia.diagnostico WHERE vigente)  AS total_dx,
            (SELECT ROUND(AVG(confianza)::numeric * 100, 1)
             FROM oftalmologia.prediccion)                                AS conf_prom,
            (SELECT COUNT(*) FROM oftalmologia.consulta
             WHERE estado = 'agendada')                                   AS citas_pendientes
    """)).fetchone()

    # Prevalencia
    clase_labels = {
        'normal': 'Normal', 'rd': 'Retinopatía Diabética',
        'glaucoma': 'Glaucoma', 'catarata': 'Cataratas',
    }
    prev_rows = db.session.execute(text("""
        SELECT d.clase::text AS clase, COUNT(*) AS total
        FROM oftalmologia.diagnostico d
        WHERE d.vigente = true
        GROUP BY d.clase ORDER BY total DESC
    """)).fetchall()
    prevalencia = [
        {'clase': clase_labels.get(r.clase, r.clase), 'total': int(r.total)}
        for r in prev_rows
    ]

    # Tendencia mensual (últimos 12 meses)
    meses = _ultimos_12_meses()
    dx_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', d.creado_en), 'YYYY-MM') AS mes,
               COUNT(*) AS total
        FROM oftalmologia.diagnostico d
        WHERE d.creado_en >= NOW() - INTERVAL '13 months'
        GROUP BY mes
    """)).fetchall()
    est_rows = db.session.execute(text("""
        SELECT TO_CHAR(DATE_TRUNC('month', e.tomado_en), 'YYYY-MM') AS mes,
               COUNT(*) AS total
        FROM oftalmologia.estudio e
        WHERE e.tomado_en >= NOW() - INTERVAL '13 months'
        GROUP BY mes
    """)).fetchall()
    dx_dict  = {r.mes: int(r.total) for r in dx_rows}
    est_dict = {r.mes: int(r.total) for r in est_rows}
    tendencia = [
        {'mes': m, 'diagnosticos': dx_dict.get(m, 0), 'estudios': est_dict.get(m, 0)}
        for m in meses
    ]

    # Estado de consultas
    estado_labels = {
        'agendada': 'Agendadas', 'atendida': 'Atendidas',
        'cancelada': 'Canceladas', 'referida': 'Referidas',
    }
    est_cita_rows = db.session.execute(text("""
        SELECT estado::text AS estado, COUNT(*) AS total
        FROM oftalmologia.consulta
        GROUP BY estado ORDER BY total DESC
    """)).fetchall()
    estados = [
        {'estado': estado_labels.get(r.estado, r.estado), 'total': int(r.total)}
        for r in est_cita_rows
    ]

    # Distribución geográfica (desde cédula panameña)
    geo_rows = db.session.execute(text("""
        SELECT UPPER(SPLIT_PART(p.cedula, '-', 1)) AS cod_prov,
               COUNT(DISTINCT p.usuario_id)        AS n_pac,
               COUNT(DISTINCT e.id)                AS n_est
        FROM oftalmologia.paciente p
        LEFT JOIN oftalmologia.consulta c ON c.paciente_id = p.usuario_id
        LEFT JOIN oftalmologia.estudio  e ON e.consulta_id = c.id
        WHERE p.cedula IS NOT NULL AND p.cedula <> ''
        GROUP BY cod_prov
        ORDER BY n_pac DESC
    """)).fetchall()
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
                'n_estudios':  int(row.n_est),
            })

    # Mapa de calor: pacientes por provincia, filtrables por médico y paciente
    medicos_mapa = db.session.execute(text("""
        SELECT u.id, u.nombre
        FROM oftalmologia.medico m
        JOIN oftalmologia.usuario u ON u.id = m.usuario_id
        ORDER BY u.nombre
    """)).fetchall()
    enlaces = db.session.execute(text("""
        SELECT paciente_id, medico_id FROM oftalmologia.consulta
        UNION
        SELECT paciente_id, medico_id FROM oftalmologia.asignacion
        WHERE hasta IS NULL OR hasta >= CURRENT_DATE
    """)).fetchall()
    medicos_por_paciente = {}
    for e in enlaces:
        medicos_por_paciente.setdefault(e.paciente_id, []).append(e.medico_id)
    pacientes_rows = db.session.execute(text("""
        SELECT p.usuario_id, u.nombre, UPPER(SPLIT_PART(p.cedula, '-', 1)) AS cod_prov
        FROM oftalmologia.paciente p
        JOIN oftalmologia.usuario u ON u.id = p.usuario_id
        ORDER BY u.nombre
    """)).fetchall()
    calor_pacientes = [
        {
            'id': r.usuario_id,
            'nombre': r.nombre,
            'provincia': _PROV_NOMBRES.get(r.cod_prov),
            'medicos': medicos_por_paciente.get(r.usuario_id, []),
        }
        for r in pacientes_rows
    ]

    return render_template(
        "admin/analytics.html",
        modelo_activo=modelo_activo,
        kpis=kpis,
        prevalencia=prevalencia,
        tendencia=tendencia,
        estados=estados,
        geo_data=geo_data,
        calor_pacientes=calor_pacientes,
        calor_medicos=[{'id': m.id, 'nombre': m.nombre} for m in medicos_mapa],
        calor_provincias=list(_PROV_NOMBRES.values()),
    )
