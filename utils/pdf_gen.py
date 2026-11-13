"""PDF report generation for patient studies using ReportLab."""

import os
from datetime import datetime
from io import BytesIO

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import cm
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, HRFlowable
)


TEAL = colors.HexColor("#0d7c6b")
NAVY = colors.HexColor("#0b2d4e")
AMBER = colors.HexColor("#d48f00")
LIGHT_GRAY = colors.HexColor("#f0f4f8")
MUTED = colors.HexColor("#5d6f84")


def build_pdf_report(paciente, consultas_con_estudios: list) -> bytes:
    """Build and return PDF bytes for a patient's ophthalmological report.

    Args:
        paciente: Paciente ORM object with .usuario relationship.
        consultas_con_estudios: list of Consulta objects with .estudios populated.
    """
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        rightMargin=2 * cm,
        leftMargin=2 * cm,
        topMargin=2 * cm,
        bottomMargin=2.5 * cm,
        title="Expediente Clínico Oftalmológico",
    )

    styles = getSampleStyleSheet()
    story = []

    h1 = ParagraphStyle("h1", parent=styles["Heading1"], textColor=NAVY,
                         fontSize=18, spaceAfter=4)
    h2 = ParagraphStyle("h2", parent=styles["Heading2"], textColor=TEAL,
                         fontSize=13, spaceBefore=16, spaceAfter=4)
    normal = ParagraphStyle("normal", parent=styles["Normal"], fontSize=10,
                             leading=14, textColor=colors.HexColor("#1e2a3a"))
    caption = ParagraphStyle("caption", parent=styles["Normal"], fontSize=8,
                              textColor=MUTED, leading=12)
    warn = ParagraphStyle("warn", parent=styles["Normal"], fontSize=9,
                           textColor=AMBER, leading=12)

    # ── Header ──────────────────────────────────────────────────────────
    story.append(Paragraph("Sistema de Detección Asistida de Enfermedades Oftalmológicas", h1))
    story.append(Paragraph("Expediente Clínico — Resultado de Retinografías", styles["Heading3"]))
    story.append(HRFlowable(width="100%", color=TEAL, thickness=1.5, spaceAfter=8))

    # ── Legal notice ────────────────────────────────────────────────────
    story.append(Paragraph(
        "⚠ <b>AVISO LEGAL:</b> Los resultados del modelo predictivo contenidos en este "
        "documento son de carácter preliminar. El diagnóstico definitivo debe ser emitido por un "
        "profesional médico idóneo en oftalmología. Este documento no sustituye la consulta médica.",
        warn,
    ))
    story.append(Spacer(1, 0.4 * cm))

    # ── Patient info ────────────────────────────────────────────────────
    story.append(Paragraph("Datos del Paciente", h2))
    edad = paciente.edad or "—"
    sexo = {"M": "Masculino", "F": "Femenino", "O": "Otro"}.get(paciente.sexo or "", "—")
    info = [
        ["Nombre completo:", paciente.usuario.nombre,  "Cédula:",      paciente.cedula or "—"],
        ["Edad:",            f"{edad} años",            "Sexo:",        sexo],
        ["Fecha del informe:", datetime.today().strftime("%d/%m/%Y"), "", ""],
    ]
    t = Table(info, colWidths=[4 * cm, 6 * cm, 3 * cm, 4 * cm])
    t.setStyle(TableStyle([
        ("FONTNAME",    (0, 0), (-1, -1), "Helvetica"),
        ("FONTSIZE",    (0, 0), (-1, -1), 9),
        ("FONTNAME",    (0, 0), (0, -1), "Helvetica-Bold"),
        ("FONTNAME",    (2, 0), (2, -1), "Helvetica-Bold"),
        ("TEXTCOLOR",   (0, 0), (-1, -1), colors.HexColor("#1e2a3a")),
        ("BACKGROUND",  (0, 0), (-1, -1), LIGHT_GRAY),
        ("ROWBACKGROUNDS", (0, 0), (-1, -1), [LIGHT_GRAY, colors.white]),
        ("GRID",        (0, 0), (-1, -1), 0.3, colors.HexColor("#d4dde9")),
        ("TOPPADDING",  (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(t)
    story.append(Spacer(1, 0.5 * cm))

    # ── Studies ─────────────────────────────────────────────────────────
    for consulta in consultas_con_estudios:
        story.append(Paragraph(
            f"Consulta del {consulta.fecha.strftime('%d/%m/%Y %H:%M')} "
            f"— Dr./Dra. {consulta.medico.usuario.nombre}", h2
        ))
        if consulta.motivo:
            story.append(Paragraph(f"<b>Motivo:</b> {consulta.motivo}", normal))
        story.append(Spacer(1, 0.25 * cm))

        for estudio in consulta.estudios:
            ojo_label = "Ojo Derecho (OD)" if estudio.ojo == "R" else "Ojo Izquierdo (OI)"
            story.append(Paragraph(f"<b>{ojo_label}</b>", normal))

            # Image
            img_ruta = None
            if estudio.imagen:
                from flask import current_app
                img_ruta = os.path.join(current_app.config["UPLOAD_FOLDER"],
                                        os.path.basename(estudio.imagen.ruta))
            if img_ruta and os.path.exists(img_ruta):
                try:
                    img = Image(img_ruta, width=5 * cm, height=5 * cm)
                    story.append(img)
                except Exception:
                    story.append(Paragraph("[Imagen no disponible]", caption))
            else:
                story.append(Paragraph("[Imagen no disponible]", caption))

            # AI prediction
            pred = estudio.prediccion_principal
            if pred and pred.probabilidades:
                prob_data = [["Clase", "Probabilidad (modelo predictivo)"]]
                for pp in pred.probabilidades:
                    cls = pp.clase.label if hasattr(pp.clase, 'label') else str(pp.clase)
                    prob_data.append([cls, f"{pp.porcentaje} %"])
                pt = Table(prob_data, colWidths=[6.5 * cm, 6.5 * cm])
                pt.setStyle(TableStyle([
                    ("BACKGROUND", (0, 0), (-1, 0), TEAL),
                    ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
                    ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
                    ("FONTSIZE",   (0, 0), (-1, -1), 9),
                    ("GRID",       (0, 0), (-1, -1), 0.3, colors.HexColor("#d4dde9")),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                    ("ROWBACKGROUNDS", (1, 0), (-1, -1), [colors.white, LIGHT_GRAY]),
                ]))
                story.append(pt)

            # Medical diagnosis
            dx = estudio.diagnostico_vigente
            if dx:
                estado = dx.estado.value if hasattr(dx.estado, 'value') else str(dx.estado)
                clase_label = dx.clase_label if hasattr(dx, 'clase_label') else str(dx.clase)
                story.append(Spacer(1, 0.2 * cm))
                story.append(Paragraph(
                    f"<b>Diagnóstico médico ({estado}):</b> {clase_label} "
                    f"— Dr./Dra. {dx.medico.usuario.nombre} ({dx.creado_en.strftime('%d/%m/%Y')})",
                    normal,
                ))
                if dx.observaciones:
                    story.append(Paragraph(f"<i>Observaciones: {dx.observaciones}</i>", caption))
            else:
                story.append(Paragraph("<i>Diagnóstico médico pendiente de revisión.</i>", caption))

            story.append(Spacer(1, 0.4 * cm))

    # ── Footer ──────────────────────────────────────────────────────────
    story.append(HRFlowable(width="100%", color=MUTED, thickness=0.5))
    story.append(Spacer(1, 0.2 * cm))
    story.append(Paragraph(
        "Documento generado automáticamente por el Sistema de Detección Asistida de "
        "Enfermedades Oftalmológicas. Confidencial. Uso exclusivo del paciente y del "
        "médico tratante. Ley 81 de 2019 — Protección de Datos Personales, Panamá.",
        caption,
    ))

    doc.build(story)
    return buffer.getvalue()
