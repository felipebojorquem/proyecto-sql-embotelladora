-- =============================================================================
-- 01_schema.sql — Proyecto Final SQL: Línea de embotellado (modelo estrella)
-- Motor: PostgreSQL 15
-- Ejecutar primero. Carga de datos en 02_data.sql; análisis en 03_eda.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Limpieza:
-- -----------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS v_pareto_paros;
DROP VIEW IF EXISTS v_eficiencia_lote;
DROP FUNCTION IF EXISTS fn_eficiencia_periodo(DATE, DATE);

DROP TABLE IF EXISTS fact_paros      CASCADE;
DROP TABLE IF EXISTS fact_lotes      CASCADE;
DROP TABLE IF EXISTS dim_calendario  CASCADE;
DROP TABLE IF EXISTS dim_producto    CASCADE;
DROP TABLE IF EXISTS dim_operador    CASCADE;
DROP TABLE IF EXISTS dim_turno       CASCADE;
DROP TABLE IF EXISTS dim_factor_paro CASCADE;

-- =============================================================================
-- 1. DIMENSIONES:
-- =============================================================================

-- dim_calendario: clave NATURAL fecha_id (YYYYMMDD)
CREATE TABLE dim_calendario (
    fecha_id     INT         PRIMARY KEY,                 -- PK natural: 20240829
    fecha        DATE        NOT NULL UNIQUE,             -- UNIQUE: una fila por día
    dia_semana   VARCHAR(10),
    semana       SMALLINT,
    mes          SMALLINT,
    anio         SMALLINT,
    es_laborable BOOLEAN     NOT NULL DEFAULT TRUE        -- DEFAULT: la mayoría son laborables
);

-- dim_producto: clave SURROGATE (convención de modelado dimensional).
CREATE TABLE dim_producto (
    producto_id    INT     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo         VARCHAR(10) NOT NULL UNIQUE,           -- CO-2L, OR-600...
    sabor          VARCHAR(30),
    tamano         VARCHAR(10),
    min_batch_time INT     NOT NULL CHECK (min_batch_time > 0)  -- tiempo estándar del lote (min)
);

-- dim_operador: PK manual (no IDENTITY) porque insertamos el centinela -1
-- ('SIN_ASIGNAR') para los lotes sin operador logueado (nulos legítimos).
CREATE TABLE dim_operador (
    operador_id   INT         PRIMARY KEY,
    nombre        VARCHAR(50) NOT NULL UNIQUE,
    especialidad  VARCHAR(50),
    fecha_ingreso DATE
);

-- dim_turno: dimensión derivada de la hora de inicio del lote (Mañana/Tarde/Noche).
CREATE TABLE dim_turno (
    turno_id    INT         PRIMARY KEY,
    nombre      VARCHAR(20) NOT NULL,
    hora_inicio TIME,
    hora_fin    TIME
);

-- dim_factor_paro: clave NATURAL (factor 1..12 es un catálogo cerrado que ya
-- viene con id en el CSV). es_error_operador mapea el campo Operator Error (Yes/No).
CREATE TABLE dim_factor_paro (
    factor_id         INT         PRIMARY KEY,
    descripcion       VARCHAR(60) NOT NULL,
    es_error_operador BOOLEAN     NOT NULL
);

-- =============================================================================
-- 2. HECHOS:
-- =============================================================================

-- fact_lotes: granularidad = 1 fila por lote producido.
CREATE TABLE fact_lotes (
    lote_id      BIGINT    PRIMARY KEY,                              -- nº de batch (ej. 422144)
    fecha_id     INT       NOT NULL REFERENCES dim_calendario(fecha_id),
    producto_id  INT       NOT NULL REFERENCES dim_producto(producto_id),
    operador_id  INT       REFERENCES dim_operador(operador_id),     -- NULL a propósito (calidad de datos)
    turno_id     INT       NOT NULL REFERENCES dim_turno(turno_id),
    hora_inicio  TIMESTAMP NOT NULL,
    hora_fin     TIMESTAMP NOT NULL,
    duracion_min INT       NOT NULL CHECK (duracion_min > 0),        -- derivada = fin - inicio (corrigiendo medianoche)
    CONSTRAINT chk_lotes_orden_horas CHECK (hora_fin > hora_inicio)  -- integridad temporal del lote
);

-- fact_paros: granularidad = 1 fila por lote × factor de paro (tras unpivot).
CREATE TABLE fact_paros (
    paro_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lote_id   BIGINT NOT NULL REFERENCES fact_lotes(lote_id),
    factor_id INT    NOT NULL REFERENCES dim_factor_paro(factor_id),
    minutos   INT    NOT NULL CHECK (minutos BETWEEN 0 AND 600)      -- rechaza outliers tipo 999
);

-- =============================================================================
-- 3. ÍNDICES
-- =============================================================================

-- Índice principal: el Pareto de paros y las agregaciones por lote unen/agrupan
-- fact_paros por (lote_id, factor_id).
CREATE INDEX idx_paros_lote_factor ON fact_paros (lote_id, factor_id);

-- Índice de apoyo temporal: las consultas de producción por fecha/mes y los
-- LEFT JOIN con dim_calendario filtran/ordenan por fecha_id.
CREATE INDEX idx_lotes_fecha ON fact_lotes (fecha_id);

-- =============================================================================
-- 4. VISTAS
-- =============================================================================

-- VISTA 1 (normal): eficiencia por lote = tiempo estándar / tiempo real.
-- Une fact_lotes con dim_producto (tiempo estándar), calendario y operador,
-- y agrega los minutos de paro del lote con LEFT JOIN (un lote puede no tener paros).
CREATE OR REPLACE VIEW v_eficiencia_lote AS
SELECT
    l.lote_id,
    c.fecha,
    p.codigo                                  AS producto,
    COALESCE(o.nombre, 'SIN_ASIGNAR')         AS operador,
    l.duracion_min,
    p.min_batch_time,
    ROUND(100.0 * p.min_batch_time / NULLIF(l.duracion_min, 0), 1) AS eficiencia_pct,
    COALESCE(SUM(par.minutos), 0)             AS minutos_paro
FROM fact_lotes l
JOIN dim_calendario c ON c.fecha_id    = l.fecha_id
JOIN dim_producto   p ON p.producto_id = l.producto_id
LEFT JOIN dim_operador o ON o.operador_id = l.operador_id
LEFT JOIN fact_paros par ON par.lote_id   = l.lote_id
GROUP BY l.lote_id, c.fecha, p.codigo, o.nombre, l.duracion_min, p.min_batch_time;

-- VISTA 2 (MATERIALIZADA): Pareto de motivos de paro. Usa funciones ventana
-- para el % individual y el % acumulado (regla 80/20).
CREATE MATERIALIZED VIEW v_pareto_paros AS
WITH paros_por_factor AS (                                   -- CTE: minutos por factor
    SELECT
        f.factor_id,
        f.descripcion,
        f.es_error_operador,
        SUM(par.minutos) AS minutos_total
    FROM fact_paros par
    JOIN dim_factor_paro f ON f.factor_id = par.factor_id
    GROUP BY f.factor_id, f.descripcion, f.es_error_operador
)
SELECT
    factor_id,
    descripcion,
    es_error_operador,
    minutos_total,
    ROUND(100.0 * minutos_total / SUM(minutos_total) OVER (), 1) AS pct,
    ROUND(100.0 * SUM(minutos_total) OVER (ORDER BY minutos_total DESC)
                / SUM(minutos_total) OVER (), 1)                 AS pct_acumulado
FROM paros_por_factor
ORDER BY minutos_total DESC
WITH DATA;

-- =============================================================================
-- 5. FUNCIÓN
--    LANGUAGE sql (no plpgsql): el cuerpo es una sola query con parámetros,
--    el planner puede inlinearla. Devuelve el % de eficiencia agregada de la
--    línea en un rango de fechas.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_eficiencia_periodo(desde DATE, hasta DATE)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT ROUND(100.0 * SUM(p.min_batch_time) / NULLIF(SUM(l.duracion_min), 0), 1)
    FROM fact_lotes l
    JOIN dim_producto   p ON p.producto_id = l.producto_id
    JOIN dim_calendario c ON c.fecha_id    = l.fecha_id
    WHERE c.fecha BETWEEN desde AND hasta;
$$;
