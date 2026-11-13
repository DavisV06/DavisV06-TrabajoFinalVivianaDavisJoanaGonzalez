-- Roles de la base de datos. Ejecutar una vez como postgres, ANTES de restaurar el esquema.
-- Cambie la contraseña de api_backend y use la misma en DATABASE_URL de su archivo .env.

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin') THEN CREATE ROLE app_admin NOLOGIN INHERIT; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_clinica') THEN CREATE ROLE app_clinica NOLOGIN INHERIT; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_lectura') THEN CREATE ROLE app_lectura NOLOGIN INHERIT; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_backend') THEN CREATE ROLE api_backend LOGIN PASSWORD 'CAMBIAR_ESTA_CLAVE' INHERIT; END IF; END $$;
GRANT app_clinica TO api_backend;
