-- =============================================================================
-- 03_eda.sql — Proyecto Final SQL: limpieza (verificación), EDA y análisis
-- Motor: PostgreSQL 15. Ejecutar DESPUÉS de 01_schema.sql y 02_data.sql.
-- Este es el CORE del entregable: detección de calidad + perfil descriptivo +
-- 10 consultas de negocio, cada una comentada con el insight que aporta.
-- (La CORRECCIÓN de los problemas se hizo en 02_data.sql; aquí los DETECTAMOS
--  sobre la capa staging cruda para evidenciar las técnicas.)
-- =============================================================================


-- #############################################################################
-- SECCIÓN A — CALIDAD DE DATOS (detección sobre staging crudo)
-- #############################################################################

-- A1. NULOS: lotes sin operador en el dato crudo (luego → centinela -1 en 02).
--     Insight: medir el % de registros sin login antes de imputar.
SELECT COUNT(*) AS lotes_sin_operador
FROM stg_productividad
WHERE operador_txt IS NULL;

-- A2. DUPLICADOS: detección con GROUP BY + COUNT(*) (regla: lote_txt es único).
--     Insight: el nº de batch debe ser único; aquí afloran los registros dobles.
SELECT lote_txt, COUNT(*) AS repeticiones
FROM stg_productividad
GROUP BY lote_txt
HAVING COUNT(*) > 1
ORDER BY lote_txt;

-- A3. TIPOS/FECHAS INCORRECTAS: el fin de lote debería ser 'HH:MM:SS' (8 chars).
--     Insight: detecta el lote cuyo fin trae fecha basura '1900-01-01 ...'
--     (cruce de medianoche), corregido en 02 con RIGHT(fin_txt,8).
SELECT lote_txt, fin_txt
FROM stg_productividad
WHERE LENGTH(fin_txt) <> 8;

-- A4. INTEGRIDAD REFERENCIAL: lotes con paros pero sin registro de producción.
--     Insight: huérfanos 422137-422143 → excluidos de fact_paros en 02 (LEFT JOIN + IS NULL).
SELECT s.lote_txt AS lote_huerfano
FROM stg_downtime s
LEFT JOIN stg_productividad pr ON pr.lote_txt = s.lote_txt
WHERE pr.lote_txt IS NULL
GROUP BY s.lote_txt
ORDER BY s.lote_txt;


-- #############################################################################
-- SECCIÓN B — EDA Y CONSULTAS DE NEGOCIO (10)
-- #############################################################################

-- -----------------------------------------------------------------------------
-- Q1. PERFIL DE DATOS del modelo limpio: volumen, rango temporal, % sin operador.
--     Técnicas: COUNT, MIN/MAX, agregación con FILTER.
--     Insight: tamaño y cobertura del dataset, y qué fracción quedó sin operador.
-- -----------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM fact_lotes)                               AS total_lotes,
    (SELECT COUNT(*) FROM fact_paros)                               AS total_registros_paro,
    MIN(c.fecha)                                                    AS desde,
    MAX(c.fecha)                                                    AS hasta,
    ROUND(100.0 * COUNT(*) FILTER (WHERE l.operador_id = -1)
                / COUNT(*), 1)                                      AS pct_sin_operador,
    ROUND(AVG(l.duracion_min), 1)                                   AS duracion_media_min
FROM fact_lotes l
JOIN dim_calendario c ON c.fecha_id = l.fecha_id;

-- -----------------------------------------------------------------------------
-- Q2. PRODUCCIÓN Y PARO por producto y mes.
--     Técnicas: 2 INNER JOIN (producto, calendario) + LEFT JOIN (paro) +
--               GROUP BY + SUM + COUNT + función de fecha DATE_TRUNC.
--     Insight: qué producto concentra producción y cuánto paro arrastra.
-- -----------------------------------------------------------------------------
SELECT
    p.codigo                                          AS producto,
    TO_CHAR(DATE_TRUNC('month', c.fecha), 'YYYY-MM')  AS mes,
    COUNT(DISTINCT l.lote_id)                         AS lotes,
    COALESCE(SUM(par.minutos), 0)                     AS min_paro_total
FROM fact_lotes l
JOIN dim_producto   p ON p.producto_id = l.producto_id     -- INNER 1
JOIN dim_calendario c ON c.fecha_id    = l.fecha_id        -- INNER 2
LEFT JOIN fact_paros par ON par.lote_id = l.lote_id        -- LEFT (paro opcional)
GROUP BY p.codigo, DATE_TRUNC('month', c.fecha)
ORDER BY min_paro_total DESC;

-- -----------------------------------------------------------------------------
-- Q3. DÍAS LABORABLES SIN PRODUCCIÓN.
--     Técnicas: LEFT JOIN dim_calendario ← fact_lotes + IS NULL.
--     Insight: huecos de actividad en días hábiles (capacidad ociosa).
-- -----------------------------------------------------------------------------
SELECT c.fecha, c.dia_semana
FROM dim_calendario c
LEFT JOIN fact_lotes l ON l.fecha_id = c.fecha_id
WHERE c.es_laborable = TRUE
  AND l.lote_id IS NULL
ORDER BY c.fecha;

-- -----------------------------------------------------------------------------
-- Q4. EFICIENCIA POR LOTE + SEMÁFORO.
--     Técnicas: vista v_eficiencia_lote + CASE (lógica condicional).
--     Insight: clasifica cada lote (Óptimo/Aceptable/Crítico) según eficiencia.
-- -----------------------------------------------------------------------------
SELECT
    lote_id, fecha, producto, operador,
    duracion_min, min_batch_time, eficiencia_pct, minutos_paro,
    CASE WHEN eficiencia_pct >= 90 THEN 'Óptimo'
         WHEN eficiencia_pct >= 70 THEN 'Aceptable'
         ELSE 'Crítico' END AS semaforo
FROM v_eficiencia_lote
ORDER BY eficiencia_pct ASC;

-- -----------------------------------------------------------------------------
-- Q5. PARETO DE MOTIVOS DE PARO (regla 80/20).
--     Técnicas: CTE + funciones ventana SUM() OVER () y acumulado OVER (ORDER BY).
--     Insight: pocos factores explican la mayor parte del paro → dónde priorizar.
-- -----------------------------------------------------------------------------
WITH paros AS (
    SELECT f.descripcion, f.es_error_operador, SUM(p.minutos) AS min_total
    FROM fact_paros p
    JOIN dim_factor_paro f ON f.factor_id = p.factor_id
    GROUP BY f.descripcion, f.es_error_operador
)
SELECT
    descripcion,
    CASE WHEN es_error_operador THEN 'Operador' ELSE 'Proceso/Máquina' END AS tipo,
    min_total,
    ROUND(100.0 * min_total / SUM(min_total) OVER (), 1)                          AS pct,
    ROUND(100.0 * SUM(min_total) OVER (ORDER BY min_total DESC)
                / SUM(min_total) OVER (), 1)                                      AS pct_acumulado
FROM paros
ORDER BY min_total DESC;

-- -----------------------------------------------------------------------------
-- Q6. MTBF (proxy) — tiempo entre fallos de máquina.
--     Técnicas: CTEs ENCADENADAS + función ventana LAG().
--     Definición: "fallo" = lote con paro de tipo 'Machine failure' (factor 7).
--     CAVEAT: gaps en tiempo de CALENDARIO (incluyen noches/fin de semana sin
--             producción) → MTBF orientativo, no horas de operación netas.
--     Insight: cada cuánto, en promedio, reaparece un fallo de máquina.
-- -----------------------------------------------------------------------------
WITH fallos AS (                       -- CTE 1: lotes con fallo de máquina, ordenados
    SELECT DISTINCT l.lote_id, l.hora_inicio
    FROM fact_lotes l
    JOIN fact_paros p      ON p.lote_id   = l.lote_id
    JOIN dim_factor_paro f ON f.factor_id = p.factor_id
    WHERE f.descripcion = 'Machine failure'
),
intervalos AS (                        -- CTE 2: gap respecto al fallo anterior con LAG
    SELECT
        lote_id,
        hora_inicio,
        LAG(hora_inicio) OVER (ORDER BY hora_inicio) AS fallo_anterior,
        ROUND(EXTRACT(EPOCH FROM
              (hora_inicio - LAG(hora_inicio) OVER (ORDER BY hora_inicio))) / 3600.0, 1)
              AS horas_entre_fallos
    FROM fallos
)
SELECT
    lote_id, hora_inicio, fallo_anterior, horas_entre_fallos,
    ROUND(AVG(horas_entre_fallos) OVER (), 1) AS mtbf_horas_promedio
FROM intervalos
ORDER BY hora_inicio;

-- -----------------------------------------------------------------------------
-- Q7. RANKING DE OPERADORES por eficiencia media.
--     Técnicas: función ventana RANK() OVER + AVG + GROUP BY.
--     Insight: quién opera más cerca del tiempo estándar (mejor desempeño).
-- -----------------------------------------------------------------------------
SELECT
    operador,
    COUNT(*)                                          AS lotes,
    ROUND(AVG(eficiencia_pct), 1)                     AS eficiencia_media,
    RANK() OVER (ORDER BY AVG(eficiencia_pct) DESC)   AS ranking
FROM v_eficiencia_lote
WHERE operador <> 'SIN_ASIGNAR'
GROUP BY operador
ORDER BY ranking;

-- -----------------------------------------------------------------------------
-- Q8. LOTES CON PARO SOBRE LA MEDIA DE SU PRODUCTO.
--     Técnicas: SUBQUERY CORRELACIONADA (referencia al producto de la fila externa).
--     Insight: lotes anómalos respecto a su propia categoría → revisar.
-- -----------------------------------------------------------------------------
WITH lp AS (
    SELECT l.lote_id, l.producto_id, COALESCE(SUM(p.minutos), 0) AS min_paro
    FROM fact_lotes l
    LEFT JOIN fact_paros p ON p.lote_id = l.lote_id
    GROUP BY l.lote_id, l.producto_id
)
SELECT pr.codigo AS producto, lp.lote_id, lp.min_paro
FROM lp
JOIN dim_producto pr ON pr.producto_id = lp.producto_id
WHERE lp.min_paro > (
        SELECT AVG(lp2.min_paro)
        FROM lp lp2
        WHERE lp2.producto_id = lp.producto_id           -- correlación con la fila externa
      )
ORDER BY producto, lp.min_paro DESC;

-- -----------------------------------------------------------------------------
-- Q9. TENDENCIA: media móvil de minutos de paro (ventana de 5 lotes).
--     Técnicas: función ventana con frame ROWS BETWEEN 4 PRECEDING AND CURRENT ROW.
--     (Ventana de LOTES, no de días, por la corta duración real del periodo.)
--     Insight: detecta el repunte de paro en los lotes finales (formato 2L).
-- -----------------------------------------------------------------------------
WITH paro_por_lote AS (
    SELECT l.lote_id, l.hora_inicio, COALESCE(SUM(p.minutos), 0) AS min_paro
    FROM fact_lotes l
    LEFT JOIN fact_paros p ON p.lote_id = l.lote_id
    GROUP BY l.lote_id, l.hora_inicio
)
SELECT
    lote_id,
    hora_inicio,
    min_paro,
    ROUND(AVG(min_paro) OVER (ORDER BY hora_inicio
              ROWS BETWEEN 4 PRECEDING AND CURRENT ROW), 1) AS media_movil_5
FROM paro_por_lote
ORDER BY hora_inicio;

-- -----------------------------------------------------------------------------
-- Q10. EFICIENCIA NORMALIZADA por operador (índice vs media de la línea).
--      Técnicas: JOIN + CAST (::NUMERIC) + división segura con NULLIF.
--      Insight: índice 100 = media de la línea; >100 mejor, <100 peor.
-- -----------------------------------------------------------------------------
WITH ef AS (
    SELECT
        l.operador_id,
        AVG(p.min_batch_time::NUMERIC / NULLIF(l.duracion_min, 0)) AS efic
    FROM fact_lotes l
    JOIN dim_producto p ON p.producto_id = l.producto_id
    WHERE l.operador_id <> -1
    GROUP BY l.operador_id
)
SELECT
    o.nombre                                                       AS operador,
    ROUND(100.0 * ef.efic, 1)                                      AS eficiencia_pct,
    ROUND(100.0 * ef.efic / NULLIF((SELECT AVG(efic) FROM ef), 0), 1) AS indice_vs_media
FROM ef
JOIN dim_operador o ON o.operador_id = ef.operador_id
ORDER BY indice_vs_media DESC;

-- =============================================================================
-- Fin de 03_eda.sql
-- =============================================================================
