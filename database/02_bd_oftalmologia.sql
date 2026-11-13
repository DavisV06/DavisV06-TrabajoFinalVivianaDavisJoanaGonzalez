--
-- PostgreSQL database dump
--

\restrict sW7UaFnDwBjuEodiUZzO0DSFDldgpqyWIRC4ZddEWvA6YHIAEoVstrKeV3Exp24

-- Dumped from database version 18.4
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oftalmologia; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA oftalmologia;


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: clase_dx; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.clase_dx AS ENUM (
    'normal',
    'rd',
    'glaucoma',
    'catarata'
);


--
-- Name: conjunto_eval; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.conjunto_eval AS ENUM (
    'test_interno',
    'test_externo',
    'validacion_pacientes'
);


--
-- Name: estado_consulta; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.estado_consulta AS ENUM (
    'agendada',
    'atendida',
    'cancelada',
    'referida'
);


--
-- Name: estado_dx; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.estado_dx AS ENUM (
    'pendiente',
    'confirmado',
    'rectificado'
);


--
-- Name: rol_app; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.rol_app AS ENUM (
    'paciente',
    'medico',
    'admin'
);


--
-- Name: tipo_asig; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.tipo_asig AS ENUM (
    'tratante',
    'interconsulta',
    'cobertura'
);


--
-- Name: tipo_notif; Type: TYPE; Schema: oftalmologia; Owner: -
--

CREATE TYPE oftalmologia.tipo_notif AS ENUM (
    'diagnostico_listo',
    'estudio_cargado',
    'asignacion_nueva',
    'sistema'
);


--
-- Name: fn_anonimizar_paciente(bigint); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_anonimizar_paciente(p_paciente bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'oftalmologia', 'public'
    AS $$
DECLARE
    v_nombre TEXT;
    v_nombres TEXT[];
    v_claves TEXT[] := ARRAY['nombre', 'email', 'telefono', 'password_hash', 'cedula', 'fecha_nac', 'sexo'];
BEGIN
    IF oftalmologia.fn_rol_actual() IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'Solo un administrador puede anonimizar pacientes' USING ERRCODE = '42501';
    END IF;

    SELECT u.nombre INTO v_nombre
    FROM usuario u JOIN paciente p ON p.usuario_id = u.id
    WHERE u.id = p_paciente AND NOT p.anonimizado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El paciente % no existe o ya fue anonimizado', p_paciente USING ERRCODE = 'P0002';
    END IF;

    -- Todos los nombres que tuvo el paciente: el actual y los anteriores registrados en la auditoría.
    SELECT array_agg(DISTINCT n ORDER BY n) INTO v_nombres FROM (
        SELECT v_nombre AS n
        UNION SELECT datos_antes->>'nombre'   FROM auditoria WHERE tabla = 'usuario' AND registro_id = p_paciente
        UNION SELECT datos_despues->>'nombre' FROM auditoria WHERE tabla = 'usuario' AND registro_id = p_paciente
    ) t WHERE n IS NOT NULL AND length(n) > 2;

    UPDATE usuario
       SET nombre        = 'Paciente anonimizado ' || p_paciente,
           email         = 'anonimizado-' || p_paciente || '@anonimizado.invalid',
           telefono      = NULL,
           activo        = FALSE,
           password_hash = '!anonimizado:' || md5(random()::text || clock_timestamp()::text)
     WHERE id = p_paciente;

    UPDATE paciente
       SET cedula = NULL, fecha_nac = NULL, sexo = NULL,
           anonimizado = TRUE, anonimizado_en = now()
     WHERE usuario_id = p_paciente;

    -- Los avisos de otros usuarios (por ejemplo, del médico) mencionan el nombre del paciente,
    -- incluso con nombres anteriores a una rectificación.
    FOR i IN 1 .. coalesce(array_length(v_nombres, 1), 0) LOOP
        UPDATE notificacion
           SET mensaje = replace(mensaje, v_nombres[i], 'Paciente anonimizado')
         WHERE position(v_nombres[i] IN mensaje) > 0;
    END LOOP;

    -- Las copias de auditoría conservan la operación, la fecha y el autor, pero no los datos
    -- identificativos. Se ejecuta al final para alcanzar también los registros generados arriba.
    UPDATE auditoria
       SET datos_antes   = CASE WHEN datos_antes   IS NULL THEN NULL ELSE (datos_antes   - v_claves) || '{"anonimizado": true}' END,
           datos_despues = CASE WHEN datos_despues IS NULL THEN NULL ELSE (datos_despues - v_claves) || '{"anonimizado": true}' END
     WHERE (tabla = 'usuario' AND registro_id = p_paciente)
        OR (tabla = 'paciente' AND (datos_antes->>'usuario_id' = p_paciente::text
                                 OR datos_despues->>'usuario_id' = p_paciente::text));
END $$;


--
-- Name: fn_auditar(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_auditar() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'oftalmologia', 'public'
    AS $$
DECLARE
    v_usuario BIGINT;
    v_ip      INET;
BEGIN
    v_usuario := NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT;
    v_ip      := NULLIF(current_setting('app.ip', TRUE), '')::INET;

    INSERT INTO oftalmologia.auditoria
        (tabla, registro_id, operacion, usuario_id, datos_antes, datos_despues, ip)
    VALUES (
        TG_TABLE_NAME,
        CASE WHEN TG_OP = 'DELETE' THEN (to_jsonb(OLD)->>'id')::BIGINT
             ELSE (to_jsonb(NEW)->>'id')::BIGINT END,
        LEFT(TG_OP, 1),
        v_usuario,
        CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
        v_ip
    );

    RETURN COALESCE(NEW, OLD);
END $$;


--
-- Name: fn_diag_versionar(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_diag_versionar() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.version IS NULL OR NEW.version = 0 THEN
        SELECT COALESCE(MAX(version), 0) + 1
          INTO NEW.version
          FROM oftalmologia.diagnostico
         WHERE estudio_id = NEW.estudio_id;
    END IF;

    UPDATE oftalmologia.diagnostico
       SET vigente = FALSE
     WHERE estudio_id = NEW.estudio_id
       AND vigente;

    NEW.vigente := TRUE;

    IF NEW.version > 1 THEN
        NEW.estado := 'rectificado';
    END IF;

    RETURN NEW;
END $$;


--
-- Name: fn_rol_actual(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_rol_actual() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE(NULLIF(current_setting('app.rol', TRUE), ''), 'anonimo');
$$;


--
-- Name: fn_usuario_actual(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_usuario_actual() RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT;
$$;


--
-- Name: fn_verificar_rol(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_verificar_rol() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_rol oftalmologia.rol_app;
BEGIN
    SELECT rol INTO v_rol FROM oftalmologia.usuario WHERE id = NEW.usuario_id;

    IF v_rol IS DISTINCT FROM TG_ARGV[0]::oftalmologia.rol_app THEN
        RAISE EXCEPTION
            'El usuario % tiene rol "%" y no puede registrarse como "%"',
            NEW.usuario_id, v_rol, TG_ARGV[0];
    END IF;

    RETURN NEW;
END $$;


--
-- Name: fn_verificar_suma_prob(); Type: FUNCTION; Schema: oftalmologia; Owner: -
--

CREATE FUNCTION oftalmologia.fn_verificar_suma_prob() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT prediccion_id, SUM(valor) AS s, COUNT(*) AS n
          FROM oftalmologia.prediccion_probabilidad
         GROUP BY prediccion_id
        HAVING COUNT(*) <> 4 OR ABS(SUM(valor) - 1) > 0.01
    LOOP
        RAISE EXCEPTION
            'Prediccion %: se esperaban 4 clases sumando 1.0, se hallaron % sumando %',
            r.prediccion_id, r.n, r.s;
    END LOOP;

    RETURN NULL;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: asignacion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.asignacion (
    id bigint NOT NULL,
    medico_id bigint NOT NULL,
    paciente_id bigint NOT NULL,
    tipo oftalmologia.tipo_asig DEFAULT 'tratante'::oftalmologia.tipo_asig NOT NULL,
    desde date DEFAULT CURRENT_DATE NOT NULL,
    hasta date,
    CONSTRAINT ck_asig_rango CHECK (((hasta IS NULL) OR (hasta >= desde)))
);


--
-- Name: TABLE asignacion; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON TABLE oftalmologia.asignacion IS 'Vigencia: hasta IS NULL OR hasta >= CURRENT_DATE. Ver vista v_asignacion_vigente';


--
-- Name: asignacion_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.asignacion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asignacion_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.asignacion_id_seq OWNED BY oftalmologia.asignacion.id;


--
-- Name: auditoria; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.auditoria (
    id bigint NOT NULL,
    tabla text NOT NULL,
    registro_id bigint,
    operacion character(1) NOT NULL,
    usuario_id bigint,
    datos_antes jsonb,
    datos_despues jsonb,
    ip inet,
    ocurrido_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_aud_op CHECK ((operacion = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: TABLE auditoria; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON TABLE oftalmologia.auditoria IS 'Solo anexado. UPDATE y DELETE revocados incluso para app_admin: una bitacora editable no es una bitacora';


--
-- Name: auditoria_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.auditoria_id_seq OWNED BY oftalmologia.auditoria.id;


--
-- Name: celda_confusion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.celda_confusion (
    evaluacion_id bigint NOT NULL,
    clase_real oftalmologia.clase_dx NOT NULL,
    clase_predicha oftalmologia.clase_dx NOT NULL,
    conteo integer NOT NULL,
    CONSTRAINT ck_celda_conteo CHECK ((conteo >= 0))
);


--
-- Name: conjunto_prueba; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.conjunto_prueba (
    id integer NOT NULL,
    nombre text NOT NULL,
    tipo oftalmologia.conjunto_eval NOT NULL,
    fuente text,
    licencia text,
    preproc text,
    n_imagenes integer,
    notas text,
    CONSTRAINT ck_conj_n CHECK (((n_imagenes IS NULL) OR (n_imagenes > 0)))
);


--
-- Name: COLUMN conjunto_prueba.preproc; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.conjunto_prueba.preproc IS 'Documenta si las imagenes llegan ya procesadas por terceros. Critico para interpretar la caida de rendimiento en validacion externa';


--
-- Name: conjunto_prueba_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.conjunto_prueba_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conjunto_prueba_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.conjunto_prueba_id_seq OWNED BY oftalmologia.conjunto_prueba.id;


--
-- Name: consulta; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.consulta (
    id bigint NOT NULL,
    paciente_id bigint NOT NULL,
    medico_id bigint NOT NULL,
    fecha timestamp with time zone DEFAULT now() NOT NULL,
    motivo text,
    notas text,
    estado oftalmologia.estado_consulta DEFAULT 'agendada'::oftalmologia.estado_consulta NOT NULL,
    referida_a bigint,
    notas_cancel text,
    modificada_en timestamp with time zone,
    consulta_padre_id bigint,
    plan_tratamiento text,
    notas_medico text,
    solicitar_retinografia boolean DEFAULT true NOT NULL
);


--
-- Name: COLUMN consulta.medico_id; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.consulta.medico_id IS 'Hecho historico: quien atendio esta consulta, independiente de las asignaciones vigentes hoy';


--
-- Name: consulta_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.consulta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consulta_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.consulta_id_seq OWNED BY oftalmologia.consulta.id;


--
-- Name: diagnostico; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.diagnostico (
    id bigint NOT NULL,
    estudio_id bigint NOT NULL,
    version integer NOT NULL,
    clase oftalmologia.clase_dx NOT NULL,
    estado oftalmologia.estado_dx DEFAULT 'confirmado'::oftalmologia.estado_dx NOT NULL,
    observaciones text,
    motivo_cambio text,
    medico_id bigint NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    vigente boolean DEFAULT true NOT NULL,
    CONSTRAINT ck_diag_motivo CHECK (((version = 1) OR (motivo_cambio IS NOT NULL))),
    CONSTRAINT ck_diag_version CHECK ((version >= 1))
);


--
-- Name: diagnostico_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.diagnostico_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: diagnostico_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.diagnostico_id_seq OWNED BY oftalmologia.diagnostico.id;


--
-- Name: estudio; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.estudio (
    id bigint NOT NULL,
    consulta_id bigint NOT NULL,
    imagen_id bigint NOT NULL,
    ojo character(1) NOT NULL,
    tomado_en timestamp with time zone DEFAULT now() NOT NULL,
    subido_por bigint NOT NULL,
    CONSTRAINT ck_estudio_ojo CHECK ((ojo = ANY (ARRAY['L'::bpchar, 'R'::bpchar])))
);


--
-- Name: estudio_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.estudio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: estudio_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.estudio_id_seq OWNED BY oftalmologia.estudio.id;


--
-- Name: evaluacion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.evaluacion (
    id bigint NOT NULL,
    modelo_id integer NOT NULL,
    conjunto_id integer NOT NULL,
    corrida_en timestamp with time zone DEFAULT now() NOT NULL,
    notas text
);


--
-- Name: evaluacion_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.evaluacion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: evaluacion_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.evaluacion_id_seq OWNED BY oftalmologia.evaluacion.id;


--
-- Name: imagen; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.imagen (
    id bigint NOT NULL,
    ruta text NOT NULL,
    sha256 character(64) NOT NULL,
    ancho integer,
    alto integer,
    formato text,
    bytes bigint,
    cargada_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_imagen_dims CHECK ((((ancho IS NULL) OR (ancho > 0)) AND ((alto IS NULL) OR (alto > 0)))),
    CONSTRAINT ck_imagen_sha CHECK ((sha256 ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: imagen_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.imagen_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: imagen_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.imagen_id_seq OWNED BY oftalmologia.imagen.id;


--
-- Name: medico; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.medico (
    usuario_id bigint NOT NULL,
    num_idoneidad text NOT NULL,
    especialidad text,
    vigente_hasta date
);


--
-- Name: metrica; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.metrica (
    id bigint NOT NULL,
    evaluacion_id bigint NOT NULL,
    clase oftalmologia.clase_dx,
    nombre text NOT NULL,
    valor numeric(7,5) NOT NULL,
    ic_inf numeric(7,5),
    ic_sup numeric(7,5),
    CONSTRAINT ck_metrica_ic CHECK (((ic_inf IS NULL) OR (ic_sup IS NULL) OR (ic_inf <= ic_sup)))
);


--
-- Name: COLUMN metrica.clase; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.metrica.clase IS 'NULL indica metrica global (macro-promedio) del conjunto';


--
-- Name: COLUMN metrica.nombre; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.metrica.nombre IS 'auc_roc | auc_pr | sensibilidad | especificidad | f1 | kappa | exactitud';


--
-- Name: metrica_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.metrica_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: metrica_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.metrica_id_seq OWNED BY oftalmologia.metrica.id;


--
-- Name: modelo; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.modelo (
    id integer NOT NULL,
    nombre text NOT NULL,
    version text NOT NULL,
    arquitectura text,
    hash_pesos character(64),
    entrenado_en date,
    activo boolean DEFAULT false NOT NULL,
    registrado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_modelo_hash CHECK (((hash_pesos IS NULL) OR (hash_pesos ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: modelo_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.modelo_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: modelo_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.modelo_id_seq OWNED BY oftalmologia.modelo.id;


--
-- Name: notificacion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.notificacion (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    diagnostico_id bigint,
    tipo oftalmologia.tipo_notif NOT NULL,
    mensaje text NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    leida_en timestamp with time zone
);


--
-- Name: notificacion_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.notificacion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notificacion_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.notificacion_id_seq OWNED BY oftalmologia.notificacion.id;


--
-- Name: paciente; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.paciente (
    usuario_id bigint NOT NULL,
    cedula text,
    fecha_nac date,
    sexo character(1),
    anonimizado boolean DEFAULT false NOT NULL,
    cancelacion_solicitada_en timestamp with time zone,
    anonimizado_en timestamp with time zone,
    CONSTRAINT ck_paciente_fnac CHECK (((fecha_nac IS NULL) OR (fecha_nac <= CURRENT_DATE))),
    CONSTRAINT ck_paciente_sexo CHECK (((sexo IS NULL) OR (sexo = ANY (ARRAY['M'::bpchar, 'F'::bpchar, 'O'::bpchar]))))
);


--
-- Name: COLUMN paciente.anonimizado; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.paciente.anonimizado IS 'Ley 81 de 2019 (Panama), derecho de supresion: se disocian los datos identificatorios y se conserva el estudio clinico. Ver seccion 11.';


--
-- Name: prediccion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.prediccion (
    id bigint NOT NULL,
    estudio_id bigint NOT NULL,
    modelo_id integer NOT NULL,
    clase oftalmologia.clase_dx NOT NULL,
    confianza numeric(5,4),
    ms_computo integer,
    generado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_pred_confianza CHECK (((confianza IS NULL) OR ((confianza >= (0)::numeric) AND (confianza <= (1)::numeric))))
);


--
-- Name: TABLE prediccion; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON TABLE oftalmologia.prediccion IS 'Sugerencia automatica. NO constituye diagnostico: ver tabla diagnostico';


--
-- Name: prediccion_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.prediccion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: prediccion_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.prediccion_id_seq OWNED BY oftalmologia.prediccion.id;


--
-- Name: prediccion_probabilidad; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.prediccion_probabilidad (
    prediccion_id bigint NOT NULL,
    clase oftalmologia.clase_dx NOT NULL,
    valor numeric(6,5) NOT NULL,
    CONSTRAINT ck_prob_rango CHECK (((valor >= (0)::numeric) AND (valor <= (1)::numeric)))
);


--
-- Name: TABLE prediccion_probabilidad; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON TABLE oftalmologia.prediccion_probabilidad IS 'Las 4 filas de una prediccion deben sumar 1.0 (+-0.01). Validado por trigger tr_prob_suma en la seccion 8';


--
-- Name: sesion; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.sesion (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    token_hash character(64) NOT NULL,
    ip inet,
    user_agent text,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    expira_en timestamp with time zone NOT NULL,
    revocada_en timestamp with time zone,
    CONSTRAINT ck_sesion_exp CHECK ((expira_en > creada_en))
);


--
-- Name: COLUMN sesion.revocada_en; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.sesion.revocada_en IS 'NULL = sesion viva. Cerrar sesion escribe la fecha, no borra la fila';


--
-- Name: sesion_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.sesion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sesion_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.sesion_id_seq OWNED BY oftalmologia.sesion.id;


--
-- Name: usuario; Type: TABLE; Schema: oftalmologia; Owner: -
--

CREATE TABLE oftalmologia.usuario (
    id bigint NOT NULL,
    email public.citext NOT NULL,
    password_hash text NOT NULL,
    rol oftalmologia.rol_app NOT NULL,
    nombre text NOT NULL,
    telefono text,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    consentimiento_en timestamp with time zone,
    consentimiento_version text,
    CONSTRAINT ck_usuario_email CHECK ((email OPERATOR(public.~) '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'::public.citext)),
    CONSTRAINT ck_usuario_hash CHECK ((length(password_hash) >= 20))
);


--
-- Name: TABLE usuario; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON TABLE oftalmologia.usuario IS 'Identidad y credenciales de todos los actores del sistema';


--
-- Name: COLUMN usuario.password_hash; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.usuario.password_hash IS 'Hash bcrypt/argon2. NUNCA almacenar la contrasena en claro';


--
-- Name: COLUMN usuario.activo; Type: COMMENT; Schema: oftalmologia; Owner: -
--

COMMENT ON COLUMN oftalmologia.usuario.activo IS 'Baja logica. No se eliminan usuarios para preservar trazabilidad';


--
-- Name: usuario_id_seq; Type: SEQUENCE; Schema: oftalmologia; Owner: -
--

CREATE SEQUENCE oftalmologia.usuario_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usuario_id_seq; Type: SEQUENCE OWNED BY; Schema: oftalmologia; Owner: -
--

ALTER SEQUENCE oftalmologia.usuario_id_seq OWNED BY oftalmologia.usuario.id;


--
-- Name: v_asignacion_vigente; Type: VIEW; Schema: oftalmologia; Owner: -
--

CREATE VIEW oftalmologia.v_asignacion_vigente AS
 SELECT id,
    medico_id,
    paciente_id,
    tipo,
    desde,
    hasta
   FROM oftalmologia.asignacion a
  WHERE ((hasta IS NULL) OR (hasta >= CURRENT_DATE));


--
-- Name: v_expediente; Type: VIEW; Schema: oftalmologia; Owner: -
--

CREATE VIEW oftalmologia.v_expediente AS
 SELECT e.id AS estudio_id,
    c.paciente_id,
    u.nombre AS paciente,
    c.fecha AS fecha_consulta,
    e.ojo,
    p.clase AS clase_modelo,
    p.confianza,
    d.clase AS clase_medico,
    d.version AS version_diag,
    d.estado,
    d.medico_id,
    (p.clase = d.clase) AS concuerda
   FROM (((((oftalmologia.estudio e
     JOIN oftalmologia.consulta c ON ((c.id = e.consulta_id)))
     JOIN oftalmologia.paciente pa ON ((pa.usuario_id = c.paciente_id)))
     JOIN oftalmologia.usuario u ON ((u.id = pa.usuario_id)))
     LEFT JOIN oftalmologia.prediccion p ON ((p.estudio_id = e.id)))
     LEFT JOIN oftalmologia.diagnostico d ON (((d.estudio_id = e.id) AND d.vigente)));


--
-- Name: v_matriz_confusion; Type: VIEW; Schema: oftalmologia; Owner: -
--

CREATE VIEW oftalmologia.v_matriz_confusion AS
 SELECT ev.id AS evaluacion_id,
    ((m.nombre || ' '::text) || m.version) AS modelo,
    cp.nombre AS conjunto,
    cc.clase_real,
    sum(cc.conteo) FILTER (WHERE (cc.clase_predicha = 'normal'::oftalmologia.clase_dx)) AS pred_normal,
    sum(cc.conteo) FILTER (WHERE (cc.clase_predicha = 'rd'::oftalmologia.clase_dx)) AS pred_rd,
    sum(cc.conteo) FILTER (WHERE (cc.clase_predicha = 'glaucoma'::oftalmologia.clase_dx)) AS pred_glaucoma,
    sum(cc.conteo) FILTER (WHERE (cc.clase_predicha = 'catarata'::oftalmologia.clase_dx)) AS pred_catarata,
    sum(cc.conteo) AS total_real
   FROM (((oftalmologia.celda_confusion cc
     JOIN oftalmologia.evaluacion ev ON ((ev.id = cc.evaluacion_id)))
     JOIN oftalmologia.modelo m ON ((m.id = ev.modelo_id)))
     JOIN oftalmologia.conjunto_prueba cp ON ((cp.id = ev.conjunto_id)))
  GROUP BY ev.id, m.nombre, m.version, cp.nombre, cc.clase_real;


--
-- Name: v_trazabilidad_diagnostico; Type: VIEW; Schema: oftalmologia; Owner: -
--

CREATE VIEW oftalmologia.v_trazabilidad_diagnostico AS
 SELECT a.ocurrido_en,
    a.operacion,
    a.usuario_id,
    u.nombre AS modifico,
    ((a.datos_despues ->> 'estudio_id'::text))::bigint AS estudio_id,
    (a.datos_antes ->> 'clase'::text) AS clase_antes,
    (a.datos_despues ->> 'clase'::text) AS clase_despues,
    (a.datos_despues ->> 'motivo_cambio'::text) AS motivo
   FROM (oftalmologia.auditoria a
     LEFT JOIN oftalmologia.usuario u ON ((u.id = a.usuario_id)))
  WHERE (a.tabla = 'diagnostico'::text)
  ORDER BY a.ocurrido_en DESC;


--
-- Name: asignacion id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.asignacion ALTER COLUMN id SET DEFAULT nextval('oftalmologia.asignacion_id_seq'::regclass);


--
-- Name: auditoria id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.auditoria ALTER COLUMN id SET DEFAULT nextval('oftalmologia.auditoria_id_seq'::regclass);


--
-- Name: conjunto_prueba id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.conjunto_prueba ALTER COLUMN id SET DEFAULT nextval('oftalmologia.conjunto_prueba_id_seq'::regclass);


--
-- Name: consulta id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta ALTER COLUMN id SET DEFAULT nextval('oftalmologia.consulta_id_seq'::regclass);


--
-- Name: diagnostico id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.diagnostico ALTER COLUMN id SET DEFAULT nextval('oftalmologia.diagnostico_id_seq'::regclass);


--
-- Name: estudio id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio ALTER COLUMN id SET DEFAULT nextval('oftalmologia.estudio_id_seq'::regclass);


--
-- Name: evaluacion id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.evaluacion ALTER COLUMN id SET DEFAULT nextval('oftalmologia.evaluacion_id_seq'::regclass);


--
-- Name: imagen id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.imagen ALTER COLUMN id SET DEFAULT nextval('oftalmologia.imagen_id_seq'::regclass);


--
-- Name: metrica id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.metrica ALTER COLUMN id SET DEFAULT nextval('oftalmologia.metrica_id_seq'::regclass);


--
-- Name: modelo id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.modelo ALTER COLUMN id SET DEFAULT nextval('oftalmologia.modelo_id_seq'::regclass);


--
-- Name: notificacion id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.notificacion ALTER COLUMN id SET DEFAULT nextval('oftalmologia.notificacion_id_seq'::regclass);


--
-- Name: prediccion id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion ALTER COLUMN id SET DEFAULT nextval('oftalmologia.prediccion_id_seq'::regclass);


--
-- Name: sesion id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.sesion ALTER COLUMN id SET DEFAULT nextval('oftalmologia.sesion_id_seq'::regclass);


--
-- Name: usuario id; Type: DEFAULT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.usuario ALTER COLUMN id SET DEFAULT nextval('oftalmologia.usuario_id_seq'::regclass);


--
-- Data for Name: asignacion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.asignacion (id, medico_id, paciente_id, tipo, desde, hasta) FROM stdin;
1	3	8	tratante	2025-05-06	\N
2	5	9	tratante	2026-07-26	\N
3	3	9	interconsulta	2026-07-12	\N
4	4	10	tratante	2025-09-21	\N
5	3	10	interconsulta	2026-04-11	\N
6	4	11	tratante	2025-05-06	\N
7	4	12	tratante	2026-03-18	\N
8	5	12	cobertura	2026-01-12	\N
9	4	13	tratante	2026-05-01	2026-06-05
10	4	14	tratante	2025-10-27	\N
11	3	15	tratante	2026-04-29	2026-06-06
12	3	16	tratante	2026-04-25	\N
13	5	16	cobertura	2026-05-07	\N
14	6	17	tratante	2025-07-19	\N
15	3	17	cobertura	2026-05-19	\N
16	6	18	tratante	2025-12-28	\N
17	3	19	tratante	2026-07-24	\N
18	3	20	tratante	2026-04-19	\N
19	4	21	tratante	2026-01-20	\N
20	3	22	tratante	2026-01-10	\N
21	3	23	tratante	2025-09-25	\N
22	6	23	interconsulta	2025-04-15	2025-07-14
23	6	24	tratante	2025-12-21	\N
24	3	25	tratante	2026-06-01	\N
25	5	26	tratante	2026-03-31	\N
26	4	26	cobertura	2026-06-06	\N
27	3	27	tratante	2025-11-01	\N
28	3	2	tratante	2026-09-23	\N
29	5	2	tratante	2026-10-01	\N
\.


--
-- Data for Name: auditoria; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.auditoria (id, tabla, registro_id, operacion, usuario_id, datos_antes, datos_despues, ip, ocurrido_en) FROM stdin;
122	estudio	5	I	3	\N	{"id": 5, "ojo": "R", "imagen_id": 5, "tomado_en": "2026-01-13T08:30:00-05:00", "subido_por": 8, "consulta_id": 6}	\N	2026-11-03 20:41:56.48039-05
457	estudio	41	I	2	\N	{"id": 41, "ojo": "L", "imagen_id": 42, "tomado_en": "2026-11-11T18:18:08.897586-05:00", "subido_por": 2, "consulta_id": 55}	127.0.0.1	2026-11-11 18:18:05.049066-05
458	usuario	1	U	1	{"id": 1, "rol": "admin", "email": "admin@sistema.local", "activo": true, "nombre": "Administrador del sistema", "telefono": null, "creado_en": "2026-08-12T00:38:11.509963-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": null, "consentimiento_version": null}	{"id": 1, "rol": "admin", "email": "admin@sistema.local", "activo": true, "nombre": "Administrador del sistema", "telefono": null, "creado_en": "2026-08-12T00:38:11.509963-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": "2026-11-11T20:42:09.202432-05:00", "consentimiento_version": "1.0 (noviembre de 2026)"}	127.0.0.1	2026-11-11 20:42:09.199551-05
118	diagnostico	5	I	3	\N	{"id": 5, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2025-12-19T15:45:00-05:00", "medico_id": 3, "estudio_id": 3, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
119	estudio	4	I	3	\N	{"id": 4, "ojo": "L", "imagen_id": 4, "tomado_en": "2025-12-19T14:45:00-05:00", "subido_por": 2, "consulta_id": 5}	\N	2026-11-03 20:41:56.48039-05
120	diagnostico	6	I	3	\N	{"id": 6, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2025-12-19T15:45:00-05:00", "medico_id": 3, "estudio_id": 4, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
3	paciente	\N	I	\N	\N	{"sexo": null, "cedula": "3-700-1001", "fecha_nac": "2002-10-06", "usuario_id": 2, "anonimizado": false}	\N	2026-09-16 00:05:16.674939-05
10	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "3-350-4657", "fecha_nac": "1996-03-22", "usuario_id": 8, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
12	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "4-132-1488", "fecha_nac": "2000-05-02", "usuario_id": 9, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
14	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "2-833-9928", "fecha_nac": "1971-02-08", "usuario_id": 10, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
16	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "2-814-7924", "fecha_nac": "1978-03-20", "usuario_id": 11, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
18	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "1-194-7224", "fecha_nac": "2000-01-24", "usuario_id": 12, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
20	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "4-649-3045", "fecha_nac": "1974-10-13", "usuario_id": 13, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
22	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "2-821-2139", "fecha_nac": "2004-08-18", "usuario_id": 14, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
24	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "2-987-2654", "fecha_nac": "1974-08-22", "usuario_id": 15, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
26	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "3-463-4432", "fecha_nac": "1948-08-13", "usuario_id": 16, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
28	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "2-267-8573", "fecha_nac": "1974-09-13", "usuario_id": 17, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
30	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "2-941-1525", "fecha_nac": "1980-06-10", "usuario_id": 18, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
32	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "8-997-6155", "fecha_nac": "1989-08-31", "usuario_id": 19, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
34	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "4-246-5339", "fecha_nac": "1996-03-19", "usuario_id": 20, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
36	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "4-697-7543", "fecha_nac": "1976-04-07", "usuario_id": 21, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
38	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "1-981-2796", "fecha_nac": "1995-01-11", "usuario_id": 22, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
40	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "1-494-7252", "fecha_nac": "1955-04-13", "usuario_id": 23, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
42	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "1-796-2876", "fecha_nac": "1947-08-01", "usuario_id": 24, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
44	paciente	\N	I	\N	\N	{"sexo": "F", "cedula": "3-545-3591", "fecha_nac": "1968-01-14", "usuario_id": 25, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
46	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "1-991-5889", "fecha_nac": "1951-06-02", "usuario_id": 26, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
48	paciente	\N	I	\N	\N	{"sexo": "M", "cedula": "2-652-9689", "fecha_nac": "2008-09-09", "usuario_id": 27, "anonimizado": false}	\N	2026-09-23 09:24:11.39284-05
49	asignacion	1	I	\N	\N	{"id": 1, "tipo": "tratante", "desde": "2025-05-06", "hasta": null, "medico_id": 3, "paciente_id": 8}	\N	2026-09-23 09:24:11.450974-05
50	asignacion	2	I	\N	\N	{"id": 2, "tipo": "tratante", "desde": "2026-07-26", "hasta": null, "medico_id": 5, "paciente_id": 9}	\N	2026-09-23 09:24:11.450974-05
51	asignacion	3	I	\N	\N	{"id": 3, "tipo": "interconsulta", "desde": "2026-07-12", "hasta": null, "medico_id": 3, "paciente_id": 9}	\N	2026-09-23 09:24:11.450974-05
52	asignacion	4	I	\N	\N	{"id": 4, "tipo": "tratante", "desde": "2025-09-21", "hasta": null, "medico_id": 4, "paciente_id": 10}	\N	2026-09-23 09:24:11.450974-05
53	asignacion	5	I	\N	\N	{"id": 5, "tipo": "interconsulta", "desde": "2026-04-11", "hasta": null, "medico_id": 3, "paciente_id": 10}	\N	2026-09-23 09:24:11.450974-05
54	asignacion	6	I	\N	\N	{"id": 6, "tipo": "tratante", "desde": "2025-05-06", "hasta": null, "medico_id": 4, "paciente_id": 11}	\N	2026-09-23 09:24:11.450974-05
55	asignacion	7	I	\N	\N	{"id": 7, "tipo": "tratante", "desde": "2026-03-18", "hasta": null, "medico_id": 4, "paciente_id": 12}	\N	2026-09-23 09:24:11.450974-05
56	asignacion	8	I	\N	\N	{"id": 8, "tipo": "cobertura", "desde": "2026-01-12", "hasta": null, "medico_id": 5, "paciente_id": 12}	\N	2026-09-23 09:24:11.450974-05
57	asignacion	9	I	\N	\N	{"id": 9, "tipo": "tratante", "desde": "2026-05-01", "hasta": "2026-06-05", "medico_id": 4, "paciente_id": 13}	\N	2026-09-23 09:24:11.450974-05
58	asignacion	10	I	\N	\N	{"id": 10, "tipo": "tratante", "desde": "2025-10-27", "hasta": null, "medico_id": 4, "paciente_id": 14}	\N	2026-09-23 09:24:11.450974-05
59	asignacion	11	I	\N	\N	{"id": 11, "tipo": "tratante", "desde": "2026-04-29", "hasta": "2026-06-06", "medico_id": 3, "paciente_id": 15}	\N	2026-09-23 09:24:11.450974-05
60	asignacion	12	I	\N	\N	{"id": 12, "tipo": "tratante", "desde": "2026-04-25", "hasta": null, "medico_id": 3, "paciente_id": 16}	\N	2026-09-23 09:24:11.450974-05
61	asignacion	13	I	\N	\N	{"id": 13, "tipo": "cobertura", "desde": "2026-05-07", "hasta": null, "medico_id": 5, "paciente_id": 16}	\N	2026-09-23 09:24:11.450974-05
62	asignacion	14	I	\N	\N	{"id": 14, "tipo": "tratante", "desde": "2025-07-19", "hasta": null, "medico_id": 6, "paciente_id": 17}	\N	2026-09-23 09:24:11.450974-05
63	asignacion	15	I	\N	\N	{"id": 15, "tipo": "cobertura", "desde": "2026-05-19", "hasta": null, "medico_id": 3, "paciente_id": 17}	\N	2026-09-23 09:24:11.450974-05
64	asignacion	16	I	\N	\N	{"id": 16, "tipo": "tratante", "desde": "2025-12-28", "hasta": null, "medico_id": 6, "paciente_id": 18}	\N	2026-09-23 09:24:11.450974-05
65	asignacion	17	I	\N	\N	{"id": 17, "tipo": "tratante", "desde": "2026-07-24", "hasta": null, "medico_id": 3, "paciente_id": 19}	\N	2026-09-23 09:24:11.450974-05
66	asignacion	18	I	\N	\N	{"id": 18, "tipo": "tratante", "desde": "2026-04-19", "hasta": null, "medico_id": 3, "paciente_id": 20}	\N	2026-09-23 09:24:11.450974-05
67	asignacion	19	I	\N	\N	{"id": 19, "tipo": "tratante", "desde": "2026-01-20", "hasta": null, "medico_id": 4, "paciente_id": 21}	\N	2026-09-23 09:24:11.450974-05
68	asignacion	20	I	\N	\N	{"id": 20, "tipo": "tratante", "desde": "2026-01-10", "hasta": null, "medico_id": 3, "paciente_id": 22}	\N	2026-09-23 09:24:11.450974-05
69	asignacion	21	I	\N	\N	{"id": 21, "tipo": "tratante", "desde": "2025-09-25", "hasta": null, "medico_id": 3, "paciente_id": 23}	\N	2026-09-23 09:24:11.450974-05
70	asignacion	22	I	\N	\N	{"id": 22, "tipo": "interconsulta", "desde": "2025-04-15", "hasta": "2025-07-14", "medico_id": 6, "paciente_id": 23}	\N	2026-09-23 09:24:11.450974-05
71	asignacion	23	I	\N	\N	{"id": 23, "tipo": "tratante", "desde": "2025-12-21", "hasta": null, "medico_id": 6, "paciente_id": 24}	\N	2026-09-23 09:24:11.450974-05
72	asignacion	24	I	\N	\N	{"id": 24, "tipo": "tratante", "desde": "2026-06-01", "hasta": null, "medico_id": 3, "paciente_id": 25}	\N	2026-09-23 09:24:11.450974-05
73	asignacion	25	I	\N	\N	{"id": 25, "tipo": "tratante", "desde": "2026-03-31", "hasta": null, "medico_id": 5, "paciente_id": 26}	\N	2026-09-23 09:24:11.450974-05
74	asignacion	26	I	\N	\N	{"id": 26, "tipo": "cobertura", "desde": "2026-06-06", "hasta": null, "medico_id": 4, "paciente_id": 26}	\N	2026-09-23 09:24:11.450974-05
75	asignacion	27	I	\N	\N	{"id": 27, "tipo": "tratante", "desde": "2025-11-01", "hasta": null, "medico_id": 3, "paciente_id": 27}	\N	2026-09-23 09:24:11.450974-05
316	diagnostico	35	I	3	\N	{"id": 35, "clase": "normal", "estado": "rectificado", "version": 1, "vigente": true, "creado_en": "2026-11-03T22:43:54.873228-05:00", "medico_id": 3, "estudio_id": 36, "motivo_cambio": "error", "observaciones": null}	127.0.0.1	2026-11-03 22:43:54.845465-05
83	consulta	1	I	2	\N	{"id": 1, "fecha": "2026-09-25T11:00:00-05:00", "notas": null, "motivo": "Molestias en el ojo", "medico_id": 3, "paciente_id": 2}	127.0.0.1	2026-09-23 09:42:56.765626-05
84	asignacion	28	I	2	\N	{"id": 28, "tipo": "tratante", "desde": "2026-09-23", "hasta": null, "medico_id": 3, "paciente_id": 2}	127.0.0.1	2026-09-23 09:42:56.765626-05
85	estudio	1	I	2	\N	{"id": 1, "ojo": "R", "imagen_id": 1, "tomado_en": "2026-09-23T09:46:24.080213-05:00", "subido_por": 2, "consulta_id": 1}	127.0.0.1	2026-09-23 09:46:24.008278-05
86	estudio	2	I	2	\N	{"id": 2, "ojo": "L", "imagen_id": 2, "tomado_en": "2026-09-23T09:46:28.093283-05:00", "subido_por": 2, "consulta_id": 1}	127.0.0.1	2026-09-23 09:46:24.008278-05
87	diagnostico	1	I	3	\N	{"id": 1, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-09-23T11:31:54.445091-05:00", "medico_id": 3, "estudio_id": 2, "motivo_cambio": null, "observaciones": "Glaucoma inicial"}	127.0.0.1	2026-09-23 11:31:54.438444-05
88	diagnostico	2	I	3	\N	{"id": 2, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-09-23T11:32:19.330495-05:00", "medico_id": 3, "estudio_id": 1, "motivo_cambio": null, "observaciones": "Ojo normal, sin enfermedades presentes"}	127.0.0.1	2026-09-23 11:32:19.326375-05
137	diagnostico	12	I	3	\N	{"id": 12, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-03-10T14:15:00-05:00", "medico_id": 3, "estudio_id": 10, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
97	consulta	2	I	3	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "modificada_en": null}	127.0.0.1	2026-09-28 12:59:40.347432-05
101	consulta	3	I	3	\N	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 2}	127.0.0.1	2026-10-01 14:13:35.472508-05
159	estudio	18	I	3	\N	{"id": 18, "ojo": "R", "imagen_id": 18, "tomado_en": "2026-06-15T09:45:00-05:00", "subido_por": 2, "consulta_id": 17}	\N	2026-11-03 20:41:56.48039-05
108	consulta	4	I	2	\N	{"id": 4, "fecha": "2026-10-02T03:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Ojo lloroso", "medico_id": 5, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	127.0.0.1	2026-10-01 17:17:26.893807-05
109	asignacion	29	I	2	\N	{"id": 29, "tipo": "tratante", "desde": "2026-10-01", "hasta": null, "medico_id": 5, "paciente_id": 2}	127.0.0.1	2026-10-01 17:17:26.893807-05
419	consulta	41	I	3	\N	{"id": 41, "fecha": "2026-11-04T08:30:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control de presión ocular", "medico_id": 3, "referida_a": null, "paciente_id": 16, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-04 21:03:18.229225-05
420	consulta	42	I	3	\N	{"id": 42, "fecha": "2026-11-04T09:30:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control por diabetes", "medico_id": 3, "referida_a": null, "paciente_id": 19, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-04 21:03:18.229225-05
421	consulta	43	I	3	\N	{"id": 43, "fecha": "2026-11-04T10:30:00-05:00", "notas": null, "estado": "agendada", "motivo": "Visión borrosa", "medico_id": 3, "referida_a": null, "paciente_id": 22, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-04 21:03:18.229225-05
422	consulta	44	I	3	\N	{"id": 44, "fecha": "2026-11-04T13:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Revisión preventiva", "medico_id": 3, "referida_a": null, "paciente_id": 27, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-04 21:03:18.229225-05
423	consulta	45	I	3	\N	{"id": 45, "fecha": "2026-11-04T14:30:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control anual de la vista", "medico_id": 3, "referida_a": null, "paciente_id": 8, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-04 21:03:18.229225-05
116	consulta	5	I	3	\N	{"id": 5, "fecha": "2025-12-19T14:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Pérdida de visión lateral", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Evaluación: Glaucoma.", "modificada_en": null, "plan_tratamiento": "Medir presión ocular y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
117	estudio	3	I	3	\N	{"id": 3, "ojo": "R", "imagen_id": 3, "tomado_en": "2025-12-19T14:45:00-05:00", "subido_por": 2, "consulta_id": 5}	\N	2026-11-03 20:41:56.48039-05
121	consulta	6	I	3	\N	{"id": 6, "fecha": "2026-01-13T08:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Pérdida de visión lateral", "medico_id": 3, "referida_a": null, "paciente_id": 8, "notas_cancel": null, "notas_medico": "Evaluación: Glaucoma.", "modificada_en": null, "plan_tratamiento": "Medir presión ocular y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
123	diagnostico	7	I	3	\N	{"id": 7, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-01-13T09:30:00-05:00", "medico_id": 3, "estudio_id": 5, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
124	consulta	7	I	3	\N	{"id": 7, "fecha": "2026-02-26T15:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Manchas en la visión", "medico_id": 3, "referida_a": null, "paciente_id": 9, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
125	estudio	6	I	3	\N	{"id": 6, "ojo": "R", "imagen_id": 6, "tomado_en": "2026-02-26T15:30:00-05:00", "subido_por": 9, "consulta_id": 7}	\N	2026-11-03 20:41:56.48039-05
126	diagnostico	8	I	3	\N	{"id": 8, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-02-26T16:30:00-05:00", "medico_id": 3, "estudio_id": 6, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
127	consulta	8	I	3	\N	{"id": 8, "fecha": "2026-02-04T11:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias al leer", "medico_id": 3, "referida_a": null, "paciente_id": 10, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
128	estudio	7	I	3	\N	{"id": 7, "ojo": "L", "imagen_id": 7, "tomado_en": "2026-02-04T11:45:00-05:00", "subido_por": 10, "consulta_id": 8}	\N	2026-11-03 20:41:56.48039-05
129	diagnostico	9	I	3	\N	{"id": 9, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-02-04T12:45:00-05:00", "medico_id": 3, "estudio_id": 7, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
130	consulta	9	I	3	\N	{"id": 9, "fecha": "2026-03-17T09:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Visión nublada", "medico_id": 3, "referida_a": null, "paciente_id": 16, "notas_cancel": null, "notas_medico": "Evaluación: Catarata.", "modificada_en": null, "plan_tratamiento": "Evaluar opción quirúrgica en la próxima cita.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
131	estudio	8	I	3	\N	{"id": 8, "ojo": "R", "imagen_id": 8, "tomado_en": "2026-03-17T09:45:00-05:00", "subido_por": 16, "consulta_id": 9}	\N	2026-11-03 20:41:56.48039-05
132	diagnostico	10	I	3	\N	{"id": 10, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-03-17T10:45:00-05:00", "medico_id": 3, "estudio_id": 8, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
133	estudio	9	I	3	\N	{"id": 9, "ojo": "L", "imagen_id": 9, "tomado_en": "2026-03-17T09:45:00-05:00", "subido_por": 16, "consulta_id": 9}	\N	2026-11-03 20:41:56.48039-05
134	diagnostico	11	I	3	\N	{"id": 11, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-03-17T10:45:00-05:00", "medico_id": 3, "estudio_id": 9, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
135	consulta	10	I	3	\N	{"id": 10, "fecha": "2026-03-10T13:15:00-05:00", "notas": null, "estado": "atendida", "motivo": "Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 17, "notas_cancel": null, "notas_medico": "Evaluación: Catarata.", "modificada_en": null, "plan_tratamiento": "Evaluar opción quirúrgica en la próxima cita.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
136	estudio	10	I	3	\N	{"id": 10, "ojo": "L", "imagen_id": 10, "tomado_en": "2026-03-10T13:15:00-05:00", "subido_por": 17, "consulta_id": 10}	\N	2026-11-03 20:41:56.48039-05
181	estudio	26	I	3	\N	{"id": 26, "ojo": "R", "imagen_id": 26, "tomado_en": "2026-08-19T08:45:00-05:00", "subido_por": 19, "consulta_id": 23}	\N	2026-11-03 20:41:56.48039-05
138	consulta	11	I	3	\N	{"id": 11, "fecha": "2026-04-06T09:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Antecedente familiar de glaucoma", "medico_id": 3, "referida_a": null, "paciente_id": 19, "notas_cancel": null, "notas_medico": "Evaluación: Glaucoma.", "modificada_en": null, "plan_tratamiento": "Medir presión ocular y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
139	estudio	11	I	3	\N	{"id": 11, "ojo": "R", "imagen_id": 11, "tomado_en": "2026-04-06T09:00:00-05:00", "subido_por": 19, "consulta_id": 11}	\N	2026-11-03 20:41:56.48039-05
140	diagnostico	13	I	3	\N	{"id": 13, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-04-06T10:00:00-05:00", "medico_id": 3, "estudio_id": 11, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
141	consulta	12	I	3	\N	{"id": 12, "fecha": "2026-04-24T10:15:00-05:00", "notas": null, "estado": "atendida", "motivo": "Visión borrosa, paciente diabético", "medico_id": 3, "referida_a": null, "paciente_id": 20, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
142	estudio	12	I	3	\N	{"id": 12, "ojo": "R", "imagen_id": 12, "tomado_en": "2026-04-24T10:15:00-05:00", "subido_por": 20, "consulta_id": 12}	\N	2026-11-03 20:41:56.48039-05
143	diagnostico	14	I	3	\N	{"id": 14, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-04-24T11:15:00-05:00", "medico_id": 3, "estudio_id": 12, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
144	consulta	13	I	3	\N	{"id": 13, "fecha": "2026-05-05T12:15:00-05:00", "notas": null, "estado": "atendida", "motivo": "Visión nublada", "medico_id": 3, "referida_a": null, "paciente_id": 22, "notas_cancel": null, "notas_medico": "Evaluación: Catarata.", "modificada_en": null, "plan_tratamiento": "Evaluar opción quirúrgica en la próxima cita.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
145	estudio	13	I	3	\N	{"id": 13, "ojo": "R", "imagen_id": 13, "tomado_en": "2026-05-05T12:15:00-05:00", "subido_por": 22, "consulta_id": 13}	\N	2026-11-03 20:41:56.48039-05
146	diagnostico	15	I	3	\N	{"id": 15, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-05-05T13:15:00-05:00", "medico_id": 3, "estudio_id": 13, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
147	estudio	14	I	3	\N	{"id": 14, "ojo": "L", "imagen_id": 14, "tomado_en": "2026-05-05T12:15:00-05:00", "subido_por": 22, "consulta_id": 13}	\N	2026-11-03 20:41:56.48039-05
148	diagnostico	16	I	3	\N	{"id": 16, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-05-05T13:15:00-05:00", "medico_id": 3, "estudio_id": 14, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
149	consulta	14	I	3	\N	{"id": 14, "fecha": "2026-05-06T10:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Revisión preventiva", "medico_id": 3, "referida_a": null, "paciente_id": 23, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
150	estudio	15	I	3	\N	{"id": 15, "ojo": "R", "imagen_id": 15, "tomado_en": "2026-05-06T10:00:00-05:00", "subido_por": 23, "consulta_id": 14}	\N	2026-11-03 20:41:56.48039-05
151	diagnostico	17	I	3	\N	{"id": 17, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-05-06T11:00:00-05:00", "medico_id": 3, "estudio_id": 15, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
152	consulta	15	I	3	\N	{"id": 15, "fecha": "2026-06-25T15:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Control anual de la vista", "medico_id": 3, "referida_a": null, "paciente_id": 25, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
153	estudio	16	I	3	\N	{"id": 16, "ojo": "L", "imagen_id": 16, "tomado_en": "2026-06-25T15:45:00-05:00", "subido_por": 25, "consulta_id": 15}	\N	2026-11-03 20:41:56.48039-05
154	diagnostico	18	I	3	\N	{"id": 18, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-06-25T16:45:00-05:00", "medico_id": 3, "estudio_id": 16, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
155	consulta	16	I	3	\N	{"id": 16, "fecha": "2026-06-22T13:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Antecedente familiar de glaucoma", "medico_id": 3, "referida_a": null, "paciente_id": 27, "notas_cancel": null, "notas_medico": "Evaluación: Glaucoma.", "modificada_en": null, "plan_tratamiento": "Medir presión ocular y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
156	estudio	17	I	3	\N	{"id": 17, "ojo": "R", "imagen_id": 17, "tomado_en": "2026-06-22T13:30:00-05:00", "subido_por": 27, "consulta_id": 16}	\N	2026-11-03 20:41:56.48039-05
157	diagnostico	19	I	3	\N	{"id": 19, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-06-22T14:30:00-05:00", "medico_id": 3, "estudio_id": 17, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
158	consulta	17	I	3	\N	{"id": 17, "fecha": "2026-06-15T09:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Evaluación: Catarata.", "modificada_en": null, "plan_tratamiento": "Evaluar opción quirúrgica en la próxima cita.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
160	diagnostico	20	I	3	\N	{"id": 20, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-06-15T10:45:00-05:00", "medico_id": 3, "estudio_id": 18, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
161	estudio	19	I	3	\N	{"id": 19, "ojo": "L", "imagen_id": 19, "tomado_en": "2026-06-15T09:45:00-05:00", "subido_por": 2, "consulta_id": 17}	\N	2026-11-03 20:41:56.48039-05
162	diagnostico	21	I	3	\N	{"id": 21, "clase": "catarata", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-06-15T10:45:00-05:00", "medico_id": 3, "estudio_id": 19, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
163	consulta	18	I	3	\N	{"id": 18, "fecha": "2026-07-15T12:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Visión borrosa, paciente diabético", "medico_id": 3, "referida_a": null, "paciente_id": 8, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
164	estudio	20	I	3	\N	{"id": 20, "ojo": "R", "imagen_id": 20, "tomado_en": "2026-07-15T12:30:00-05:00", "subido_por": 8, "consulta_id": 18}	\N	2026-11-03 20:41:56.48039-05
165	diagnostico	22	I	3	\N	{"id": 22, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-07-15T13:30:00-05:00", "medico_id": 3, "estudio_id": 20, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
166	consulta	19	I	3	\N	{"id": 19, "fecha": "2026-07-17T09:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Visión borrosa, paciente diabético", "medico_id": 3, "referida_a": null, "paciente_id": 9, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
167	estudio	21	I	3	\N	{"id": 21, "ojo": "L", "imagen_id": 21, "tomado_en": "2026-07-17T09:30:00-05:00", "subido_por": 9, "consulta_id": 19}	\N	2026-11-03 20:41:56.48039-05
168	diagnostico	23	I	3	\N	{"id": 23, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-07-17T10:30:00-05:00", "medico_id": 3, "estudio_id": 21, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
169	consulta	20	I	3	\N	{"id": 20, "fecha": "2026-07-15T08:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Revisión preventiva", "medico_id": 3, "referida_a": null, "paciente_id": 10, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
170	estudio	22	I	3	\N	{"id": 22, "ojo": "L", "imagen_id": 22, "tomado_en": "2026-07-15T08:00:00-05:00", "subido_por": 10, "consulta_id": 20}	\N	2026-11-03 20:41:56.48039-05
171	diagnostico	24	I	3	\N	{"id": 24, "clase": "normal", "estado": "rectificado", "version": 1, "vigente": true, "creado_en": "2026-07-15T09:00:00-05:00", "medico_id": 3, "estudio_id": 22, "motivo_cambio": "La revisión clínica no coincide con la predicción del modelo.", "observaciones": "Corregido tras la revisión clínica."}	\N	2026-11-03 20:41:56.48039-05
172	consulta	21	I	3	\N	{"id": 21, "fecha": "2026-08-27T12:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Manchas en la visión", "medico_id": 3, "referida_a": null, "paciente_id": 16, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
173	estudio	23	I	3	\N	{"id": 23, "ojo": "R", "imagen_id": 23, "tomado_en": "2026-08-27T12:00:00-05:00", "subido_por": 16, "consulta_id": 21}	\N	2026-11-03 20:41:56.48039-05
174	diagnostico	25	I	3	\N	{"id": 25, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-08-27T13:00:00-05:00", "medico_id": 3, "estudio_id": 23, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
175	estudio	24	I	3	\N	{"id": 24, "ojo": "L", "imagen_id": 24, "tomado_en": "2026-08-27T12:00:00-05:00", "subido_por": 16, "consulta_id": 21}	\N	2026-11-03 20:41:56.48039-05
176	diagnostico	26	I	3	\N	{"id": 26, "clase": "rd", "estado": "rectificado", "version": 1, "vigente": true, "creado_en": "2026-08-27T13:00:00-05:00", "medico_id": 3, "estudio_id": 24, "motivo_cambio": "La revisión clínica no coincide con la predicción del modelo.", "observaciones": "Corregido tras la revisión clínica."}	\N	2026-11-03 20:41:56.48039-05
177	consulta	22	I	3	\N	{"id": 22, "fecha": "2026-08-21T09:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias al leer", "medico_id": 3, "referida_a": null, "paciente_id": 17, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
178	estudio	25	I	3	\N	{"id": 25, "ojo": "L", "imagen_id": 25, "tomado_en": "2026-08-21T09:45:00-05:00", "subido_por": 17, "consulta_id": 22}	\N	2026-11-03 20:41:56.48039-05
179	diagnostico	27	I	3	\N	{"id": 27, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-08-21T10:45:00-05:00", "medico_id": 3, "estudio_id": 25, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
180	consulta	23	I	3	\N	{"id": 23, "fecha": "2026-08-19T08:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias al leer", "medico_id": 3, "referida_a": null, "paciente_id": 19, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
182	diagnostico	28	I	3	\N	{"id": 28, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-08-19T09:45:00-05:00", "medico_id": 3, "estudio_id": 26, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
183	consulta	24	I	3	\N	{"id": 24, "fecha": "2026-09-11T15:15:00-05:00", "notas": null, "estado": "atendida", "motivo": "Control por diabetes", "medico_id": 3, "referida_a": null, "paciente_id": 20, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
184	estudio	27	I	3	\N	{"id": 27, "ojo": "R", "imagen_id": 27, "tomado_en": "2026-09-11T15:15:00-05:00", "subido_por": 20, "consulta_id": 24}	\N	2026-11-03 20:41:56.48039-05
185	diagnostico	29	I	3	\N	{"id": 29, "clase": "rd", "estado": "rectificado", "version": 1, "vigente": true, "creado_en": "2026-09-11T16:15:00-05:00", "medico_id": 3, "estudio_id": 27, "motivo_cambio": "La revisión clínica no coincide con la predicción del modelo.", "observaciones": "Corregido tras la revisión clínica."}	\N	2026-11-03 20:41:56.48039-05
186	consulta	25	I	3	\N	{"id": 25, "fecha": "2026-09-15T09:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Pérdida de visión lateral", "medico_id": 3, "referida_a": null, "paciente_id": 22, "notas_cancel": null, "notas_medico": "Evaluación: Glaucoma.", "modificada_en": null, "plan_tratamiento": "Medir presión ocular y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
187	estudio	28	I	3	\N	{"id": 28, "ojo": "R", "imagen_id": 28, "tomado_en": "2026-09-15T09:30:00-05:00", "subido_por": 22, "consulta_id": 25}	\N	2026-11-03 20:41:56.48039-05
188	diagnostico	30	I	3	\N	{"id": 30, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-09-15T10:30:00-05:00", "medico_id": 3, "estudio_id": 28, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
189	estudio	29	I	3	\N	{"id": 29, "ojo": "L", "imagen_id": 29, "tomado_en": "2026-09-15T09:30:00-05:00", "subido_por": 22, "consulta_id": 25}	\N	2026-11-03 20:41:56.48039-05
190	diagnostico	31	I	3	\N	{"id": 31, "clase": "glaucoma", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-09-15T10:30:00-05:00", "medico_id": 3, "estudio_id": 29, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
191	consulta	26	I	3	\N	{"id": 26, "fecha": "2026-10-23T09:15:00-05:00", "notas": null, "estado": "atendida", "motivo": "Control anual de la vista", "medico_id": 3, "referida_a": null, "paciente_id": 23, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
192	estudio	30	I	3	\N	{"id": 30, "ojo": "R", "imagen_id": 30, "tomado_en": "2026-10-23T09:15:00-05:00", "subido_por": 23, "consulta_id": 26}	\N	2026-11-03 20:41:56.48039-05
193	diagnostico	32	I	3	\N	{"id": 32, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-10-23T10:15:00-05:00", "medico_id": 3, "estudio_id": 30, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
194	consulta	27	I	3	\N	{"id": 27, "fecha": "2026-10-08T15:45:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias al leer", "medico_id": 3, "referida_a": null, "paciente_id": 25, "notas_cancel": null, "notas_medico": "Evaluación: Normal.", "modificada_en": null, "plan_tratamiento": "Control de rutina en 12 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
195	estudio	31	I	3	\N	{"id": 31, "ojo": "R", "imagen_id": 31, "tomado_en": "2026-10-08T15:45:00-05:00", "subido_por": 25, "consulta_id": 27}	\N	2026-11-03 20:41:56.48039-05
196	diagnostico	33	I	3	\N	{"id": 33, "clase": "normal", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-10-08T16:45:00-05:00", "medico_id": 3, "estudio_id": 31, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
197	consulta	28	I	3	\N	{"id": 28, "fecha": "2026-10-12T13:30:00-05:00", "notas": null, "estado": "atendida", "motivo": "Manchas en la visión", "medico_id": 3, "referida_a": null, "paciente_id": 27, "notas_cancel": null, "notas_medico": "Evaluación: Retinopatía Diabética.", "modificada_en": null, "plan_tratamiento": "Control glucémico y nueva evaluación en 3 meses.", "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
198	estudio	32	I	3	\N	{"id": 32, "ojo": "L", "imagen_id": 32, "tomado_en": "2026-10-12T13:30:00-05:00", "subido_por": 27, "consulta_id": 28}	\N	2026-11-03 20:41:56.48039-05
199	diagnostico	34	I	3	\N	{"id": 34, "clase": "rd", "estado": "confirmado", "version": 1, "vigente": true, "creado_en": "2026-10-12T14:30:00-05:00", "medico_id": 3, "estudio_id": 32, "motivo_cambio": null, "observaciones": "Hallazgos compatibles con la predicción."}	\N	2026-11-03 20:41:56.48039-05
200	consulta	29	I	3	\N	{"id": 29, "fecha": "2026-10-28T10:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control por diabetes", "medico_id": 3, "referida_a": null, "paciente_id": 8, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
201	estudio	33	I	3	\N	{"id": 33, "ojo": "R", "imagen_id": 33, "tomado_en": "2026-10-28T10:00:00-05:00", "subido_por": 8, "consulta_id": 29}	\N	2026-11-03 20:41:56.48039-05
202	consulta	30	I	3	\N	{"id": 30, "fecha": "2026-10-30T10:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Revisión preventiva", "medico_id": 3, "referida_a": null, "paciente_id": 19, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
203	estudio	34	I	3	\N	{"id": 34, "ojo": "R", "imagen_id": 34, "tomado_en": "2026-10-30T10:00:00-05:00", "subido_por": 19, "consulta_id": 30}	\N	2026-11-03 20:41:56.48039-05
204	consulta	31	I	3	\N	{"id": 31, "fecha": "2026-11-01T10:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Pérdida de visión lateral", "medico_id": 3, "referida_a": null, "paciente_id": 22, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
205	estudio	35	I	3	\N	{"id": 35, "ojo": "R", "imagen_id": 35, "tomado_en": "2026-11-01T10:00:00-05:00", "subido_por": 22, "consulta_id": 31}	\N	2026-11-03 20:41:56.48039-05
206	consulta	32	I	3	\N	{"id": 32, "fecha": "2026-11-03T09:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 23, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
207	estudio	36	I	3	\N	{"id": 36, "ojo": "L", "imagen_id": 36, "tomado_en": "2026-11-03T09:00:00-05:00", "subido_por": 23, "consulta_id": 32}	\N	2026-11-03 20:41:56.48039-05
208	consulta	33	I	3	\N	{"id": 33, "fecha": "2026-11-03T11:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control por diabetes", "medico_id": 3, "referida_a": null, "paciente_id": 10, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
209	consulta	34	I	3	\N	{"id": 34, "fecha": "2026-11-03T14:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Control de presión ocular", "medico_id": 3, "referida_a": null, "paciente_id": 25, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	\N	2026-11-03 20:41:56.48039-05
210	consulta	35	I	3	\N	{"id": 35, "fecha": "2026-11-10T09:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento: Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 17, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
211	consulta	36	I	3	\N	{"id": 36, "fecha": "2026-11-19T10:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento: Manchas en la visión", "medico_id": 3, "referida_a": null, "paciente_id": 16, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 21, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
212	consulta	37	I	3	\N	{"id": 37, "fecha": "2026-11-28T11:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento: Control por diabetes", "medico_id": 3, "referida_a": null, "paciente_id": 20, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 24, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
213	consulta	38	I	3	\N	{"id": 38, "fecha": "2026-05-22T14:15:00-05:00", "notas": null, "estado": "cancelada", "motivo": "Control anual de la vista", "medico_id": 3, "referida_a": null, "paciente_id": 17, "notas_cancel": "El paciente no pudo asistir.", "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
214	consulta	39	I	3	\N	{"id": 39, "fecha": "2026-08-20T09:30:00-05:00", "notas": null, "estado": "cancelada", "motivo": "Revisión preventiva", "medico_id": 3, "referida_a": null, "paciente_id": 27, "notas_cancel": "El paciente no pudo asistir.", "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
215	consulta	40	I	3	\N	{"id": 40, "fecha": "2026-07-13T13:15:00-05:00", "notas": "Referido para segunda opinión.", "estado": "referida", "motivo": "Evaluación por especialista", "medico_id": 3, "referida_a": 5, "paciente_id": 9, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": false}	\N	2026-11-03 20:41:56.48039-05
453	consulta	54	I	2	\N	{"id": 54, "fecha": "2026-11-12T07:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Molestias en la vista", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	127.0.0.1	2026-11-11 17:58:14.096873-05
455	consulta	55	I	2	\N	{"id": 55, "fecha": "2026-11-12T07:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Molestias en la vista", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	127.0.0.1	2026-11-11 18:18:04.996506-05
456	estudio	40	I	2	\N	{"id": 40, "ojo": "R", "imagen_id": 41, "tomado_en": "2026-11-11T18:18:05.108925-05:00", "subido_por": 2, "consulta_id": 55}	127.0.0.1	2026-11-11 18:18:05.049066-05
96	consulta	1	U	\N	{"id": 1, "fecha": "2026-09-25T11:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "modificada_en": null}	{"id": 1, "fecha": "2026-09-25T11:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "modificada_en": null}	\N	2026-09-28 11:00:17.58776-05
98	consulta	2	U	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "modificada_en": null, "consulta_padre_id": null}	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "modificada_en": null, "consulta_padre_id": 1}	\N	2026-10-01 10:28:09.686293-05
99	consulta	1	U	\N	{"id": 1, "fecha": "2026-09-25T11:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null}	{"id": 1, "fecha": "2026-09-25T11:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Retinografia izquierda muestra una enfermedad avanzada.", "modificada_en": "2026-10-01T11:27:25.86666-05:00", "plan_tratamiento": "Lidocaina", "consulta_padre_id": null}	\N	2026-10-01 11:27:25.864264-05
15	usuario	11	I	\N	\N	{"id": 11, "rol": "paciente", "email": "arcelia.gamez.gonzales.10@example.com", "activo": true, "nombre": "Arcelia Gamez Gonzales", "telefono": "+507 6384-3547", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
100	consulta	2	U	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 1}	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:11:36.344349-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1}	\N	2026-10-01 14:11:36.340617-05
102	consulta	2	U	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:11:36.344349-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1}	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:30:40.143292-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1}	\N	2026-10-01 14:30:40.139968-05
103	consulta	2	U	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:30:40.143292-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1}	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:30:46.088053-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1}	\N	2026-10-01 14:30:46.085372-05
104	consulta	3	U	\N	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": 2}	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Mismo status, sin mejora.", "modificada_en": "2026-10-01T14:31:17.856528-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 2}	\N	2026-10-01 14:31:17.853647-05
105	consulta	3	U	\N	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Mismo status, sin mejora.", "modificada_en": "2026-10-01T14:31:17.856528-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 2}	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Mismo status, sin mejora.", "modificada_en": "2026-10-01T14:31:21.572432-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 2}	\N	2026-10-01 14:31:21.569856-05
106	consulta	2	U	\N	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:30:46.088053-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1, "solicitar_retinografia": true}	{"id": 2, "fecha": "2026-09-29T05:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Seguimiento: todo en orden.", "modificada_en": "2026-10-01T14:30:46.088053-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 1, "solicitar_retinografia": false}	\N	2026-10-01 17:00:30.383006-05
107	consulta	3	U	\N	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Mismo status, sin mejora.", "modificada_en": "2026-10-01T14:31:21.572432-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 2, "solicitar_retinografia": true}	{"id": 3, "fecha": "2026-11-25T03:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Seguimiento — Molestias en el ojo", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": "Mismo status, sin mejora.", "modificada_en": "2026-10-01T14:31:21.572432-05:00", "plan_tratamiento": "Mismo tratamiento.", "consulta_padre_id": 2, "solicitar_retinografia": false}	\N	2026-10-01 17:00:30.383006-05
317	consulta	32	U	3	{"id": 32, "fecha": "2026-11-03T09:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 23, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	{"id": 32, "fecha": "2026-11-03T09:00:00-05:00", "notas": null, "estado": "atendida", "motivo": "Disminución progresiva de la visión", "medico_id": 3, "referida_a": null, "paciente_id": 23, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	127.0.0.1	2026-11-03 22:43:54.845465-05
454	consulta	54	U	2	{"id": 54, "fecha": "2026-11-12T07:00:00-05:00", "notas": null, "estado": "agendada", "motivo": "Molestias en la vista", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	{"id": 54, "fecha": "2026-11-12T07:00:00-05:00", "notas": null, "estado": "cancelada", "motivo": "Molestias en la vista", "medico_id": 3, "referida_a": null, "paciente_id": 2, "notas_cancel": null, "notas_medico": null, "modificada_en": null, "plan_tratamiento": null, "consulta_padre_id": null, "solicitar_retinografia": true}	127.0.0.1	2026-11-11 18:11:01.214794-05
17	usuario	12	I	\N	\N	{"id": 12, "rol": "paciente", "email": "sr..rolando.farias.53@example.com", "activo": true, "nombre": "Sr. Rolando Farías", "telefono": "+507 6467-6635", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
1	usuario	1	I	\N	\N	{"id": 1, "rol": "admin", "email": "admin@sistema.local", "activo": true, "nombre": "Administrador del sistema", "telefono": null, "creado_en": "2026-08-12T00:38:11.509963-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-08-12 00:38:11.509963-05
4	usuario	3	I	\N	\N	{"id": 3, "rol": "medico", "email": "carlos.mendez@oftaia.med.pa", "activo": true, "nombre": "Dr. Carlos Mendez Rios", "telefono": "+507 6612-3401", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:19:39.316549-05
5	usuario	4	I	\N	\N	{"id": 4, "rol": "medico", "email": "lucia.herrera@oftaia.med.pa", "activo": true, "nombre": "Dra. Lucia Herrera Vasquez", "telefono": "+507 6723-5512", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:19:39.316549-05
6	usuario	5	I	\N	\N	{"id": 5, "rol": "medico", "email": "andres.caballero@oftaia.med.pa", "activo": true, "nombre": "Dr. Andres Caballero Mora", "telefono": "+507 6834-7623", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:19:39.316549-05
7	usuario	6	I	\N	\N	{"id": 6, "rol": "medico", "email": "elena.quintero@oftaia.med.pa", "activo": true, "nombre": "Dra. Elena Quintero Salas", "telefono": "+507 6945-9734", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:19:39.316549-05
8	usuario	7	I	\N	\N	{"id": 7, "rol": "admin", "email": "admin@oftaia.med.pa", "activo": true, "nombre": "Administrador OftaIA", "telefono": null, "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:19:39.316549-05
9	usuario	8	I	\N	\N	{"id": 8, "rol": "paciente", "email": "alberto.laureano.guevara.13@example.com", "activo": true, "nombre": "Alberto Laureano Guevara", "telefono": "+507 6854-2679", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
11	usuario	9	I	\N	\N	{"id": 9, "rol": "paciente", "email": "dario.camilo.trejo.85@example.com", "activo": true, "nombre": "Darío Camilo Trejo", "telefono": "+507 6323-4811", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
13	usuario	10	I	\N	\N	{"id": 10, "rol": "paciente", "email": "silvano.pichardo.aparicio.81@example.com", "activo": true, "nombre": "Silvano Pichardo Aparicio", "telefono": "+507 6325-8359", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
19	usuario	13	I	\N	\N	{"id": 13, "rol": "paciente", "email": "ing..dulce.maria.rangel.15@example.com", "activo": true, "nombre": "Ing. Dulce María Rangel", "telefono": "+507 6180-5803", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
21	usuario	14	I	\N	\N	{"id": 14, "rol": "paciente", "email": "dra..abril.crespo.83@example.com", "activo": true, "nombre": "Dra. Abril Crespo", "telefono": "+507 6777-4733", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
23	usuario	15	I	\N	\N	{"id": 15, "rol": "paciente", "email": "indira.ledesma.20@example.com", "activo": true, "nombre": "Indira Ledesma", "telefono": "+507 6384-8428", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
25	usuario	16	I	\N	\N	{"id": 16, "rol": "paciente", "email": "dulce.ilse.canales.30@example.com", "activo": true, "nombre": "Dulce Ilse Canales", "telefono": "+507 6373-2169", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
27	usuario	17	I	\N	\N	{"id": 17, "rol": "paciente", "email": "juan.calderon.munoz.78@example.com", "activo": true, "nombre": "Juan Calderón Muñoz", "telefono": "+507 6376-4598", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
29	usuario	18	I	\N	\N	{"id": 18, "rol": "paciente", "email": "raquel.estefania.armas.rico.17@example.com", "activo": true, "nombre": "Raquel Estefanía Armas Rico", "telefono": "+507 6510-5386", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
31	usuario	19	I	\N	\N	{"id": 19, "rol": "paciente", "email": "sr..jose.maria.berrios.37@example.com", "activo": true, "nombre": "Sr. José María Berríos", "telefono": "+507 6771-9179", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
33	usuario	20	I	\N	\N	{"id": 20, "rol": "paciente", "email": "dra..rosario.najera.92@example.com", "activo": true, "nombre": "Dra. Rosario Nájera", "telefono": "+507 6352-9830", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
35	usuario	21	I	\N	\N	{"id": 21, "rol": "paciente", "email": "srita..virginia.barrios.84@example.com", "activo": true, "nombre": "Srita. Virginia Barrios", "telefono": "+507 6324-3266", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
37	usuario	22	I	\N	\N	{"id": 22, "rol": "paciente", "email": "soledad.gil.longoria.21@example.com", "activo": true, "nombre": "Soledad Gil Longoria", "telefono": "+507 6742-3621", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
39	usuario	23	I	\N	\N	{"id": 23, "rol": "paciente", "email": "eloisa.campos.olivares.86@example.com", "activo": true, "nombre": "Eloisa Campos Olivares", "telefono": "+507 6579-9669", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
41	usuario	24	I	\N	\N	{"id": 24, "rol": "paciente", "email": "maria.salma.nava.curiel.80@example.com", "activo": true, "nombre": "María Salma Nava Curiel", "telefono": "+507 6649-5371", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
43	usuario	25	I	\N	\N	{"id": 25, "rol": "paciente", "email": "irma.diana.jaramillo.becerra.24@example.com", "activo": true, "nombre": "Irma Diana Jaramillo Becerra", "telefono": "+507 6103-5315", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
45	usuario	26	I	\N	\N	{"id": 26, "rol": "paciente", "email": "dr..renato.guevara.74@example.com", "activo": true, "nombre": "Dr. Renato Guevara", "telefono": "+507 6619-4258", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
47	usuario	27	I	\N	\N	{"id": 27, "rol": "paciente", "email": "miguel.juan.jiminez.57@example.com", "activo": true, "nombre": "Miguel Juan Jimínez", "telefono": "+507 6713-6310", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:11.39284-05
89	usuario	1	U	\N	{"id": 1, "rol": "admin", "email": "admin@sistema.local", "activo": true, "nombre": "Administrador del sistema", "telefono": null, "creado_en": "2026-08-12T00:38:11.509963-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 1, "rol": "admin", "email": "admin@sistema.local", "activo": true, "nombre": "Administrador del sistema", "telefono": null, "creado_en": "2026-08-12T00:38:11.509963-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 15:18:32.590678-05
76	usuario	12	U	\N	{"id": 12, "rol": "paciente", "email": "sr..rolando.farias.53@example.com", "activo": true, "nombre": "Sr. Rolando Farías", "telefono": "+507 6467-6635", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 12, "rol": "paciente", "email": "rolando.farias.53@example.com", "activo": true, "nombre": "Sr. Rolando Farías", "telefono": "+507 6467-6635", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
77	usuario	13	U	\N	{"id": 13, "rol": "paciente", "email": "ing..dulce.maria.rangel.15@example.com", "activo": true, "nombre": "Ing. Dulce María Rangel", "telefono": "+507 6180-5803", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 13, "rol": "paciente", "email": "dulce.maria.rangel.15@example.com", "activo": true, "nombre": "Ing. Dulce María Rangel", "telefono": "+507 6180-5803", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
78	usuario	14	U	\N	{"id": 14, "rol": "paciente", "email": "dra..abril.crespo.83@example.com", "activo": true, "nombre": "Dra. Abril Crespo", "telefono": "+507 6777-4733", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 14, "rol": "paciente", "email": "abril.crespo.83@example.com", "activo": true, "nombre": "Dra. Abril Crespo", "telefono": "+507 6777-4733", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
79	usuario	19	U	\N	{"id": 19, "rol": "paciente", "email": "sr..jose.maria.berrios.37@example.com", "activo": true, "nombre": "Sr. José María Berríos", "telefono": "+507 6771-9179", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 19, "rol": "paciente", "email": "jose.maria.berrios.37@example.com", "activo": true, "nombre": "Sr. José María Berríos", "telefono": "+507 6771-9179", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
80	usuario	20	U	\N	{"id": 20, "rol": "paciente", "email": "dra..rosario.najera.92@example.com", "activo": true, "nombre": "Dra. Rosario Nájera", "telefono": "+507 6352-9830", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 20, "rol": "paciente", "email": "rosario.najera.92@example.com", "activo": true, "nombre": "Dra. Rosario Nájera", "telefono": "+507 6352-9830", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
81	usuario	21	U	\N	{"id": 21, "rol": "paciente", "email": "srita..virginia.barrios.84@example.com", "activo": true, "nombre": "Srita. Virginia Barrios", "telefono": "+507 6324-3266", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 21, "rol": "paciente", "email": "virginia.barrios.84@example.com", "activo": true, "nombre": "Srita. Virginia Barrios", "telefono": "+507 6324-3266", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
82	usuario	26	U	\N	{"id": 26, "rol": "paciente", "email": "dr..renato.guevara.74@example.com", "activo": true, "nombre": "Dr. Renato Guevara", "telefono": "+507 6619-4258", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 26, "rol": "paciente", "email": "renato.guevara.74@example.com", "activo": true, "nombre": "Dr. Renato Guevara", "telefono": "+507 6619-4258", "creado_en": "2026-09-23T09:24:11.39284-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-23 09:24:25.805284-05
90	usuario	3	U	\N	{"id": 3, "rol": "medico", "email": "carlos.mendez@oftaia.med.pa", "activo": true, "nombre": "Dr. Carlos Mendez Rios", "telefono": "+507 6612-3401", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 3, "rol": "medico", "email": "carlos.mendez@prueba.com", "activo": true, "nombre": "Dr. Carlos Mendez Rios", "telefono": "+507 6612-3401", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:35:11.442334-05
91	usuario	4	U	\N	{"id": 4, "rol": "medico", "email": "lucia.herrera@oftaia.med.pa", "activo": true, "nombre": "Dra. Lucia Herrera Vasquez", "telefono": "+507 6723-5512", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 4, "rol": "medico", "email": "lucia.herrera@prueba.com", "activo": true, "nombre": "Dra. Lucia Herrera Vasquez", "telefono": "+507 6723-5512", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:35:11.442334-05
92	usuario	5	U	\N	{"id": 5, "rol": "medico", "email": "andres.caballero@oftaia.med.pa", "activo": true, "nombre": "Dr. Andres Caballero Mora", "telefono": "+507 6834-7623", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 5, "rol": "medico", "email": "andres.caballero@prueba.com", "activo": true, "nombre": "Dr. Andres Caballero Mora", "telefono": "+507 6834-7623", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:35:11.442334-05
93	usuario	6	U	\N	{"id": 6, "rol": "medico", "email": "elena.quintero@oftaia.med.pa", "activo": true, "nombre": "Dra. Elena Quintero Salas", "telefono": "+507 6945-9734", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 6, "rol": "medico", "email": "elena.quintero@prueba.com", "activo": true, "nombre": "Dra. Elena Quintero Salas", "telefono": "+507 6945-9734", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:35:11.442334-05
94	usuario	7	U	\N	{"id": 7, "rol": "admin", "email": "admin@oftaia.med.pa", "activo": true, "nombre": "Administrador OftaIA", "telefono": null, "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 7, "rol": "admin", "email": "admin@prueba.com", "activo": true, "nombre": "Administrador OftaIA", "telefono": null, "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:35:11.442334-05
95	usuario	7	U	\N	{"id": 7, "rol": "admin", "email": "admin@prueba.com", "activo": true, "nombre": "Administrador OftaIA", "telefono": null, "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	{"id": 7, "rol": "admin", "email": "admin@prueba.com", "activo": true, "nombre": "Administrador JYV", "telefono": null, "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-28 09:36:05.916643-05
451	usuario	3	U	3	{"id": 3, "rol": "medico", "email": "carlos.mendez@prueba.com", "activo": true, "nombre": "Dr. Carlos Mendez Rios", "telefono": "+507 6612-3401", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": null, "consentimiento_version": null}	{"id": 3, "rol": "medico", "email": "carlos.mendez@prueba.com", "activo": true, "nombre": "Dr. Carlos Mendez Rios", "telefono": "+507 6612-3401", "creado_en": "2026-09-23T09:19:39.316549-05:00", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": "2026-11-11T17:12:41.318603-05:00", "consentimiento_version": "1.0 (noviembre de 2026)"}	127.0.0.1	2026-11-11 17:12:41.314982-05
2	usuario	2	I	\N	\N	{"id": 2, "rol": "paciente", "email": "paciente.demo@example.com", "activo": true, "nombre": "Paciente Demo", "telefono": null, "creado_en": "2026-09-16T00:05:16.674791-05:00", "fecha_nac": "2000-01-15", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e"}	\N	2026-09-16 00:05:16.674939-05
452	usuario	2	U	2	{"id": 2, "rol": "paciente", "email": "paciente.demo@example.com", "activo": true, "nombre": "Paciente Demo", "telefono": null, "creado_en": "2026-09-16T00:05:16.674791-05:00", "fecha_nac": "2000-01-15", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": null, "consentimiento_version": null}	{"id": 2, "rol": "paciente", "email": "paciente.demo@example.com", "activo": true, "nombre": "Paciente Demo", "telefono": null, "creado_en": "2026-09-16T00:05:16.674791-05:00", "fecha_nac": "2000-01-15", "password_hash": "pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e", "consentimiento_en": "2026-11-11T17:50:01.047573-05:00", "consentimiento_version": "1.0 (noviembre de 2026)"}	127.0.0.1	2026-11-11 17:50:01.044348-05
\.


--
-- Data for Name: celda_confusion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.celda_confusion (evaluacion_id, clase_real, clase_predicha, conteo) FROM stdin;
\.


--
-- Data for Name: conjunto_prueba; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.conjunto_prueba (id, nombre, tipo, fuente, licencia, preproc, n_imagenes, notas) FROM stdin;
1	ODIR-5K test interno	test_interno	Peking University / Shanggong Medical Technology, ODIR-2019	Uso academico	Recorte de borde negro + resize propio	\N	Particion reservada. Solo casos monoetiqueta de las 4 clases
2	APTOS-2019 via pkdarabi	test_externo	Aravind Eye Hospital (India). Redistribuido en Kaggle por pkdarabi, 2023	Por confirmar	Filtro gaussiano (Ben Graham) y resize 224x224 aplicados por el redistribuidor	2838	Etiquetas binarias DR/No_DR. Requiere ablacion con ODIR filtrado para separar el efecto del preprocesamiento
3	ACRIMA	test_externo	Universidad Politecnica de Valencia	Publica	Originales sin procesar	705	Centrado en disco optico, distinto encuadre que ODIR
4	CSDI	test_externo	Cataract Severity and Diagnostic Image Dataset, Scientific Data	Abierta	Originales sin procesar	187	Conjunto pequeno: reportar intervalos de confianza bootstrap
5	Pacientes piloto	validacion_pacientes	Captura propia	Consentimiento informado	Pipeline propio	\N	Pacientes reales del sistema con diagnostico confirmado por especialista
\.


--
-- Data for Name: consulta; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.consulta (id, paciente_id, medico_id, fecha, motivo, notas, estado, referida_a, notas_cancel, modificada_en, consulta_padre_id, plan_tratamiento, notas_medico, solicitar_retinografia) FROM stdin;
32	23	3	2026-11-03 09:00:00-05	Disminución progresiva de la visión	\N	atendida	\N	\N	\N	\N	\N	\N	t
1	2	3	2026-09-25 11:00:00-05	Molestias en el ojo	\N	atendida	\N	\N	2026-10-01 11:27:25.86666-05	\N	Lidocaina	Retinografia izquierda muestra una enfermedad avanzada.	t
2	2	3	2026-09-29 05:00:00-05	Seguimiento — Molestias en el ojo	\N	atendida	\N	\N	2026-10-01 14:30:46.088053-05	1	Mismo tratamiento.	Seguimiento: todo en orden.	f
3	2	3	2026-11-25 03:00:00-05	Seguimiento — Molestias en el ojo	\N	atendida	\N	\N	2026-10-01 14:31:21.572432-05	2	Mismo tratamiento.	Mismo status, sin mejora.	f
4	2	5	2026-10-02 03:00:00-05	Ojo lloroso	\N	agendada	\N	\N	\N	\N	\N	\N	t
5	2	3	2025-12-19 14:45:00-05	Pérdida de visión lateral	\N	atendida	\N	\N	\N	\N	Medir presión ocular y nueva evaluación en 3 meses.	Evaluación: Glaucoma.	t
6	8	3	2026-01-13 08:30:00-05	Pérdida de visión lateral	\N	atendida	\N	\N	\N	\N	Medir presión ocular y nueva evaluación en 3 meses.	Evaluación: Glaucoma.	t
7	9	3	2026-02-26 15:30:00-05	Manchas en la visión	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
8	10	3	2026-02-04 11:45:00-05	Molestias al leer	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
9	16	3	2026-03-17 09:45:00-05	Visión nublada	\N	atendida	\N	\N	\N	\N	Evaluar opción quirúrgica en la próxima cita.	Evaluación: Catarata.	t
10	17	3	2026-03-10 13:15:00-05	Disminución progresiva de la visión	\N	atendida	\N	\N	\N	\N	Evaluar opción quirúrgica en la próxima cita.	Evaluación: Catarata.	t
11	19	3	2026-04-06 09:00:00-05	Antecedente familiar de glaucoma	\N	atendida	\N	\N	\N	\N	Medir presión ocular y nueva evaluación en 3 meses.	Evaluación: Glaucoma.	t
12	20	3	2026-04-24 10:15:00-05	Visión borrosa, paciente diabético	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
13	22	3	2026-05-05 12:15:00-05	Visión nublada	\N	atendida	\N	\N	\N	\N	Evaluar opción quirúrgica en la próxima cita.	Evaluación: Catarata.	t
14	23	3	2026-05-06 10:00:00-05	Revisión preventiva	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
15	25	3	2026-06-25 15:45:00-05	Control anual de la vista	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
16	27	3	2026-06-22 13:30:00-05	Antecedente familiar de glaucoma	\N	atendida	\N	\N	\N	\N	Medir presión ocular y nueva evaluación en 3 meses.	Evaluación: Glaucoma.	t
17	2	3	2026-06-15 09:45:00-05	Disminución progresiva de la visión	\N	atendida	\N	\N	\N	\N	Evaluar opción quirúrgica en la próxima cita.	Evaluación: Catarata.	t
18	8	3	2026-07-15 12:30:00-05	Visión borrosa, paciente diabético	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
19	9	3	2026-07-17 09:30:00-05	Visión borrosa, paciente diabético	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
20	10	3	2026-07-15 08:00:00-05	Revisión preventiva	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
21	16	3	2026-08-27 12:00:00-05	Manchas en la visión	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
22	17	3	2026-08-21 09:45:00-05	Molestias al leer	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
23	19	3	2026-08-19 08:45:00-05	Molestias al leer	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
24	20	3	2026-09-11 15:15:00-05	Control por diabetes	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
25	22	3	2026-09-15 09:30:00-05	Pérdida de visión lateral	\N	atendida	\N	\N	\N	\N	Medir presión ocular y nueva evaluación en 3 meses.	Evaluación: Glaucoma.	t
26	23	3	2026-10-23 09:15:00-05	Control anual de la vista	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
27	25	3	2026-10-08 15:45:00-05	Molestias al leer	\N	atendida	\N	\N	\N	\N	Control de rutina en 12 meses.	Evaluación: Normal.	t
28	27	3	2026-10-12 13:30:00-05	Manchas en la visión	\N	atendida	\N	\N	\N	\N	Control glucémico y nueva evaluación en 3 meses.	Evaluación: Retinopatía Diabética.	t
29	8	3	2026-10-28 10:00:00-05	Control por diabetes	\N	agendada	\N	\N	\N	\N	\N	\N	t
30	19	3	2026-10-30 10:00:00-05	Revisión preventiva	\N	agendada	\N	\N	\N	\N	\N	\N	t
31	22	3	2026-11-01 10:00:00-05	Pérdida de visión lateral	\N	agendada	\N	\N	\N	\N	\N	\N	t
33	10	3	2026-11-03 11:00:00-05	Control por diabetes	\N	agendada	\N	\N	\N	\N	\N	\N	t
34	25	3	2026-11-03 14:00:00-05	Control de presión ocular	\N	agendada	\N	\N	\N	\N	\N	\N	t
35	2	3	2026-11-10 09:00:00-05	Seguimiento: Disminución progresiva de la visión	\N	agendada	\N	\N	\N	17	\N	\N	f
36	16	3	2026-11-19 10:00:00-05	Seguimiento: Manchas en la visión	\N	agendada	\N	\N	\N	21	\N	\N	f
37	20	3	2026-11-28 11:00:00-05	Seguimiento: Control por diabetes	\N	agendada	\N	\N	\N	24	\N	\N	f
38	17	3	2026-05-22 14:15:00-05	Control anual de la vista	\N	cancelada	\N	El paciente no pudo asistir.	\N	\N	\N	\N	f
39	27	3	2026-08-20 09:30:00-05	Revisión preventiva	\N	cancelada	\N	El paciente no pudo asistir.	\N	\N	\N	\N	f
40	9	3	2026-07-13 13:15:00-05	Evaluación por especialista	Referido para segunda opinión.	referida	5	\N	\N	\N	\N	\N	f
41	16	3	2026-11-04 08:30:00-05	Control de presión ocular	\N	agendada	\N	\N	\N	\N	\N	\N	t
42	19	3	2026-11-04 09:30:00-05	Control por diabetes	\N	agendada	\N	\N	\N	\N	\N	\N	t
43	22	3	2026-11-04 10:30:00-05	Visión borrosa	\N	agendada	\N	\N	\N	\N	\N	\N	t
44	27	3	2026-11-04 13:00:00-05	Revisión preventiva	\N	agendada	\N	\N	\N	\N	\N	\N	t
45	8	3	2026-11-04 14:30:00-05	Control anual de la vista	\N	agendada	\N	\N	\N	\N	\N	\N	t
54	2	3	2026-11-12 07:00:00-05	Molestias en la vista	\N	cancelada	\N	\N	\N	\N	\N	\N	t
55	2	3	2026-11-12 07:00:00-05	Molestias en la vista	\N	agendada	\N	\N	\N	\N	\N	\N	t
\.


--
-- Data for Name: diagnostico; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.diagnostico (id, estudio_id, version, clase, estado, observaciones, motivo_cambio, medico_id, creado_en, vigente) FROM stdin;
1	2	1	glaucoma	confirmado	Glaucoma inicial	\N	3	2026-09-23 11:31:54.445091-05	t
2	1	1	normal	confirmado	Ojo normal, sin enfermedades presentes	\N	3	2026-09-23 11:32:19.330495-05	t
5	3	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2025-12-19 15:45:00-05	t
6	4	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2025-12-19 15:45:00-05	t
7	5	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-01-13 09:30:00-05	t
8	6	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-02-26 16:30:00-05	t
9	7	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-02-04 12:45:00-05	t
10	8	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-03-17 10:45:00-05	t
11	9	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-03-17 10:45:00-05	t
12	10	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-03-10 14:15:00-05	t
13	11	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-04-06 10:00:00-05	t
14	12	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-04-24 11:15:00-05	t
15	13	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-05-05 13:15:00-05	t
16	14	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-05-05 13:15:00-05	t
17	15	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-05-06 11:00:00-05	t
18	16	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-06-25 16:45:00-05	t
19	17	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-06-22 14:30:00-05	t
20	18	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-06-15 10:45:00-05	t
21	19	1	catarata	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-06-15 10:45:00-05	t
22	20	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-07-15 13:30:00-05	t
23	21	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-07-17 10:30:00-05	t
24	22	1	normal	rectificado	Corregido tras la revisión clínica.	La revisión clínica no coincide con la predicción del modelo.	3	2026-07-15 09:00:00-05	t
25	23	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-08-27 13:00:00-05	t
26	24	1	rd	rectificado	Corregido tras la revisión clínica.	La revisión clínica no coincide con la predicción del modelo.	3	2026-08-27 13:00:00-05	t
27	25	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-08-21 10:45:00-05	t
28	26	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-08-19 09:45:00-05	t
29	27	1	rd	rectificado	Corregido tras la revisión clínica.	La revisión clínica no coincide con la predicción del modelo.	3	2026-09-11 16:15:00-05	t
30	28	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-09-15 10:30:00-05	t
31	29	1	glaucoma	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-09-15 10:30:00-05	t
32	30	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-10-23 10:15:00-05	t
33	31	1	normal	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-10-08 16:45:00-05	t
34	32	1	rd	confirmado	Hallazgos compatibles con la predicción.	\N	3	2026-10-12 14:30:00-05	t
35	36	1	normal	rectificado	\N	error	3	2026-11-03 22:43:54.873228-05	t
\.


--
-- Data for Name: estudio; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.estudio (id, consulta_id, imagen_id, ojo, tomado_en, subido_por) FROM stdin;
1	1	1	R	2026-09-23 09:46:24.080213-05	2
2	1	2	L	2026-09-23 09:46:28.093283-05	2
3	5	3	R	2025-12-19 14:45:00-05	2
4	5	4	L	2025-12-19 14:45:00-05	2
5	6	5	R	2026-01-13 08:30:00-05	8
6	7	6	R	2026-02-26 15:30:00-05	9
7	8	7	L	2026-02-04 11:45:00-05	10
8	9	8	R	2026-03-17 09:45:00-05	16
9	9	9	L	2026-03-17 09:45:00-05	16
10	10	10	L	2026-03-10 13:15:00-05	17
11	11	11	R	2026-04-06 09:00:00-05	19
12	12	12	R	2026-04-24 10:15:00-05	20
13	13	13	R	2026-05-05 12:15:00-05	22
14	13	14	L	2026-05-05 12:15:00-05	22
15	14	15	R	2026-05-06 10:00:00-05	23
16	15	16	L	2026-06-25 15:45:00-05	25
17	16	17	R	2026-06-22 13:30:00-05	27
18	17	18	R	2026-06-15 09:45:00-05	2
19	17	19	L	2026-06-15 09:45:00-05	2
20	18	20	R	2026-07-15 12:30:00-05	8
21	19	21	L	2026-07-17 09:30:00-05	9
22	20	22	L	2026-07-15 08:00:00-05	10
23	21	23	R	2026-08-27 12:00:00-05	16
24	21	24	L	2026-08-27 12:00:00-05	16
25	22	25	L	2026-08-21 09:45:00-05	17
26	23	26	R	2026-08-19 08:45:00-05	19
27	24	27	R	2026-09-11 15:15:00-05	20
28	25	28	R	2026-09-15 09:30:00-05	22
29	25	29	L	2026-09-15 09:30:00-05	22
30	26	30	R	2026-10-23 09:15:00-05	23
31	27	31	R	2026-10-08 15:45:00-05	25
32	28	32	L	2026-10-12 13:30:00-05	27
33	29	33	R	2026-10-28 10:00:00-05	8
34	30	34	R	2026-10-30 10:00:00-05	19
35	31	35	R	2026-11-01 10:00:00-05	22
36	32	36	L	2026-11-03 09:00:00-05	23
40	55	41	R	2026-11-11 18:18:05.108925-05	2
41	55	42	L	2026-11-11 18:18:08.897586-05	2
\.


--
-- Data for Name: evaluacion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.evaluacion (id, modelo_id, conjunto_id, corrida_en, notas) FROM stdin;
\.


--
-- Data for Name: imagen; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.imagen (id, ruta, sha256, ancho, alto, formato, bytes, cargada_en) FROM stdin;
1	uploads/pac2_20260923_144624_R.jpg	14cf16b35c6569b223c4f9dc38eb3bfc4726395cf9aa74ace5fb45902b735903	1024	560	JPEG	50755	2026-09-23 09:46:24.069065-05
2	uploads/pac2_20260923_144624_L.png	eb9e75e156c749dbb3847dba4494269ee7775de41efac25468b8381265fbe5bb	1015	994	PNG	1114402	2026-09-23 09:46:28.092213-05
3	uploads/pac2_20251219_144500_R.png	995681ee369a22f193a5756a722b3459b806b6ac1cc6dee2baa0809651f863aa	512	512	PNG	189083	2025-12-19 14:45:00-05
4	uploads/pac2_20251219_144500_L.png	a05659d01ff7972378849afc1188a523786930c863c5ae780ab7c96cdd2fa340	512	512	PNG	255759	2025-12-19 14:45:00-05
5	uploads/pac8_20260113_083000_R.png	696062dc1884049e32555a12a6d7142097f76ff3cb4be3b26af084b3dc1d67dc	512	512	PNG	238923	2026-01-13 08:30:00-05
6	uploads/pac9_20260226_153000_R.jpg	269302b38b8760ec2b3673972039e4ad486f2678a95b4f995c003af08767e550	512	512	JPEG	70579	2026-02-26 15:30:00-05
7	uploads/pac10_20260204_114500_L.jpg	ae0c3dcdf61296760dabba687067f6e9b4eca2d920f82377f507343781ecb90b	512	512	JPEG	59981	2026-02-04 11:45:00-05
8	uploads/pac16_20260317_094500_R.jpg	3aafb50878b5b4045a922f6c7a2c439ce4ecddeaec4bb758c5e5ac6b2d96230f	512	512	JPEG	37335	2026-03-17 09:45:00-05
9	uploads/pac16_20260317_094500_L.jpg	e98ffd6937ad7cf69590ba7051433e044259bfb664b3c7698a68d890d1b5b554	512	512	JPEG	45227	2026-03-17 09:45:00-05
10	uploads/pac17_20260310_131500_L.jpg	b7496c3fd4473dfa7c7801f508d8456de32b1e5827afaa6ef4f32eb287194e44	512	512	JPEG	58894	2026-03-10 13:15:00-05
11	uploads/pac19_20260406_090000_R.png	99d140f2ecd49faa0cfdc0a984cea808a4386c31c0069316a8cc342cc4fc2ce7	512	512	PNG	202814	2026-04-06 09:00:00-05
12	uploads/pac20_20260424_101500_R.jpg	d54b666a86b54885e9c9d5ec154e06bb4465c4d46a4c51c26d3f60b4638ea50d	224	224	JPEG	5426	2026-04-24 10:15:00-05
13	uploads/pac22_20260505_121500_R.jpg	0def69bdf81e4dfd2dcfe0ae2d8484615b1122c3f007f4d7bd22bd7b153d4195	512	512	JPEG	39699	2026-05-05 12:15:00-05
14	uploads/pac22_20260505_121500_L.jpg	693770c859b5c6386f4d2c32cf36ec87dbb3d3f27293be817e44f5a348ffe6fe	256	256	JPEG	4922	2026-05-05 12:15:00-05
15	uploads/pac23_20260506_100000_R.jpg	2dd4dce90c19e66d92bd9b0f3eb26c6c26ccb38d081f92fece952f07f0af0384	224	224	JPEG	4796	2026-05-06 10:00:00-05
16	uploads/pac25_20260625_154500_L.jpg	b1948f56f79229cc214a247c88b767fd37d0b681e4d5ab6bb318dd9679cff360	224	224	JPEG	4858	2026-06-25 15:45:00-05
17	uploads/pac27_20260622_133000_R.png	777a6f41b0fbc7746a20045024f8b52bea9a9bca922f5398f41e7ccdf349c2e3	512	512	PNG	250421	2026-06-22 13:30:00-05
18	uploads/pac2_20260615_094500_R.jpg	01f31e8a1171848ff68a9e2b507eb639c50eb5663a1821c5bc3fd0d158268195	256	256	JPEG	4480	2026-06-15 09:45:00-05
19	uploads/pac2_20260615_094500_L.png	357c98c26dc46ab08af424977047abb0890457fc99dd3e424b35451e9cbd4012	2592	1728	PNG	2994141	2026-06-15 09:45:00-05
20	uploads/pac8_20260715_123000_R.jpg	5728d6719d644f81505dfab6ac02a7dee849dc8e24163245d0bf79fa7b22affe	512	512	JPEG	60752	2026-07-15 12:30:00-05
21	uploads/pac9_20260717_093000_L.jpg	b5518609beb2d33f4f0eb5563827070bdb31c5f48bbedf8f5653852e64e7680d	224	224	JPEG	5517	2026-07-17 09:30:00-05
22	uploads/pac10_20260715_080000_L.jpg	feb207512d55bd64b33cdbf3e31e93fb8ae341ecd9ba178f84286d55c9625291	512	512	JPEG	46300	2026-07-15 08:00:00-05
23	uploads/pac16_20260827_120000_R.jpg	bd3bd2d7f5c46a64139c04076e7ef30e3336602da6ceb43e95653786e7e7e3e9	224	224	JPEG	5907	2026-08-27 12:00:00-05
24	uploads/pac16_20260827_120000_L.jpg	e88a39b2ad911602a96cebf7066853867896bde98db21c5b5c8b5805bc80b262	512	512	JPEG	70466	2026-08-27 12:00:00-05
25	uploads/pac17_20260821_094500_L.jpg	edaea1c0caa34cafebe49ff55f0d5a6b1c0ac3abbec90344bfcc35d35bc37c68	224	224	JPEG	6133	2026-08-21 09:45:00-05
26	uploads/pac19_20260819_084500_R.jpg	24e0497a82632c2659b87272a6f393b26fc7eb16d0dc9c58f12c5f5c46596d21	224	224	JPEG	6468	2026-08-19 08:45:00-05
27	uploads/pac20_20260911_151500_R.jpg	3b8500fe108ac146b4cc2a9080a12cddf4e96ae2805f788be8231b7d5d369610	512	512	JPEG	67530	2026-09-11 15:15:00-05
28	uploads/pac22_20260915_093000_R.png	0940c9c618311ed29e0f3875afbd9201a70e565706e39bb486bef2563c3eb110	512	512	PNG	198772	2026-09-15 09:30:00-05
29	uploads/pac22_20260915_093000_L.png	bb890930c4b64f4af25ba6336d9e0cf63cbdacab55ae7a939f15e21dac5a74c5	512	512	PNG	232074	2026-09-15 09:30:00-05
30	uploads/pac23_20261023_091500_R.jpg	915feedb653fb503e70bf40591bda684405a01910730d900f1e3de80f31c4442	224	224	JPEG	6391	2026-10-23 09:15:00-05
31	uploads/pac25_20261008_154500_R.jpg	b1c4c5680cc7c42848a07f2d27cdcaf06f1a91bb2656280fc1ad7c5ea8594699	224	224	JPEG	6533	2026-10-08 15:45:00-05
32	uploads/pac27_20261012_133000_L.jpg	a3dde59d3cb1c7a77fac95a031ed4973ab22d37adec021f69f932c7106ec504c	224	224	JPEG	6742	2026-10-12 13:30:00-05
33	uploads/pac8_20261028_100000_R.jpg	7e074ee831a8ede707e69401bb9045bdcc49e43eabccaa4aea66a53fde667099	512	512	JPEG	78686	2026-10-28 10:00:00-05
34	uploads/pac19_20261030_100000_R.jpg	2f7b2669eeaf8ddcb3af39c2a91037f7a73b763e526173addd7916328c397edc	512	512	JPEG	45457	2026-10-30 10:00:00-05
35	uploads/pac22_20261101_100000_R.png	afa66bc36662b0c301b2d7038590cbf431cfedd6624b1675aedb4cbfed0290d5	512	512	PNG	273573	2026-11-01 10:00:00-05
36	uploads/pac23_20261103_090000_L.jpg	e1252c91af997bd42ec83bc4761cbe6b76167aa2192be69fc4965a837467e78a	256	256	JPEG	5664	2026-11-03 09:00:00-05
41	uploads/pac2_20261111_231805_R.jpg	23c2ca8f3628372d7a02b3bd88d71b09202717cc4828cd85aeb830781767bf08	640	480	JPEG	27300	2026-11-11 18:18:05.077003-05
42	uploads/pac2_20261111_231805_L.jpg	e7eb1269a41f27195592e3ba0a56dd763d62ff0650eeb1a48446dc1ba90d4534	447	447	JPEG	16398	2026-11-11 18:18:08.877863-05
\.


--
-- Data for Name: medico; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.medico (usuario_id, num_idoneidad, especialidad, vigente_hasta) FROM stdin;
3	MED-OFT-4821	Oftalmologia General	2028-12-31
4	MED-OFT-5034	Retina y Vitreo	2027-06-30
5	MED-OFT-5267	Glaucoma y Neuroftalmologia	2029-03-31
6	MED-OFT-5498	Segmento Anterior y Cataratas	2028-09-30
\.


--
-- Data for Name: metrica; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.metrica (id, evaluacion_id, clase, nombre, valor, ic_inf, ic_sup) FROM stdin;
\.


--
-- Data for Name: modelo; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.modelo (id, nombre, version, arquitectura, hash_pesos, entrenado_en, activo, registrado_en) FROM stdin;
1	clasificador-fondo-ojo	0.1.0	Por definir	\N	\N	f	2026-08-12 00:38:11.509963-05
2	Ensemble MV2+RN50	1.0	MobileNetV2 + ResNet50 (TTA-8, promedio)	\N	2026-07-31	f	2026-09-18 10:24:36.576711-05
3	ResNet50	1.0	ResNet50 (Transfer Learning, TTA-8)	\N	2026-07-31	t	2026-09-18 10:40:48.236181-05
\.


--
-- Data for Name: notificacion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.notificacion (id, usuario_id, diagnostico_id, tipo, mensaje, creada_en, leida_en) FROM stdin;
4	2	1	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Glaucoma.	2026-09-23 11:31:54.50176-05	\N
5	2	2	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Normal.	2026-09-23 11:32:19.332004-05	\N
1	3	\N	asignacion_nueva	Nueva cita agendada con Paciente Demo para el 25/09/2026 a las 16:00. Motivo: Molestias en el ojo	2026-09-23 09:42:56.851118-05	2026-09-23 11:32:35.320746-05
2	3	\N	estudio_cargado	Paciente Demo subió retinografías (Ojo Derecho y Ojo Izquierdo). Pendiente de revisión diagnóstica.	2026-09-23 09:46:29.209332-05	2026-09-28 10:41:42.423605-05
6	2	\N	sistema	El Dr./Dra. Dr. Carlos Mendez Rios agendó una cita de seguimiento para el 29/09/2026 a las 10:00. Motivo: Seguimiento — Molestias en el ojo	2026-09-28 12:59:40.445224-05	\N
7	2	\N	sistema	El Dr./Dra. Dr. Carlos Mendez Rios agendó una cita de seguimiento para el 25/11/2026 a las 08:00. Motivo: Seguimiento — Molestias en el ojo	2026-10-01 14:13:35.604429-05	\N
8	5	\N	asignacion_nueva	Nueva cita agendada con Paciente Demo para el 02/10/2026 a las 08:00. Motivo: Ojo lloroso	2026-10-01 17:17:26.958954-05	\N
9	2	5	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Glaucoma.	2025-12-19 15:45:00-05	2025-12-19 17:45:00-05
10	2	6	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Glaucoma.	2025-12-19 15:45:00-05	2025-12-19 17:45:00-05
11	8	7	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Glaucoma.	2026-01-13 09:30:00-05	2026-01-13 11:30:00-05
12	9	8	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Retinopatía Diabética.	2026-02-26 16:30:00-05	2026-02-26 18:30:00-05
13	10	9	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Normal.	2026-02-04 12:45:00-05	2026-02-04 14:45:00-05
14	16	10	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Catarata.	2026-03-17 10:45:00-05	2026-03-17 12:45:00-05
15	16	11	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Catarata.	2026-03-17 10:45:00-05	2026-03-17 12:45:00-05
16	17	12	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Catarata.	2026-03-10 14:15:00-05	2026-03-10 16:15:00-05
17	19	13	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Glaucoma.	2026-04-06 10:00:00-05	2026-04-06 12:00:00-05
18	20	14	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Retinopatía Diabética.	2026-04-24 11:15:00-05	2026-04-24 13:15:00-05
19	22	15	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Catarata.	2026-05-05 13:15:00-05	2026-05-05 15:15:00-05
20	22	16	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Catarata.	2026-05-05 13:15:00-05	2026-05-05 15:15:00-05
21	23	17	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Normal.	2026-05-06 11:00:00-05	2026-05-06 13:00:00-05
22	25	18	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Normal.	2026-06-25 16:45:00-05	2026-06-25 18:45:00-05
23	27	19	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Glaucoma.	2026-06-22 14:30:00-05	2026-06-22 16:30:00-05
24	2	20	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Catarata.	2026-06-15 10:45:00-05	2026-06-15 12:45:00-05
25	2	21	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Catarata.	2026-06-15 10:45:00-05	2026-06-15 12:45:00-05
26	8	22	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Retinopatía Diabética.	2026-07-15 13:30:00-05	2026-07-15 15:30:00-05
27	9	23	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Retinopatía Diabética.	2026-07-17 10:30:00-05	2026-07-17 12:30:00-05
28	10	24	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Normal.	2026-07-15 09:00:00-05	2026-07-15 11:00:00-05
29	16	25	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Retinopatía Diabética.	2026-08-27 13:00:00-05	2026-08-27 15:00:00-05
30	16	26	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Retinopatía Diabética.	2026-08-27 13:00:00-05	2026-08-27 15:00:00-05
31	17	27	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Normal.	2026-08-21 10:45:00-05	2026-08-21 12:45:00-05
32	19	28	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Normal.	2026-08-19 09:45:00-05	2026-08-19 11:45:00-05
33	20	29	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Retinopatía Diabética.	2026-09-11 16:15:00-05	2026-09-11 18:15:00-05
34	22	30	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Glaucoma.	2026-09-15 10:30:00-05	2026-09-15 12:30:00-05
35	22	31	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Glaucoma.	2026-09-15 10:30:00-05	2026-09-15 12:30:00-05
36	23	32	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Normal.	2026-10-23 10:15:00-05	2026-10-23 12:15:00-05
37	25	33	diagnostico_listo	Tu diagnóstico para Ojo Derecho está listo: Normal.	2026-10-08 16:45:00-05	2026-10-08 18:45:00-05
38	27	34	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo está listo: Retinopatía Diabética.	2026-10-12 14:30:00-05	2026-10-12 16:30:00-05
39	3	\N	estudio_cargado	Se cargó una retinografía (Ojo Derecho). Pendiente de revisión diagnóstica.	2026-10-28 10:00:00-05	\N
40	3	\N	estudio_cargado	Se cargó una retinografía (Ojo Derecho). Pendiente de revisión diagnóstica.	2026-10-30 10:00:00-05	\N
41	3	\N	estudio_cargado	Se cargó una retinografía (Ojo Derecho). Pendiente de revisión diagnóstica.	2026-11-01 10:00:00-05	\N
42	3	\N	estudio_cargado	Se cargó una retinografía (Ojo Izquierdo). Pendiente de revisión diagnóstica.	2026-11-03 09:00:00-05	\N
43	23	35	diagnostico_listo	Tu diagnóstico para Ojo Izquierdo fue actualizado: Normal.	2026-11-03 22:43:54.982365-05	\N
3	2	\N	estudio_cargado	Tus retinografías (Ojo Derecho y Ojo Izquierdo) fueron analizadas por el modelo predictivo. El médico las revisará pronto.	2026-09-23 09:46:29.209336-05	2026-09-23 11:08:18.452814-05
54	3	\N	asignacion_nueva	Nueva cita agendada con Paciente Demo para el 12/11/2026 a las 12:00. Motivo: Molestias en la vista	2026-11-11 17:58:14.167217-05	\N
55	3	\N	sistema	Paciente Demo canceló la cita del 12/11/2026 a las 07:00.	2026-11-11 18:11:01.237668-05	\N
56	3	\N	asignacion_nueva	Nueva cita agendada con Paciente Demo para el 12/11/2026 a las 12:00. Motivo: Molestias en la vista	2026-11-11 18:18:05.040814-05	\N
57	3	\N	estudio_cargado	Paciente Demo subió retinografías al agendar la cita del 12/11/2026.	2026-11-11 18:18:10.087253-05	\N
\.


--
-- Data for Name: paciente; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.paciente (usuario_id, cedula, fecha_nac, sexo, anonimizado, cancelacion_solicitada_en, anonimizado_en) FROM stdin;
8	3-350-4657	1996-03-22	M	f	\N	\N
9	4-132-1488	2000-05-02	M	f	\N	\N
10	2-833-9928	1971-02-08	M	f	\N	\N
11	2-814-7924	1978-03-20	F	f	\N	\N
12	1-194-7224	2000-01-24	M	f	\N	\N
13	4-649-3045	1974-10-13	F	f	\N	\N
14	2-821-2139	2004-08-18	F	f	\N	\N
15	2-987-2654	1974-08-22	F	f	\N	\N
16	3-463-4432	1948-08-13	F	f	\N	\N
17	2-267-8573	1974-09-13	M	f	\N	\N
18	2-941-1525	1980-06-10	F	f	\N	\N
19	8-997-6155	1989-08-31	M	f	\N	\N
20	4-246-5339	1996-03-19	F	f	\N	\N
21	4-697-7543	1976-04-07	F	f	\N	\N
22	1-981-2796	1995-01-11	F	f	\N	\N
23	1-494-7252	1955-04-13	F	f	\N	\N
24	1-796-2876	1947-08-01	F	f	\N	\N
25	3-545-3591	1968-01-14	F	f	\N	\N
26	1-991-5889	1951-06-02	M	f	\N	\N
27	2-652-9689	2008-09-09	M	f	\N	\N
2	3-700-1001	2000-01-15	\N	f	\N	\N
\.


--
-- Data for Name: prediccion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.prediccion (id, estudio_id, modelo_id, clase, confianza, ms_computo, generado_en) FROM stdin;
1	1	3	normal	0.9910	3899	2026-09-23 09:46:27.987981-05
2	2	3	glaucoma	0.7509	1111	2026-09-23 09:46:29.206135-05
3	3	3	glaucoma	0.9999	4341	2025-12-19 14:45:00-05
4	4	3	glaucoma	0.9579	1055	2025-12-19 14:45:00-05
5	5	3	glaucoma	0.8291	1124	2026-01-13 08:30:00-05
6	6	3	rd	0.5942	1129	2026-02-26 15:30:00-05
7	7	3	normal	0.4458	1126	2026-02-04 11:45:00-05
8	8	3	catarata	0.9844	1181	2026-03-17 09:45:00-05
9	9	3	catarata	0.9542	1144	2026-03-17 09:45:00-05
10	10	3	catarata	0.4273	1068	2026-03-10 13:15:00-05
11	11	3	glaucoma	0.9754	1013	2026-04-06 09:00:00-05
12	12	3	rd	0.9945	1228	2026-04-24 10:15:00-05
13	13	3	catarata	0.9157	1135	2026-05-05 12:15:00-05
14	14	3	catarata	0.9957	1078	2026-05-05 12:15:00-05
15	15	3	normal	0.9958	1074	2026-05-06 10:00:00-05
16	16	3	normal	0.9098	1161	2026-06-25 15:45:00-05
17	17	3	glaucoma	0.9503	1127	2026-06-22 13:30:00-05
18	18	3	catarata	0.9982	1129	2026-06-15 09:45:00-05
19	19	3	catarata	0.9494	1201	2026-06-15 09:45:00-05
20	20	3	rd	0.5767	1116	2026-07-15 12:30:00-05
21	21	3	rd	0.9231	1168	2026-07-17 09:30:00-05
22	22	3	glaucoma	0.4757	1102	2026-07-15 08:00:00-05
23	23	3	rd	0.9753	1104	2026-08-27 12:00:00-05
24	24	3	normal	0.5894	1145	2026-08-27 12:00:00-05
25	25	3	normal	0.9833	1120	2026-08-21 09:45:00-05
26	26	3	normal	0.9809	1128	2026-08-19 08:45:00-05
27	27	3	normal	0.4586	1107	2026-09-11 15:15:00-05
28	28	3	glaucoma	0.9989	1133	2026-09-15 09:30:00-05
29	29	3	glaucoma	0.9551	1087	2026-09-15 09:30:00-05
30	30	3	normal	0.9958	1112	2026-10-23 09:15:00-05
31	31	3	normal	0.9872	1155	2026-10-08 15:45:00-05
32	32	3	rd	0.9935	1195	2026-10-12 13:30:00-05
33	33	3	normal	0.5957	1075	2026-10-28 10:00:00-05
34	34	3	glaucoma	0.5152	1105	2026-10-30 10:00:00-05
35	35	3	glaucoma	0.6495	1073	2026-11-01 10:00:00-05
36	36	3	catarata	0.9899	1055	2026-11-03 09:00:00-05
42	40	3	rd	0.9292	3733	2026-11-11 18:18:08.859413-05
43	41	3	rd	0.9635	1185	2026-11-11 18:18:10.085666-05
\.


--
-- Data for Name: prediccion_probabilidad; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.prediccion_probabilidad (prediccion_id, clase, valor) FROM stdin;
1	normal	0.99101
1	rd	0.00225
1	glaucoma	0.00049
1	catarata	0.00625
2	normal	0.23222
2	rd	0.01637
2	glaucoma	0.75094
2	catarata	0.00048
3	normal	0.00005
3	rd	0.00001
3	glaucoma	0.99993
3	catarata	0.00001
4	normal	0.03204
4	rd	0.00877
4	glaucoma	0.95788
4	catarata	0.00131
5	normal	0.14569
5	rd	0.02430
5	glaucoma	0.82910
5	catarata	0.00091
6	normal	0.17593
6	rd	0.59417
6	glaucoma	0.19640
6	catarata	0.03351
7	normal	0.44582
7	rd	0.35437
7	glaucoma	0.17434
7	catarata	0.02548
8	normal	0.00351
8	rd	0.00651
8	glaucoma	0.00561
8	catarata	0.98437
9	normal	0.01992
9	rd	0.00913
9	glaucoma	0.01675
9	catarata	0.95419
10	normal	0.24339
10	rd	0.15506
10	glaucoma	0.17425
10	catarata	0.42730
11	normal	0.02114
11	rd	0.00228
11	glaucoma	0.97540
11	catarata	0.00119
12	normal	0.00259
12	rd	0.99453
12	glaucoma	0.00282
12	catarata	0.00006
13	normal	0.03267
13	rd	0.01632
13	glaucoma	0.03530
13	catarata	0.91571
14	normal	0.00317
14	rd	0.00017
14	glaucoma	0.00091
14	catarata	0.99575
15	normal	0.99575
15	rd	0.00370
15	glaucoma	0.00002
15	catarata	0.00053
16	normal	0.90980
16	rd	0.08353
16	glaucoma	0.00509
16	catarata	0.00158
17	normal	0.03097
17	rd	0.01765
17	glaucoma	0.95026
17	catarata	0.00112
18	normal	0.00077
18	rd	0.00059
18	glaucoma	0.00043
18	catarata	0.99821
19	normal	0.04558
19	rd	0.00063
19	glaucoma	0.00443
19	catarata	0.94936
20	normal	0.38118
20	rd	0.57667
20	glaucoma	0.02993
20	catarata	0.01222
21	normal	0.07069
21	rd	0.92314
21	glaucoma	0.00500
21	catarata	0.00117
22	normal	0.11083
22	rd	0.05133
22	glaucoma	0.47574
22	catarata	0.36210
23	normal	0.00810
23	rd	0.97530
23	glaucoma	0.01454
23	catarata	0.00206
24	normal	0.58938
24	rd	0.33840
24	glaucoma	0.05945
24	catarata	0.01277
25	normal	0.98330
25	rd	0.01572
25	glaucoma	0.00041
25	catarata	0.00057
26	normal	0.98085
26	rd	0.01849
26	glaucoma	0.00047
26	catarata	0.00018
27	normal	0.45860
27	rd	0.19640
27	glaucoma	0.23157
27	catarata	0.11343
28	normal	0.00040
28	rd	0.00067
28	glaucoma	0.99888
28	catarata	0.00004
29	normal	0.01131
29	rd	0.03256
29	glaucoma	0.95513
29	catarata	0.00100
30	normal	0.99581
30	rd	0.00376
30	glaucoma	0.00012
30	catarata	0.00031
31	normal	0.98719
31	rd	0.01244
31	glaucoma	0.00024
31	catarata	0.00014
32	normal	0.00125
32	rd	0.99348
32	glaucoma	0.00495
32	catarata	0.00033
33	normal	0.59574
33	rd	0.38458
33	glaucoma	0.01096
33	catarata	0.00872
34	normal	0.09250
34	rd	0.34869
34	glaucoma	0.51524
34	catarata	0.04356
35	normal	0.30300
35	rd	0.02924
35	glaucoma	0.64949
35	catarata	0.01827
36	normal	0.00413
36	rd	0.00232
36	glaucoma	0.00367
36	catarata	0.98988
42	normal	0.00647
42	rd	0.92923
42	glaucoma	0.06099
42	catarata	0.00332
43	normal	0.00553
43	rd	0.96352
43	glaucoma	0.03066
43	catarata	0.00029
\.


--
-- Data for Name: sesion; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.sesion (id, usuario_id, token_hash, ip, user_agent, creada_en, expira_en, revocada_en) FROM stdin;
\.


--
-- Data for Name: usuario; Type: TABLE DATA; Schema: oftalmologia; Owner: -
--

COPY oftalmologia.usuario (id, email, password_hash, rol, nombre, telefono, activo, creado_en, consentimiento_en, consentimiento_version) FROM stdin;
7	admin@prueba.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	admin	Administrador JYV	\N	t	2026-09-23 09:19:39.316549-05	\N	\N
8	alberto.laureano.guevara.13@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Alberto Laureano Guevara	+507 6854-2679	t	2026-09-23 09:24:11.39284-05	\N	\N
9	dario.camilo.trejo.85@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Darío Camilo Trejo	+507 6323-4811	t	2026-09-23 09:24:11.39284-05	\N	\N
10	silvano.pichardo.aparicio.81@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Silvano Pichardo Aparicio	+507 6325-8359	t	2026-09-23 09:24:11.39284-05	\N	\N
11	arcelia.gamez.gonzales.10@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Arcelia Gamez Gonzales	+507 6384-3547	t	2026-09-23 09:24:11.39284-05	\N	\N
15	indira.ledesma.20@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Indira Ledesma	+507 6384-8428	t	2026-09-23 09:24:11.39284-05	\N	\N
16	dulce.ilse.canales.30@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Dulce Ilse Canales	+507 6373-2169	t	2026-09-23 09:24:11.39284-05	\N	\N
17	juan.calderon.munoz.78@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Juan Calderón Muñoz	+507 6376-4598	t	2026-09-23 09:24:11.39284-05	\N	\N
18	raquel.estefania.armas.rico.17@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Raquel Estefanía Armas Rico	+507 6510-5386	t	2026-09-23 09:24:11.39284-05	\N	\N
22	soledad.gil.longoria.21@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Soledad Gil Longoria	+507 6742-3621	t	2026-09-23 09:24:11.39284-05	\N	\N
23	eloisa.campos.olivares.86@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Eloisa Campos Olivares	+507 6579-9669	t	2026-09-23 09:24:11.39284-05	\N	\N
24	maria.salma.nava.curiel.80@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	María Salma Nava Curiel	+507 6649-5371	t	2026-09-23 09:24:11.39284-05	\N	\N
25	irma.diana.jaramillo.becerra.24@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Irma Diana Jaramillo Becerra	+507 6103-5315	t	2026-09-23 09:24:11.39284-05	\N	\N
27	miguel.juan.jiminez.57@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Miguel Juan Jimínez	+507 6713-6310	t	2026-09-23 09:24:11.39284-05	\N	\N
12	rolando.farias.53@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Sr. Rolando Farías	+507 6467-6635	t	2026-09-23 09:24:11.39284-05	\N	\N
13	dulce.maria.rangel.15@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Ing. Dulce María Rangel	+507 6180-5803	t	2026-09-23 09:24:11.39284-05	\N	\N
14	abril.crespo.83@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Dra. Abril Crespo	+507 6777-4733	t	2026-09-23 09:24:11.39284-05	\N	\N
19	jose.maria.berrios.37@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Sr. José María Berríos	+507 6771-9179	t	2026-09-23 09:24:11.39284-05	\N	\N
20	rosario.najera.92@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Dra. Rosario Nájera	+507 6352-9830	t	2026-09-23 09:24:11.39284-05	\N	\N
21	virginia.barrios.84@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Srita. Virginia Barrios	+507 6324-3266	t	2026-09-23 09:24:11.39284-05	\N	\N
26	renato.guevara.74@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Dr. Renato Guevara	+507 6619-4258	t	2026-09-23 09:24:11.39284-05	\N	\N
4	lucia.herrera@prueba.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	medico	Dra. Lucia Herrera Vasquez	+507 6723-5512	t	2026-09-23 09:19:39.316549-05	\N	\N
5	andres.caballero@prueba.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	medico	Dr. Andres Caballero Mora	+507 6834-7623	t	2026-09-23 09:19:39.316549-05	\N	\N
6	elena.quintero@prueba.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	medico	Dra. Elena Quintero Salas	+507 6945-9734	t	2026-09-23 09:19:39.316549-05	\N	\N
3	carlos.mendez@prueba.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	medico	Dr. Carlos Mendez Rios	+507 6612-3401	t	2026-09-23 09:19:39.316549-05	2026-11-11 17:12:41.318603-05	1.0 (noviembre de 2026)
1	admin@sistema.local	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	admin	Administrador del sistema	\N	t	2026-08-12 00:38:11.509963-05	2026-11-11 20:42:09.202432-05	1.0 (noviembre de 2026)
2	paciente.demo@example.com	pbkdf2:sha256:600000$UABoYUPpkvM1lbGJ$87d983aed31783c6be2ce1894bc6f6e8e97f132662b7de9142c52201b422ac8e	paciente	Paciente Demo	\N	t	2026-09-16 00:05:16.674791-05	2026-11-11 17:50:01.047573-05	1.0 (noviembre de 2026)
\.


--
-- Name: asignacion_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.asignacion_id_seq', 30, true);


--
-- Name: auditoria_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.auditoria_id_seq', 458, true);


--
-- Name: conjunto_prueba_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.conjunto_prueba_id_seq', 5, true);


--
-- Name: consulta_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.consulta_id_seq', 55, true);


--
-- Name: diagnostico_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.diagnostico_id_seq', 44, true);


--
-- Name: estudio_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.estudio_id_seq', 41, true);


--
-- Name: evaluacion_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.evaluacion_id_seq', 1, false);


--
-- Name: imagen_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.imagen_id_seq', 42, true);


--
-- Name: metrica_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.metrica_id_seq', 1, false);


--
-- Name: modelo_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.modelo_id_seq', 3, true);


--
-- Name: notificacion_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.notificacion_id_seq', 57, true);


--
-- Name: prediccion_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.prediccion_id_seq', 43, true);


--
-- Name: sesion_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.sesion_id_seq', 1, false);


--
-- Name: usuario_id_seq; Type: SEQUENCE SET; Schema: oftalmologia; Owner: -
--

SELECT pg_catalog.setval('oftalmologia.usuario_id_seq', 29, true);


--
-- Name: asignacion asignacion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.asignacion
    ADD CONSTRAINT asignacion_pkey PRIMARY KEY (id);


--
-- Name: auditoria auditoria_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.auditoria
    ADD CONSTRAINT auditoria_pkey PRIMARY KEY (id);


--
-- Name: celda_confusion celda_confusion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.celda_confusion
    ADD CONSTRAINT celda_confusion_pkey PRIMARY KEY (evaluacion_id, clase_real, clase_predicha);


--
-- Name: conjunto_prueba conjunto_prueba_nombre_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.conjunto_prueba
    ADD CONSTRAINT conjunto_prueba_nombre_key UNIQUE (nombre);


--
-- Name: conjunto_prueba conjunto_prueba_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.conjunto_prueba
    ADD CONSTRAINT conjunto_prueba_pkey PRIMARY KEY (id);


--
-- Name: consulta consulta_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta
    ADD CONSTRAINT consulta_pkey PRIMARY KEY (id);


--
-- Name: diagnostico diagnostico_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.diagnostico
    ADD CONSTRAINT diagnostico_pkey PRIMARY KEY (id);


--
-- Name: estudio estudio_imagen_id_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio
    ADD CONSTRAINT estudio_imagen_id_key UNIQUE (imagen_id);


--
-- Name: estudio estudio_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio
    ADD CONSTRAINT estudio_pkey PRIMARY KEY (id);


--
-- Name: evaluacion evaluacion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.evaluacion
    ADD CONSTRAINT evaluacion_pkey PRIMARY KEY (id);


--
-- Name: imagen imagen_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.imagen
    ADD CONSTRAINT imagen_pkey PRIMARY KEY (id);


--
-- Name: imagen imagen_sha256_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.imagen
    ADD CONSTRAINT imagen_sha256_key UNIQUE (sha256);


--
-- Name: medico medico_num_idoneidad_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.medico
    ADD CONSTRAINT medico_num_idoneidad_key UNIQUE (num_idoneidad);


--
-- Name: medico medico_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.medico
    ADD CONSTRAINT medico_pkey PRIMARY KEY (usuario_id);


--
-- Name: metrica metrica_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.metrica
    ADD CONSTRAINT metrica_pkey PRIMARY KEY (id);


--
-- Name: modelo modelo_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.modelo
    ADD CONSTRAINT modelo_pkey PRIMARY KEY (id);


--
-- Name: notificacion notificacion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.notificacion
    ADD CONSTRAINT notificacion_pkey PRIMARY KEY (id);


--
-- Name: paciente paciente_cedula_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.paciente
    ADD CONSTRAINT paciente_cedula_key UNIQUE (cedula);


--
-- Name: paciente paciente_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.paciente
    ADD CONSTRAINT paciente_pkey PRIMARY KEY (usuario_id);


--
-- Name: prediccion prediccion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion
    ADD CONSTRAINT prediccion_pkey PRIMARY KEY (id);


--
-- Name: prediccion_probabilidad prediccion_probabilidad_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion_probabilidad
    ADD CONSTRAINT prediccion_probabilidad_pkey PRIMARY KEY (prediccion_id, clase);


--
-- Name: sesion sesion_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.sesion
    ADD CONSTRAINT sesion_pkey PRIMARY KEY (id);


--
-- Name: sesion sesion_token_hash_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.sesion
    ADD CONSTRAINT sesion_token_hash_key UNIQUE (token_hash);


--
-- Name: asignacion uq_asig_unica; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.asignacion
    ADD CONSTRAINT uq_asig_unica UNIQUE (medico_id, paciente_id, desde);


--
-- Name: diagnostico uq_diag_version; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.diagnostico
    ADD CONSTRAINT uq_diag_version UNIQUE (estudio_id, version);


--
-- Name: metrica uq_metrica; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.metrica
    ADD CONSTRAINT uq_metrica UNIQUE (evaluacion_id, clase, nombre);


--
-- Name: modelo uq_modelo_version; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.modelo
    ADD CONSTRAINT uq_modelo_version UNIQUE (nombre, version);


--
-- Name: prediccion uq_pred_estudio_modelo; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion
    ADD CONSTRAINT uq_pred_estudio_modelo UNIQUE (estudio_id, modelo_id);


--
-- Name: usuario usuario_email_key; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.usuario
    ADD CONSTRAINT usuario_email_key UNIQUE (email);


--
-- Name: usuario usuario_pkey; Type: CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.usuario
    ADD CONSTRAINT usuario_pkey PRIMARY KEY (id);


--
-- Name: ix_asig_medico; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_asig_medico ON oftalmologia.asignacion USING btree (medico_id) WHERE (hasta IS NULL);


--
-- Name: ix_asig_paciente; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_asig_paciente ON oftalmologia.asignacion USING btree (paciente_id) WHERE (hasta IS NULL);


--
-- Name: ix_aud_tabla_reg; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_aud_tabla_reg ON oftalmologia.auditoria USING btree (tabla, registro_id, ocurrido_en DESC);


--
-- Name: ix_aud_usuario; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_aud_usuario ON oftalmologia.auditoria USING btree (usuario_id, ocurrido_en DESC);


--
-- Name: ix_consulta_medico; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_consulta_medico ON oftalmologia.consulta USING btree (medico_id, fecha DESC);


--
-- Name: ix_consulta_paciente; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_consulta_paciente ON oftalmologia.consulta USING btree (paciente_id, fecha DESC);


--
-- Name: ix_diag_estudio; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_diag_estudio ON oftalmologia.diagnostico USING btree (estudio_id, version DESC);


--
-- Name: ix_diag_medico; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_diag_medico ON oftalmologia.diagnostico USING btree (medico_id, creado_en DESC);


--
-- Name: ix_estudio_consulta; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_estudio_consulta ON oftalmologia.estudio USING btree (consulta_id);


--
-- Name: ix_metrica_eval; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_metrica_eval ON oftalmologia.metrica USING btree (evaluacion_id);


--
-- Name: ix_notif_pendiente; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_notif_pendiente ON oftalmologia.notificacion USING btree (usuario_id) WHERE (leida_en IS NULL);


--
-- Name: ix_pred_estudio; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_pred_estudio ON oftalmologia.prediccion USING btree (estudio_id);


--
-- Name: ix_sesion_vigente; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE INDEX ix_sesion_vigente ON oftalmologia.sesion USING btree (usuario_id) WHERE (revocada_en IS NULL);


--
-- Name: ux_diag_vigente; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE UNIQUE INDEX ux_diag_vigente ON oftalmologia.diagnostico USING btree (estudio_id) WHERE vigente;


--
-- Name: ux_modelo_activo; Type: INDEX; Schema: oftalmologia; Owner: -
--

CREATE UNIQUE INDEX ux_modelo_activo ON oftalmologia.modelo USING btree (activo) WHERE activo;


--
-- Name: asignacion tr_aud_asignacion; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_asignacion AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.asignacion FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: consulta tr_aud_consulta; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_consulta AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.consulta FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: diagnostico tr_aud_diagnostico; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_diagnostico AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.diagnostico FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: estudio tr_aud_estudio; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_estudio AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.estudio FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: paciente tr_aud_paciente; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_paciente AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.paciente FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: usuario tr_aud_usuario; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_aud_usuario AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.usuario FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_auditar();


--
-- Name: diagnostico tr_diag_versionar; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_diag_versionar BEFORE INSERT ON oftalmologia.diagnostico FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_diag_versionar();


--
-- Name: prediccion_probabilidad tr_prob_suma; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE CONSTRAINT TRIGGER tr_prob_suma AFTER INSERT OR DELETE OR UPDATE ON oftalmologia.prediccion_probabilidad DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_verificar_suma_prob();


--
-- Name: medico tr_rol_medico; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_rol_medico BEFORE INSERT OR UPDATE ON oftalmologia.medico FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_verificar_rol('medico');


--
-- Name: paciente tr_rol_paciente; Type: TRIGGER; Schema: oftalmologia; Owner: -
--

CREATE TRIGGER tr_rol_paciente BEFORE INSERT OR UPDATE ON oftalmologia.paciente FOR EACH ROW EXECUTE FUNCTION oftalmologia.fn_verificar_rol('paciente');


--
-- Name: asignacion asignacion_medico_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.asignacion
    ADD CONSTRAINT asignacion_medico_id_fkey FOREIGN KEY (medico_id) REFERENCES oftalmologia.medico(usuario_id) ON DELETE RESTRICT;


--
-- Name: asignacion asignacion_paciente_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.asignacion
    ADD CONSTRAINT asignacion_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES oftalmologia.paciente(usuario_id) ON DELETE RESTRICT;


--
-- Name: celda_confusion celda_confusion_evaluacion_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.celda_confusion
    ADD CONSTRAINT celda_confusion_evaluacion_id_fkey FOREIGN KEY (evaluacion_id) REFERENCES oftalmologia.evaluacion(id) ON DELETE CASCADE;


--
-- Name: consulta consulta_consulta_padre_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta
    ADD CONSTRAINT consulta_consulta_padre_id_fkey FOREIGN KEY (consulta_padre_id) REFERENCES oftalmologia.consulta(id);


--
-- Name: consulta consulta_medico_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta
    ADD CONSTRAINT consulta_medico_id_fkey FOREIGN KEY (medico_id) REFERENCES oftalmologia.medico(usuario_id) ON DELETE RESTRICT;


--
-- Name: consulta consulta_paciente_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta
    ADD CONSTRAINT consulta_paciente_id_fkey FOREIGN KEY (paciente_id) REFERENCES oftalmologia.paciente(usuario_id) ON DELETE RESTRICT;


--
-- Name: consulta consulta_referida_a_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.consulta
    ADD CONSTRAINT consulta_referida_a_fkey FOREIGN KEY (referida_a) REFERENCES oftalmologia.medico(usuario_id);


--
-- Name: diagnostico diagnostico_estudio_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.diagnostico
    ADD CONSTRAINT diagnostico_estudio_id_fkey FOREIGN KEY (estudio_id) REFERENCES oftalmologia.estudio(id) ON DELETE RESTRICT;


--
-- Name: diagnostico diagnostico_medico_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.diagnostico
    ADD CONSTRAINT diagnostico_medico_id_fkey FOREIGN KEY (medico_id) REFERENCES oftalmologia.medico(usuario_id) ON DELETE RESTRICT;


--
-- Name: estudio estudio_consulta_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio
    ADD CONSTRAINT estudio_consulta_id_fkey FOREIGN KEY (consulta_id) REFERENCES oftalmologia.consulta(id) ON DELETE RESTRICT;


--
-- Name: estudio estudio_imagen_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio
    ADD CONSTRAINT estudio_imagen_id_fkey FOREIGN KEY (imagen_id) REFERENCES oftalmologia.imagen(id) ON DELETE RESTRICT;


--
-- Name: estudio estudio_subido_por_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.estudio
    ADD CONSTRAINT estudio_subido_por_fkey FOREIGN KEY (subido_por) REFERENCES oftalmologia.usuario(id) ON DELETE RESTRICT;


--
-- Name: evaluacion evaluacion_conjunto_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.evaluacion
    ADD CONSTRAINT evaluacion_conjunto_id_fkey FOREIGN KEY (conjunto_id) REFERENCES oftalmologia.conjunto_prueba(id) ON DELETE RESTRICT;


--
-- Name: evaluacion evaluacion_modelo_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.evaluacion
    ADD CONSTRAINT evaluacion_modelo_id_fkey FOREIGN KEY (modelo_id) REFERENCES oftalmologia.modelo(id) ON DELETE RESTRICT;


--
-- Name: medico medico_usuario_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.medico
    ADD CONSTRAINT medico_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES oftalmologia.usuario(id) ON DELETE RESTRICT;


--
-- Name: metrica metrica_evaluacion_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.metrica
    ADD CONSTRAINT metrica_evaluacion_id_fkey FOREIGN KEY (evaluacion_id) REFERENCES oftalmologia.evaluacion(id) ON DELETE CASCADE;


--
-- Name: notificacion notificacion_diagnostico_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.notificacion
    ADD CONSTRAINT notificacion_diagnostico_id_fkey FOREIGN KEY (diagnostico_id) REFERENCES oftalmologia.diagnostico(id) ON DELETE RESTRICT;


--
-- Name: notificacion notificacion_usuario_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.notificacion
    ADD CONSTRAINT notificacion_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES oftalmologia.usuario(id) ON DELETE RESTRICT;


--
-- Name: paciente paciente_usuario_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.paciente
    ADD CONSTRAINT paciente_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES oftalmologia.usuario(id) ON DELETE RESTRICT;


--
-- Name: prediccion prediccion_estudio_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion
    ADD CONSTRAINT prediccion_estudio_id_fkey FOREIGN KEY (estudio_id) REFERENCES oftalmologia.estudio(id) ON DELETE RESTRICT;


--
-- Name: prediccion prediccion_modelo_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion
    ADD CONSTRAINT prediccion_modelo_id_fkey FOREIGN KEY (modelo_id) REFERENCES oftalmologia.modelo(id) ON DELETE RESTRICT;


--
-- Name: prediccion_probabilidad prediccion_probabilidad_prediccion_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.prediccion_probabilidad
    ADD CONSTRAINT prediccion_probabilidad_prediccion_id_fkey FOREIGN KEY (prediccion_id) REFERENCES oftalmologia.prediccion(id) ON DELETE CASCADE;


--
-- Name: sesion sesion_usuario_id_fkey; Type: FK CONSTRAINT; Schema: oftalmologia; Owner: -
--

ALTER TABLE ONLY oftalmologia.sesion
    ADD CONSTRAINT sesion_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES oftalmologia.usuario(id) ON DELETE RESTRICT;


--
-- Name: consulta; Type: ROW SECURITY; Schema: oftalmologia; Owner: -
--

ALTER TABLE oftalmologia.consulta ENABLE ROW LEVEL SECURITY;

--
-- Name: diagnostico; Type: ROW SECURITY; Schema: oftalmologia; Owner: -
--

ALTER TABLE oftalmologia.diagnostico ENABLE ROW LEVEL SECURITY;

--
-- Name: estudio; Type: ROW SECURITY; Schema: oftalmologia; Owner: -
--

ALTER TABLE oftalmologia.estudio ENABLE ROW LEVEL SECURITY;

--
-- Name: consulta pol_consulta_actualizacion; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_consulta_actualizacion ON oftalmologia.consulta FOR UPDATE USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
   FROM oftalmologia.v_asignacion_vigente a
  WHERE ((a.paciente_id = consulta.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual())))))) WITH CHECK (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
   FROM oftalmologia.v_asignacion_vigente a
  WHERE ((a.paciente_id = consulta.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))));


--
-- Name: consulta pol_consulta_escritura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_consulta_escritura ON oftalmologia.consulta FOR INSERT WITH CHECK (((oftalmologia.fn_rol_actual() = ANY (ARRAY['medico'::text, 'admin'::text])) OR ((oftalmologia.fn_rol_actual() = 'paciente'::text) AND (paciente_id = oftalmologia.fn_usuario_actual()))));


--
-- Name: consulta pol_consulta_lectura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_consulta_lectura ON oftalmologia.consulta FOR SELECT USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
   FROM oftalmologia.v_asignacion_vigente a
  WHERE ((a.paciente_id = consulta.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))));


--
-- Name: diagnostico pol_diag_actualizacion; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_diag_actualizacion ON oftalmologia.diagnostico FOR UPDATE USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR ((oftalmologia.fn_rol_actual() = 'medico'::text) AND (EXISTS ( SELECT 1
   FROM (oftalmologia.estudio e
     JOIN oftalmologia.consulta c ON ((c.id = e.consulta_id)))
  WHERE ((e.id = diagnostico.estudio_id) AND (EXISTS ( SELECT 1
           FROM oftalmologia.v_asignacion_vigente a
          WHERE ((a.paciente_id = c.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))))))));


--
-- Name: diagnostico pol_diag_escritura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_diag_escritura ON oftalmologia.diagnostico FOR INSERT WITH CHECK (((oftalmologia.fn_rol_actual() = 'medico'::text) AND (medico_id = oftalmologia.fn_usuario_actual())));


--
-- Name: diagnostico pol_diag_lectura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_diag_lectura ON oftalmologia.diagnostico FOR SELECT USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (EXISTS ( SELECT 1
   FROM (oftalmologia.estudio e
     JOIN oftalmologia.consulta c ON ((c.id = e.consulta_id)))
  WHERE ((e.id = diagnostico.estudio_id) AND ((c.paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
           FROM oftalmologia.v_asignacion_vigente a
          WHERE ((a.paciente_id = c.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))))))));


--
-- Name: estudio pol_estudio_actualizacion; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_estudio_actualizacion ON oftalmologia.estudio FOR UPDATE USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (EXISTS ( SELECT 1
   FROM oftalmologia.consulta c
  WHERE ((c.id = estudio.consulta_id) AND ((c.paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
           FROM oftalmologia.v_asignacion_vigente a
          WHERE ((a.paciente_id = c.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))))))));


--
-- Name: estudio pol_estudio_borrado; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_estudio_borrado ON oftalmologia.estudio FOR DELETE USING ((EXISTS ( SELECT 1
   FROM oftalmologia.consulta c
  WHERE ((c.id = estudio.consulta_id) AND (c.paciente_id = oftalmologia.fn_usuario_actual())))));


--
-- Name: estudio pol_estudio_escritura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_estudio_escritura ON oftalmologia.estudio FOR INSERT WITH CHECK (((oftalmologia.fn_rol_actual() = ANY (ARRAY['medico'::text, 'admin'::text])) OR ((oftalmologia.fn_rol_actual() = 'paciente'::text) AND (EXISTS ( SELECT 1
   FROM oftalmologia.consulta c
  WHERE ((c.id = estudio.consulta_id) AND (c.paciente_id = oftalmologia.fn_usuario_actual())))))));


--
-- Name: estudio pol_estudio_lectura; Type: POLICY; Schema: oftalmologia; Owner: -
--

CREATE POLICY pol_estudio_lectura ON oftalmologia.estudio FOR SELECT USING (((oftalmologia.fn_rol_actual() = 'admin'::text) OR (EXISTS ( SELECT 1
   FROM oftalmologia.consulta c
  WHERE ((c.id = estudio.consulta_id) AND ((c.paciente_id = oftalmologia.fn_usuario_actual()) OR (EXISTS ( SELECT 1
           FROM oftalmologia.v_asignacion_vigente a
          WHERE ((a.paciente_id = c.paciente_id) AND (a.medico_id = oftalmologia.fn_usuario_actual()))))))))));


--
-- Name: SCHEMA oftalmologia; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA oftalmologia TO app_lectura;
GRANT USAGE ON SCHEMA oftalmologia TO app_clinica;
GRANT USAGE ON SCHEMA oftalmologia TO app_admin;


--
-- Name: FUNCTION fn_anonimizar_paciente(p_paciente bigint); Type: ACL; Schema: oftalmologia; Owner: -
--

REVOKE ALL ON FUNCTION oftalmologia.fn_anonimizar_paciente(p_paciente bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION oftalmologia.fn_anonimizar_paciente(p_paciente bigint) TO api_backend;


--
-- Name: TABLE asignacion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.asignacion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.asignacion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.asignacion TO app_admin;


--
-- Name: SEQUENCE asignacion_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.asignacion_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.asignacion_id_seq TO app_admin;


--
-- Name: TABLE auditoria; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.auditoria TO app_lectura;
GRANT SELECT ON TABLE oftalmologia.auditoria TO app_clinica;
GRANT SELECT ON TABLE oftalmologia.auditoria TO app_admin;


--
-- Name: SEQUENCE auditoria_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.auditoria_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.auditoria_id_seq TO app_admin;


--
-- Name: TABLE celda_confusion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.celda_confusion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.celda_confusion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.celda_confusion TO app_admin;


--
-- Name: TABLE conjunto_prueba; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.conjunto_prueba TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.conjunto_prueba TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.conjunto_prueba TO app_admin;


--
-- Name: SEQUENCE conjunto_prueba_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.conjunto_prueba_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.conjunto_prueba_id_seq TO app_admin;


--
-- Name: TABLE consulta; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.consulta TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.consulta TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.consulta TO app_admin;


--
-- Name: SEQUENCE consulta_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.consulta_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.consulta_id_seq TO app_admin;


--
-- Name: TABLE diagnostico; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.diagnostico TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.diagnostico TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.diagnostico TO app_admin;


--
-- Name: SEQUENCE diagnostico_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.diagnostico_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.diagnostico_id_seq TO app_admin;


--
-- Name: TABLE estudio; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.estudio TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.estudio TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.estudio TO app_admin;
GRANT DELETE ON TABLE oftalmologia.estudio TO api_backend;


--
-- Name: SEQUENCE estudio_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.estudio_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.estudio_id_seq TO app_admin;


--
-- Name: TABLE evaluacion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.evaluacion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.evaluacion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.evaluacion TO app_admin;


--
-- Name: SEQUENCE evaluacion_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.evaluacion_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.evaluacion_id_seq TO app_admin;


--
-- Name: TABLE imagen; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.imagen TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.imagen TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.imagen TO app_admin;


--
-- Name: SEQUENCE imagen_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.imagen_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.imagen_id_seq TO app_admin;


--
-- Name: TABLE medico; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.medico TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.medico TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.medico TO app_admin;


--
-- Name: TABLE metrica; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.metrica TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.metrica TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.metrica TO app_admin;


--
-- Name: SEQUENCE metrica_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.metrica_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.metrica_id_seq TO app_admin;


--
-- Name: TABLE modelo; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.modelo TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.modelo TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.modelo TO app_admin;


--
-- Name: SEQUENCE modelo_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.modelo_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.modelo_id_seq TO app_admin;


--
-- Name: TABLE notificacion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.notificacion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.notificacion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.notificacion TO app_admin;


--
-- Name: SEQUENCE notificacion_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.notificacion_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.notificacion_id_seq TO app_admin;


--
-- Name: TABLE paciente; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.paciente TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.paciente TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.paciente TO app_admin;


--
-- Name: TABLE prediccion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.prediccion TO app_lectura;
GRANT SELECT,INSERT ON TABLE oftalmologia.prediccion TO app_clinica;
GRANT SELECT,INSERT ON TABLE oftalmologia.prediccion TO app_admin;


--
-- Name: SEQUENCE prediccion_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.prediccion_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.prediccion_id_seq TO app_admin;


--
-- Name: TABLE prediccion_probabilidad; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.prediccion_probabilidad TO app_lectura;
GRANT SELECT,INSERT ON TABLE oftalmologia.prediccion_probabilidad TO app_clinica;
GRANT SELECT,INSERT ON TABLE oftalmologia.prediccion_probabilidad TO app_admin;


--
-- Name: TABLE sesion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.sesion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.sesion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.sesion TO app_admin;


--
-- Name: SEQUENCE sesion_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.sesion_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.sesion_id_seq TO app_admin;


--
-- Name: TABLE usuario; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.usuario TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.usuario TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.usuario TO app_admin;


--
-- Name: SEQUENCE usuario_id_seq; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE oftalmologia.usuario_id_seq TO app_clinica;
GRANT SELECT,USAGE ON SEQUENCE oftalmologia.usuario_id_seq TO app_admin;


--
-- Name: TABLE v_asignacion_vigente; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.v_asignacion_vigente TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_asignacion_vigente TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_asignacion_vigente TO app_admin;


--
-- Name: TABLE v_expediente; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.v_expediente TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_expediente TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_expediente TO app_admin;


--
-- Name: TABLE v_matriz_confusion; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.v_matriz_confusion TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_matriz_confusion TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_matriz_confusion TO app_admin;


--
-- Name: TABLE v_trazabilidad_diagnostico; Type: ACL; Schema: oftalmologia; Owner: -
--

GRANT SELECT ON TABLE oftalmologia.v_trazabilidad_diagnostico TO app_lectura;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_trazabilidad_diagnostico TO app_clinica;
GRANT SELECT,INSERT,UPDATE ON TABLE oftalmologia.v_trazabilidad_diagnostico TO app_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: oftalmologia; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA oftalmologia GRANT SELECT ON TABLES TO app_lectura;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA oftalmologia GRANT SELECT,INSERT,UPDATE ON TABLES TO app_clinica;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA oftalmologia GRANT SELECT,INSERT,UPDATE ON TABLES TO app_admin;


--
-- PostgreSQL database dump complete
--

\unrestrict sW7UaFnDwBjuEodiUZzO0DSFDldgpqyWIRC4ZddEWvA6YHIAEoVstrKeV3Exp24

