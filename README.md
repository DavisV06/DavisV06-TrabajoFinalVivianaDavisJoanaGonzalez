# JYV Oftalmología

Prototipo web de apoyo a la detección de enfermedades oftalmológicas a partir de retinografías. Un modelo ResNet50 clasifica cada imagen en cuatro clases (normal, retinopatía diabética, glaucoma y cataratas); el médico confirma o rectifica el resultado, y médicos y administradores consultan tableros analíticos.

Trabajo de graduación de la Licenciatura en Ingeniería de Sistemas y Computación, Universidad Tecnológica de Panamá (2026). Autoras: Viviana Davis y Joana González. Asesor: José Carlos Rangel Ortiz.

> Los resultados del modelo son una orientación preliminar y no sustituyen la evaluación de un especialista. Todos los datos de la base de demostración son ficticios y las retinografías provienen de conjuntos públicos.

## Qué incluye

| Carpeta o archivo | Contenido |
|---|---|
| `app.py`, `config.py`, `extensions.py`, `models.py` | Aplicativo Flask y modelos de datos (SQLAlchemy) |
| `auth/`, `paciente/`, `medico/`, `admin/` | Rutas de cada tipo de usuario |
| `inference/` | Preprocesamiento (canal verde y Ben Graham), TTA de 8 pasadas e inferencia con ResNet50 |
| `utils/` | Control de acceso y generación del expediente en PDF |
| `templates/`, `static/` | Páginas, estilos, gráficos y retinografías de demostración |
| `database/` | Roles y base de datos de demostración (esquema, seguridad a nivel de fila, auditoría y datos) |

El modelo entrenado (`mejor_rn50.keras`, 241 MB) no está en el repositorio porque supera el límite de GitHub; se descarga desde la sección [Releases](../../releases/latest).

## Requisitos

- Python 3.13
- PostgreSQL 18 (con `psql` en el PATH)
- Unos 2 GB libres para TensorFlow y el modelo. No hace falta tarjeta gráfica: el análisis de una imagen toma menos de un segundo en CPU.

## Instalación

Los comandos son para PowerShell en Windows; en Linux o macOS son equivalentes.

**1. Clonar el repositorio y crear el entorno virtual**

```powershell
git clone <URL-de-este-repositorio>
cd <carpeta-del-repositorio>
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

**2. Descargar el modelo**

Descargue `mejor_rn50.keras` desde [Releases](../../releases/latest) y guárdelo en la carpeta `modelos_tesis3/`.

**3. Crear la base de datos**

Abra `database/01_roles.sql` y cambie `CAMBIAR_ESTA_CLAVE` por una contraseña para el usuario `api_backend`. Luego, como usuario `postgres`:

```powershell
psql -U postgres -f database/01_roles.sql
createdb -U postgres bd_oftalmologia
psql -U postgres -d bd_oftalmologia -v ON_ERROR_STOP=1 -f database/02_bd_oftalmologia.sql
```

**4. Configurar el aplicativo**

```powershell
Copy-Item .env.example .env
```

En `.env`, ponga en `DATABASE_URL` la contraseña que eligió para `api_backend` y cambie `SECRET_KEY` por una cadena larga y aleatoria.

**5. Ejecutar**

```powershell
python app.py
```

Abra <http://localhost:5000>. El primer arranque tarda unos segundos mientras se carga el modelo.

## Cuentas de demostración

Todas usan la contraseña `Demo2026!`.

| Rol | Correo |
|---|---|
| Administrador | `admin@prueba.com` |
| Médico | `carlos.mendez@prueba.com` |
| Paciente | `paciente.demo@example.com` |

Al entrar por primera vez, el sistema pide aceptar el aviso de privacidad (Ley 81 de 2019); después muestra el panel de cada rol. También puede registrar un paciente nuevo desde la pantalla de inicio de sesión.

## Recorrido sugerido

1. **Paciente:** agende una cita y cargue una retinografía de cada ojo. Puede usar imágenes de los conjuntos públicos indicados abajo. El resultado del modelo aparece en «Mis estudios» como pendiente de revisión médica.
2. **Médico** (el que eligió en la cita): abra la consulta, confirme o rectifique el diagnóstico y revise «Mis estadísticas».
3. **Administrador:** revise el resumen general, la concordancia entre el modelo y los médicos, los tableros analíticos y el registro de auditoría.

## Datos de entrenamiento

Los modelos se entrenaron con conjuntos públicos de Kaggle, que no se incluyen en este repositorio:

- ODIR-5K: `andrewmvd/ocular-disease-recognition-odir5k`
- Diagnosis of Diabetic Retinopathy: `pkdarabi/diagnosis-of-diabetic-retinopathy`
- SMDG-19: `deathtrooper/multichannel-glaucoma-benchmark-dataset`
- Eye Diseases Classification: `gunavenkatdoddi/eye-diseases-classification`
- Cataract (solo validación externa): `tambowyer/cataract`
