"""SQLAlchemy ORM models for the oftalmologia schema."""

import enum
from datetime import datetime, timezone
from extensions import db
from flask_login import UserMixin
from sqlalchemy import (
    BigInteger, Boolean, Column, Date, DateTime, Enum, Float,
    Integer, Numeric, String, Text, UniqueConstraint,
    ForeignKey, Index,
)
from sqlalchemy.dialects.postgresql import INET, JSONB
from sqlalchemy.orm import relationship

SCHEMA = "oftalmologia"


# ── Enumeraciones (mirrors PostgreSQL ENUMs) ───────────────────────────────

class RolApp(str, enum.Enum):
    paciente = "paciente"
    medico   = "medico"
    admin    = "admin"


class ClaseDx(str, enum.Enum):
    normal   = "normal"
    rd       = "rd"
    glaucoma = "glaucoma"
    catarata = "catarata"

    @property
    def label(self):
        labels = {
            "normal":   "Normal",
            "rd":       "Retinopatía Diabética",
            "glaucoma": "Glaucoma",
            "catarata": "Cataratas",
        }
        return labels.get(self.value, self.value)


class EstadoDx(str, enum.Enum):
    pendiente   = "pendiente"
    confirmado  = "confirmado"
    rectificado = "rectificado"


class EstadoConsulta(str, enum.Enum):
    agendada  = "agendada"
    atendida  = "atendida"
    cancelada = "cancelada"
    referida  = "referida"

    @property
    def label(self):
        labels = {
            "agendada":  "Agendada",
            "atendida":  "Atendida",
            "cancelada": "Cancelada",
            "referida":  "Referida",
        }
        return labels.get(self.value, self.value.title())

    @property
    def badge(self):
        badges = {
            "agendada":  "info",
            "atendida":  "success",
            "cancelada": "danger",
            "referida":  "warning",
        }
        return badges.get(self.value, "badge-neutral")


class TipoAsig(str, enum.Enum):
    tratante      = "tratante"
    interconsulta = "interconsulta"
    cobertura     = "cobertura"


class TipoNotif(str, enum.Enum):
    diagnostico_listo = "diagnostico_listo"
    estudio_cargado   = "estudio_cargado"
    asignacion_nueva  = "asignacion_nueva"
    sistema           = "sistema"


# ── Tablas principales ────────────────────────────────────────────────────

class Usuario(UserMixin, db.Model):
    __tablename__ = "usuario"
    __table_args__ = {"schema": SCHEMA}

    id            = Column(BigInteger, primary_key=True)
    email         = Column(String(255), nullable=False, unique=True)
    password_hash = Column(Text, nullable=False)
    rol           = Column(Enum(RolApp, schema=SCHEMA, name="rol_app"), nullable=False)
    nombre        = Column(Text, nullable=False)
    telefono      = Column(Text)
    activo        = Column(Boolean, nullable=False, default=True)
    creado_en     = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    # Consentimiento expreso del tratamiento de datos (Ley 81 de 2019)
    consentimiento_en      = Column(DateTime(timezone=True))
    consentimiento_version = Column(Text)

    paciente_data = relationship("Paciente", back_populates="usuario", uselist=False)
    medico_data   = relationship("Medico",   back_populates="usuario", uselist=False)
    notificaciones = relationship("Notificacion", back_populates="usuario",
                                  foreign_keys="Notificacion.usuario_id",
                                  order_by="Notificacion.creada_en.desc()")

    def __repr__(self):
        return f"<Usuario {self.email}>"

    @property
    def is_active(self):
        return self.activo

    @property
    def pendientes_count(self):
        return sum(1 for n in self.notificaciones if n.leida_en is None)


class Paciente(db.Model):
    __tablename__ = "paciente"
    __table_args__ = {"schema": SCHEMA}

    usuario_id  = Column(BigInteger, ForeignKey(f"{SCHEMA}.usuario.id", ondelete="RESTRICT"), primary_key=True)
    cedula      = Column(Text, unique=True)
    fecha_nac   = Column(Date)
    sexo        = Column(String(1))
    anonimizado = Column(Boolean, nullable=False, default=False)
    cancelacion_solicitada_en = Column(DateTime(timezone=True))
    anonimizado_en            = Column(DateTime(timezone=True))

    usuario   = relationship("Usuario", back_populates="paciente_data")
    consultas = relationship("Consulta", back_populates="paciente",
                             foreign_keys="Consulta.paciente_id",
                             order_by="Consulta.fecha.desc()")

    @property
    def edad(self):
        if self.fecha_nac:
            today = datetime.today().date()
            return today.year - self.fecha_nac.year - (
                (today.month, today.day) < (self.fecha_nac.month, self.fecha_nac.day)
            )
        return None


class Medico(db.Model):
    __tablename__ = "medico"
    __table_args__ = {"schema": SCHEMA}

    usuario_id    = Column(BigInteger, ForeignKey(f"{SCHEMA}.usuario.id", ondelete="RESTRICT"), primary_key=True)
    num_idoneidad = Column(Text, nullable=False, unique=True)
    especialidad  = Column(Text)
    vigente_hasta = Column(Date)

    usuario    = relationship("Usuario", back_populates="medico_data")
    consultas  = relationship("Consulta", back_populates="medico",
                              foreign_keys="Consulta.medico_id")
    asignaciones = relationship("Asignacion", back_populates="medico",
                                foreign_keys="Asignacion.medico_id")

    @property
    def idoneidad_vigente(self):
        if self.vigente_hasta is None:
            return True
        return self.vigente_hasta >= datetime.today().date()


class Asignacion(db.Model):
    __tablename__ = "asignacion"
    __table_args__ = (
        UniqueConstraint("medico_id", "paciente_id", "desde"),
        {"schema": SCHEMA},
    )

    id          = Column(BigInteger, primary_key=True)
    medico_id   = Column(BigInteger, ForeignKey(f"{SCHEMA}.medico.usuario_id",   ondelete="RESTRICT"), nullable=False)
    paciente_id = Column(BigInteger, ForeignKey(f"{SCHEMA}.paciente.usuario_id", ondelete="RESTRICT"), nullable=False)
    tipo        = Column(Enum(TipoAsig, schema=SCHEMA, name="tipo_asig"), nullable=False, default=TipoAsig.tratante)
    desde       = Column(Date, nullable=False, default=lambda: datetime.today().date())
    hasta       = Column(Date)

    medico   = relationship("Medico",   back_populates="asignaciones", foreign_keys=[medico_id])
    paciente = relationship("Paciente", foreign_keys=[paciente_id])

    @property
    def vigente(self):
        today = datetime.today().date()
        return self.hasta is None or self.hasta >= today


class Consulta(db.Model):
    __tablename__ = "consulta"
    __table_args__ = {"schema": SCHEMA}

    id                = Column(BigInteger, primary_key=True)
    paciente_id       = Column(BigInteger, ForeignKey(f"{SCHEMA}.paciente.usuario_id", ondelete="RESTRICT"), nullable=False)
    medico_id         = Column(BigInteger, ForeignKey(f"{SCHEMA}.medico.usuario_id",   ondelete="RESTRICT"), nullable=False)
    fecha             = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    motivo            = Column(Text)
    notas             = Column(Text)
    estado            = Column(Enum(EstadoConsulta, schema=SCHEMA, name="estado_consulta"),
                               nullable=False, default=EstadoConsulta.agendada)
    referida_a        = Column(BigInteger, ForeignKey(f"{SCHEMA}.medico.usuario_id"))
    notas_cancel      = Column(Text)
    modificada_en     = Column(DateTime(timezone=True))
    consulta_padre_id      = Column(BigInteger, ForeignKey(f"{SCHEMA}.consulta.id"))
    notas_medico           = Column(Text)
    plan_tratamiento       = Column(Text)
    solicitar_retinografia = Column(Boolean, nullable=False, default=True)

    paciente       = relationship("Paciente", back_populates="consultas", foreign_keys=[paciente_id])
    medico         = relationship("Medico",   back_populates="consultas", foreign_keys=[medico_id])
    medico_ref     = relationship("Medico",                               foreign_keys=[referida_a])
    estudios       = relationship("Estudio",  back_populates="consulta",  order_by="Estudio.tomado_en.desc()")
    @property
    def padre(self):
        if not self.consulta_padre_id:
            return None
        return db.session.get(Consulta, self.consulta_padre_id)


class Imagen(db.Model):
    __tablename__ = "imagen"
    __table_args__ = {"schema": SCHEMA}

    id         = Column(BigInteger, primary_key=True)
    ruta       = Column(Text, nullable=False)
    sha256     = Column(String(64), nullable=False, unique=True)
    ancho      = Column(Integer)
    alto       = Column(Integer)
    formato    = Column(Text)
    bytes      = Column(BigInteger)
    cargada_en = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    estudio = relationship("Estudio", back_populates="imagen", uselist=False)


class Estudio(db.Model):
    __tablename__ = "estudio"
    __table_args__ = {"schema": SCHEMA}

    id          = Column(BigInteger, primary_key=True)
    consulta_id = Column(BigInteger, ForeignKey(f"{SCHEMA}.consulta.id",  ondelete="RESTRICT"), nullable=False)
    imagen_id   = Column(BigInteger, ForeignKey(f"{SCHEMA}.imagen.id",    ondelete="RESTRICT"), nullable=False, unique=True)
    ojo         = Column(String(1), nullable=False)
    tomado_en   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    subido_por  = Column(BigInteger, ForeignKey(f"{SCHEMA}.usuario.id",   ondelete="RESTRICT"), nullable=False)

    consulta    = relationship("Consulta",    back_populates="estudios",  foreign_keys=[consulta_id])
    imagen      = relationship("Imagen",      back_populates="estudio",   foreign_keys=[imagen_id])
    predicciones = relationship("Prediccion", back_populates="estudio",   order_by="Prediccion.generado_en.desc()")
    diagnosticos = relationship("Diagnostico", back_populates="estudio",  order_by="Diagnostico.version.desc()")

    @property
    def diagnostico_vigente(self):
        return next((d for d in self.diagnosticos if d.vigente), None)

    @property
    def prediccion_principal(self):
        return self.predicciones[0] if self.predicciones else None

    @property
    def ojo_label(self):
        return "Ojo Derecho" if self.ojo == "R" else "Ojo Izquierdo"


class ModeloIA(db.Model):
    __tablename__ = "modelo"
    __table_args__ = {"schema": SCHEMA}

    id            = Column(Integer, primary_key=True)
    nombre        = Column(Text, nullable=False)
    version       = Column(Text, nullable=False)
    arquitectura  = Column(Text)
    hash_pesos    = Column(String(64))
    entrenado_en  = Column(Date)
    activo        = Column(Boolean, nullable=False, default=False)
    registrado_en = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    predicciones = relationship("Prediccion", back_populates="modelo")
    evaluaciones = relationship("Evaluacion", back_populates="modelo")

    def accuracy_global(self):
        from sqlalchemy import text
        result = db.session.execute(
            text("""
                SELECT m.valor FROM oftalmologia.metrica m
                JOIN oftalmologia.evaluacion e ON e.id = m.evaluacion_id
                WHERE e.modelo_id = :mid AND m.nombre = 'exactitud' AND m.clase IS NULL
                ORDER BY m.id DESC LIMIT 1
            """),
            {"mid": self.id},
        ).fetchone()
        return float(result[0]) if result else None


class Prediccion(db.Model):
    __tablename__ = "prediccion"
    __table_args__ = {"schema": SCHEMA}

    id          = Column(BigInteger, primary_key=True)
    estudio_id  = Column(BigInteger, ForeignKey(f"{SCHEMA}.estudio.id", ondelete="RESTRICT"), nullable=False)
    modelo_id   = Column(Integer,    ForeignKey(f"{SCHEMA}.modelo.id",  ondelete="RESTRICT"), nullable=False)
    clase       = Column(Enum(ClaseDx, schema=SCHEMA, name="clase_dx"), nullable=False)
    confianza   = Column(Numeric(5, 4))
    ms_computo  = Column(Integer)
    generado_en = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    estudio       = relationship("Estudio",   back_populates="predicciones", foreign_keys=[estudio_id])
    modelo        = relationship("ModeloIA",  back_populates="predicciones", foreign_keys=[modelo_id])
    probabilidades = relationship("PrediccionProb", back_populates="prediccion",
                                  cascade="all, delete-orphan",
                                  order_by="PrediccionProb.valor.desc()")


class PrediccionProb(db.Model):
    __tablename__ = "prediccion_probabilidad"
    __table_args__ = {"schema": SCHEMA}

    prediccion_id = Column(BigInteger, ForeignKey(f"{SCHEMA}.prediccion.id", ondelete="CASCADE"), primary_key=True)
    clase         = Column(Enum(ClaseDx, schema=SCHEMA, name="clase_dx"), primary_key=True)
    valor         = Column(Numeric(6, 5), nullable=False)

    prediccion = relationship("Prediccion", back_populates="probabilidades")

    @property
    def porcentaje(self):
        return round(float(self.valor) * 100, 1)


class Diagnostico(db.Model):
    __tablename__ = "diagnostico"
    __table_args__ = {"schema": SCHEMA}

    id            = Column(BigInteger, primary_key=True)
    estudio_id    = Column(BigInteger, ForeignKey(f"{SCHEMA}.estudio.id",       ondelete="RESTRICT"), nullable=False)
    version       = Column(Integer, nullable=False)
    clase         = Column(Enum(ClaseDx,   schema=SCHEMA, name="clase_dx"),    nullable=False)
    estado        = Column(Enum(EstadoDx,  schema=SCHEMA, name="estado_dx"),   nullable=False, default=EstadoDx.confirmado)
    observaciones = Column(Text)
    motivo_cambio = Column(Text)
    medico_id     = Column(BigInteger, ForeignKey(f"{SCHEMA}.medico.usuario_id", ondelete="RESTRICT"), nullable=False)
    creado_en     = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    vigente       = Column(Boolean, nullable=False, default=True)

    estudio = relationship("Estudio", back_populates="diagnosticos", foreign_keys=[estudio_id])
    medico  = relationship("Medico",  foreign_keys=[medico_id])

    @property
    def clase_label(self):
        return ClaseDx(self.clase).label if isinstance(self.clase, str) else self.clase.label

    @property
    def estado_badge(self):
        badges = {
            EstadoDx.pendiente:   "badge-pending",
            EstadoDx.confirmado:  "badge-success",
            EstadoDx.rectificado: "badge-warning",
        }
        return badges.get(self.estado, "badge-neutral")


class Notificacion(db.Model):
    __tablename__ = "notificacion"
    __table_args__ = {"schema": SCHEMA}

    id             = Column(BigInteger, primary_key=True)
    usuario_id     = Column(BigInteger, ForeignKey(f"{SCHEMA}.usuario.id",      ondelete="RESTRICT"), nullable=False)
    diagnostico_id = Column(BigInteger, ForeignKey(f"{SCHEMA}.diagnostico.id", ondelete="RESTRICT"))
    tipo           = Column(Enum(TipoNotif, schema=SCHEMA, name="tipo_notif"), nullable=False)
    mensaje        = Column(Text, nullable=False)
    creada_en      = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    leida_en       = Column(DateTime(timezone=True))

    usuario = relationship("Usuario", back_populates="notificaciones", foreign_keys=[usuario_id])


class Auditoria(db.Model):
    __tablename__ = "auditoria"
    __table_args__ = {"schema": SCHEMA}

    id            = Column(BigInteger, primary_key=True)
    tabla         = Column(Text, nullable=False)
    registro_id   = Column(BigInteger)
    operacion     = Column(String(1), nullable=False)
    usuario_id    = Column(BigInteger)
    datos_antes   = Column(JSONB)
    datos_despues = Column(JSONB)
    ip            = Column(INET)
    ocurrido_en   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    @property
    def operacion_label(self):
        return {"I": "Inserción", "U": "Actualización", "D": "Eliminación"}.get(self.operacion, self.operacion)


class Evaluacion(db.Model):
    __tablename__ = "evaluacion"
    __table_args__ = {"schema": SCHEMA}

    id          = Column(BigInteger, primary_key=True)
    modelo_id   = Column(Integer, ForeignKey(f"{SCHEMA}.modelo.id",          ondelete="RESTRICT"), nullable=False)
    conjunto_id = Column(Integer, ForeignKey(f"{SCHEMA}.conjunto_prueba.id", ondelete="RESTRICT"), nullable=False)
    corrida_en  = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    notas       = Column(Text)

    modelo   = relationship("ModeloIA", back_populates="evaluaciones", foreign_keys=[modelo_id])
    metricas = relationship("Metrica",  back_populates="evaluacion", cascade="all, delete-orphan")


class Metrica(db.Model):
    __tablename__ = "metrica"
    __table_args__ = {"schema": SCHEMA}

    id            = Column(BigInteger, primary_key=True)
    evaluacion_id = Column(BigInteger, ForeignKey(f"{SCHEMA}.evaluacion.id", ondelete="CASCADE"), nullable=False)
    clase         = Column(Enum(ClaseDx, schema=SCHEMA, name="clase_dx"))
    nombre        = Column(Text, nullable=False)
    valor         = Column(Numeric(7, 5), nullable=False)
    ic_inf        = Column(Numeric(7, 5))
    ic_sup        = Column(Numeric(7, 5))

    evaluacion = relationship("Evaluacion", back_populates="metricas", foreign_keys=[evaluacion_id])
