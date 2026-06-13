-- =============================================================================
-- 02_data.sql — Proyecto Final SQL: carga de datos y limpieza
-- Motor: PostgreSQL 15. Ejecutar DESPUÉS de 01_schema.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Idempotencia: limpieza de staging y hechos (reinicio de secuencias).
-- -----------------------------------------------------------------------------
TRUNCATE fact_paros, fact_lotes RESTART IDENTITY;
TRUNCATE dim_calendario, dim_producto, dim_operador, dim_turno, dim_factor_paro RESTART IDENTITY CASCADE;

DROP TABLE IF EXISTS stg_productividad;
DROP TABLE IF EXISTS stg_productos;
DROP TABLE IF EXISTS stg_factores;
DROP TABLE IF EXISTS stg_downtime;

-- Staging: TODO como TEXT → simula la carga cruda de un CSV y obliga
-- a una conversión de tipos explícita (CAST) al pasar al modelo dimensional.
CREATE TABLE stg_productividad (
    fecha_txt    TEXT, producto_txt TEXT, lote_txt TEXT,
    operador_txt TEXT, inicio_txt   TEXT, fin_txt  TEXT
);
CREATE TABLE stg_productos (
    producto_txt TEXT, sabor_txt TEXT, tamano_txt TEXT, min_batch_txt TEXT
);
CREATE TABLE stg_factores (
    factor_txt TEXT, descripcion_txt TEXT, error_operador_txt TEXT
);
CREATE TABLE stg_downtime (                 -- formato ANCHO (1 columna por factor)
    lote_txt TEXT,
    f1_txt TEXT, f2_txt TEXT, f3_txt TEXT, f4_txt TEXT, f5_txt TEXT, f6_txt TEXT,
    f7_txt TEXT, f8_txt TEXT, f9_txt TEXT, f10_txt TEXT, f11_txt TEXT, f12_txt TEXT
);

-- =============================================================================
-- 1. Carga cruda en staging (valores reales del dataset, embebidos por código)
-- =============================================================================

-- stg_productividad (31 filas)
INSERT INTO stg_productividad (fecha_txt, producto_txt, lote_txt, operador_txt, inicio_txt, fin_txt) VALUES
('2024-08-29','OR-600','422111','Mac','11:50:00','14:05:00'),
('2024-08-29','LE-600','422112','Mac','14:05:00','15:45:00'),
('2024-08-29','LE-600','422113','Mac','15:45:00','17:35:00'),
('2024-08-29','LE-600','422114','Mac','17:35:00','19:15:00'),
('2024-08-29','LE-600','422115','Charlie','19:15:00','20:39:00'),
('2024-08-29','LE-600','422116','Charlie','20:39:00','21:39:00'),
('2024-08-29','LE-600','422117','Charlie','21:39:00','22:54:00'),
('2024-08-30','CO-600','422118','Dee','04:05:00','06:05:00'),
('2024-08-30','CO-600','422119','Dee','06:05:00','07:30:00'),
('2024-08-30','CO-600','422120','Dee','07:30:00','09:22:00'),
('2024-08-30','CO-600','422121','Dennis','09:22:00','10:37:00'),
('2024-08-30','CO-600','422122','Dennis','10:37:00','12:02:00'),
('2024-08-30','CO-600','422123','Dennis','12:02:00','14:15:00'),
('2024-08-30','CO-600','422124','Dennis','14:15:00','15:55:00'),
('2024-08-30','CO-600','422125','Charlie','15:55:00','17:15:00'),
('2024-08-30','CO-600','422126','Charlie','17:15:00','18:59:00'),
('2024-08-30','CO-600','422127','Charlie','18:59:00','20:22:00'),
('2024-08-30','CO-600','422128','Charlie','20:22:00','22:14:00'),
('2024-08-30','CO-600','422129','Charlie','22:14:00','23:29:00'),
('2024-08-31','CO-600','422130','Dee','07:45:00','09:05:00'),
('2024-08-31','CO-600','422131','Dee','09:05:00','10:35:00'),
('2024-08-31','CO-600','422132','Dee','10:35:00','11:35:00'),
('2024-08-31','DC-600','422133','Dee','11:35:00','12:55:00'),
('2024-08-31','DC-600','422134','Mac','12:55:00','14:45:00'),
('2024-08-31','DC-600','422135','Mac','14:45:00','16:30:00'),
('2024-08-31','DC-600','422136','Mac','16:30:00','17:30:00'),
('2024-09-02','CO-2L','422144','Dennis','12:18:00','14:50:00'),
('2024-09-02','CO-2L','422145','Charlie','14:50:00','16:50:00'),
('2024-09-02','CO-2L','422146','Charlie','16:50:00','19:30:00'),
('2024-09-02','CO-2L','422147','Charlie','19:30:00','22:55:00'),
('2024-09-03','CO-2L','422148','Mac','22:55:00','1900-01-01 01:05:00'); -- fin cruza medianoche (fecha basura)

-- stg_productos (5) 
INSERT INTO stg_productos (producto_txt, sabor_txt, tamano_txt, min_batch_txt) VALUES
('OR-600','Orange','600 ml','60'),
('LE-600','Lemon lime','600 ml','60'),
('CO-600','Cola','600 ml','60'),
('DC-600','Diet Cola','600 ml','60'),
('CO-2L','Cola','2 L','98');

-- stg_factores (12)
INSERT INTO stg_factores (factor_txt, descripcion_txt, error_operador_txt) VALUES
('1','Emergency stop','No'),
('2','Batch change','Yes'),
('3','Labeling error','No'),
('4','Inventory shortage','No'),
('5','Product spill','Yes'),
('6','Machine adjustment','Yes'),
('7','Machine failure','No'),
('8','Batch coding error','Yes'),
('9','Conveyor belt jam','No'),
('10','Calibration error','Yes'),
('11','Label switch','Yes'),
('12','Other','No');

-- stg_downtime (38 filas, formato ancho; los lotes 422137-422143 son
--       huérfanos: tienen paros pero NO existen en productividad)
INSERT INTO stg_downtime (lote_txt,f1_txt,f2_txt,f3_txt,f4_txt,f5_txt,f6_txt,f7_txt,f8_txt,f9_txt,f10_txt,f11_txt,f12_txt) VALUES
('422111',NULL,'60.0',NULL,NULL,NULL,NULL,'15.0',NULL,NULL,NULL,NULL,NULL),
('422112',NULL,'20.0',NULL,NULL,NULL,NULL,NULL,'20.0',NULL,NULL,NULL,NULL),
('422113',NULL,'50.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422114',NULL,NULL,NULL,'25.0',NULL,'15.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422115',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'24.0',NULL,NULL),
('422116',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422117',NULL,'10.0',NULL,NULL,NULL,'5.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422118',NULL,NULL,NULL,NULL,NULL,'14.0','16.0',NULL,NULL,NULL,'10.0','20.0'),
('422119',NULL,NULL,NULL,'25.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422120',NULL,NULL,NULL,'20.0','15.0',NULL,NULL,NULL,'17.0',NULL,NULL,NULL),
('422121',NULL,NULL,NULL,NULL,NULL,NULL,'15.0',NULL,NULL,NULL,NULL,NULL),
('422122',NULL,NULL,NULL,NULL,NULL,NULL,'25.0',NULL,NULL,NULL,NULL,NULL),
('422123',NULL,NULL,NULL,'43.0',NULL,NULL,'30.0',NULL,NULL,NULL,NULL,NULL),
('422124',NULL,NULL,NULL,NULL,'20.0','20.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422125',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'10.0','10.0'),
('422126',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'44.0',NULL,NULL,NULL,NULL),
('422127',NULL,NULL,NULL,NULL,NULL,'23.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422128',NULL,NULL,NULL,NULL,'22.0',NULL,'30.0',NULL,NULL,NULL,NULL,NULL),
('422129',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'15.0'),
('422130',NULL,'20.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422131',NULL,NULL,NULL,'20.0',NULL,NULL,NULL,NULL,NULL,'10.0',NULL,NULL),
('422132',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422133',NULL,NULL,NULL,NULL,NULL,NULL,'20.0',NULL,NULL,NULL,NULL,NULL),
('422134',NULL,NULL,NULL,NULL,NULL,NULL,'30.0','20.0',NULL,NULL,NULL,NULL),
('422135',NULL,NULL,NULL,'30.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'15.0'),
('422136',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422137',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'30.0',NULL,'15.0',NULL,NULL),
('422138',NULL,NULL,'20.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422139',NULL,NULL,NULL,'20.0',NULL,'15.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422140',NULL,NULL,NULL,NULL,NULL,'50.0',NULL,NULL,NULL,NULL,'13.0',NULL),
('422141',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'7.0'),
('422142',NULL,NULL,NULL,NULL,NULL,'30.0',NULL,NULL,NULL,NULL,NULL,NULL),
('422143',NULL,NULL,NULL,NULL,NULL,'40.0','18.0',NULL,NULL,NULL,NULL,NULL),
('422144',NULL,NULL,NULL,NULL,NULL,'30.0',NULL,'24.0',NULL,NULL,NULL,NULL),
('422145',NULL,NULL,'22.0',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
('422146',NULL,NULL,NULL,NULL,NULL,'30.0','25.0',NULL,NULL,NULL,NULL,'7.0'),
('422147',NULL,NULL,NULL,'17.0',NULL,'60.0','30.0',NULL,NULL,NULL,NULL,NULL),
('422148',NULL,NULL,NULL,'25.0',NULL,NULL,NULL,'7.0',NULL,NULL,NULL,NULL);

-- =============================================================================
-- 2. ERRORES SEMBRADOS:
-- =============================================================================
-- 2a. Nulos: 3 lotes pierden el operador (registro sin login en planta).
UPDATE stg_productividad SET operador_txt = NULL
WHERE lote_txt IN ('422116','422125','422132');

-- 2b. Duplicados exactos: re-insertamos 2 lotes tal cual (doble registro).
INSERT INTO stg_productividad
SELECT * FROM stg_productividad WHERE lote_txt IN ('422111','422120');

-- =============================================================================
-- 3. CARGA DE DIMENSIONES
-- =============================================================================

-- dim_calendario: generada con generate_series sobre 2 semanas completas que
-- cubren el periodo (no solo los días observados). 
INSERT INTO dim_calendario (fecha_id, fecha, dia_semana, semana, mes, anio, es_laborable)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INT,
    d::DATE,
    TRIM(TO_CHAR(d, 'TMDay')),
    EXTRACT(week  FROM d)::INT,
    EXTRACT(month FROM d)::INT,
    EXTRACT(year  FROM d)::INT,
    EXTRACT(dow FROM d) NOT IN (0, 6)            -- domingo(0)/sábado(6) → no laborable
FROM generate_series(DATE '2024-08-26', DATE '2024-09-08', INTERVAL '1 day') AS g(d);

-- dim_producto: surrogate (IDENTITY) + código de negocio como UNIQUE. 
INSERT INTO dim_producto (codigo, sabor, tamano, min_batch_time)
SELECT producto_txt, sabor_txt, tamano_txt, min_batch_txt::INT
FROM stg_productos;

-- dim_factor_paro: clave natural (1..12). El booleano se deriva del 'Yes'/'No'.
INSERT INTO dim_factor_paro (factor_id, descripcion, es_error_operador)
SELECT factor_txt::INT, descripcion_txt, (error_operador_txt = 'Yes')
FROM stg_factores;

-- dim_operador: centinela -1 (SIN_ASIGNAR) + operadores reales. 
INSERT INTO dim_operador (operador_id, nombre, especialidad, fecha_ingreso) VALUES
(-1, 'SIN_ASIGNAR', NULL,                  NULL),
( 1, 'Mac',         'Operador de línea',   DATE '2021-03-15'),
( 2, 'Charlie',     'Operador de línea',   DATE '2022-07-01'),
( 3, 'Dee',         'Supervisor de turno', DATE '2020-11-20'),
( 4, 'Dennis',      'Operador de línea',   DATE '2023-01-10');

-- dim_turno: catálogo fijo. El turno de cada lote se deriva de la hora de inicio.
INSERT INTO dim_turno (turno_id, nombre, hora_inicio, hora_fin) VALUES
(1, 'Mañana', TIME '06:00', TIME '14:00'),
(2, 'Tarde',  TIME '14:00', TIME '22:00'),
(3, 'Noche',  TIME '22:00', TIME '06:00');

-- =============================================================================
-- 4. CARGA DE HECHOS
-- =============================================================================

BEGIN;

-- fact_lotes: limpieza + transformación en CTEs encadenadas:
--   dedup  → elimina los duplicados sembrados con ROW_NUMBER (se queda rn=1)
--   base   → CAST de fecha/horas; reconstruye hora_fin tomando solo HH:MM:SS
--   fix    → corrige el cruce de medianoche (+1 día si fin <= inicio)
WITH dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY lote_txt ORDER BY lote_txt) AS rn
    FROM stg_productividad
),
base AS (
    SELECT
        lote_txt::BIGINT                              AS lote_id,
        fecha_txt::DATE                               AS fecha,
        producto_txt,
        operador_txt,
        (fecha_txt::DATE + inicio_txt::TIME)          AS hora_inicio,
        (fecha_txt::DATE + RIGHT(fin_txt, 8)::TIME)   AS hora_fin_raw
    FROM dedup
    WHERE rn = 1
),
fix AS (
    SELECT lote_id, fecha, producto_txt, operador_txt, hora_inicio,
           CASE WHEN hora_fin_raw <= hora_inicio
                THEN hora_fin_raw + INTERVAL '1 day'
                ELSE hora_fin_raw END                 AS hora_fin
    FROM base
)
INSERT INTO fact_lotes (lote_id, fecha_id, producto_id, operador_id, turno_id,
                        hora_inicio, hora_fin, duracion_min)
SELECT
    f.lote_id,
    TO_CHAR(f.fecha, 'YYYYMMDD')::INT,
    p.producto_id,
    o.operador_id,                                    -- NULL si el operador fue sembrado nulo
    CASE WHEN EXTRACT(hour FROM f.hora_inicio) >= 6  AND EXTRACT(hour FROM f.hora_inicio) < 14 THEN 1
         WHEN EXTRACT(hour FROM f.hora_inicio) >= 14 AND EXTRACT(hour FROM f.hora_inicio) < 22 THEN 2
         ELSE 3 END,                                  -- turno derivado de la hora de inicio
    f.hora_inicio,
    f.hora_fin,
    (EXTRACT(EPOCH FROM (f.hora_fin - f.hora_inicio)) / 60)::INT
FROM fix f
JOIN      dim_producto p ON p.codigo = f.producto_txt
LEFT JOIN dim_operador o ON o.nombre = f.operador_txt;

-- Limpieza de nulos: IS NULL → centinela -1 (SIN_ASIGNAR).
UPDATE fact_lotes SET operador_id = -1 WHERE operador_id IS NULL;

COMMIT;

BEGIN;

-- fact_paros: UNPIVOT del formato ancho a (lote, factor, minutos) con LATERAL.
--   - descarta celdas vacías (WHERE ... IS NOT NULL)
--   - CAST '60.0' (texto) → NUMERIC → INT
--   - el JOIN (INNER) a fact_lotes EXCLUYE los lotes huérfanos 422137-422143
INSERT INTO fact_paros (lote_id, factor_id, minutos)
SELECT
    s.lote_txt::BIGINT,
    v.factor_id,
    v.minutos_txt::NUMERIC::INT
FROM stg_downtime s
CROSS JOIN LATERAL (VALUES
    (1, s.f1_txt), (2, s.f2_txt), (3, s.f3_txt), (4, s.f4_txt),
    (5, s.f5_txt), (6, s.f6_txt), (7, s.f7_txt), (8, s.f8_txt),
    (9, s.f9_txt), (10, s.f10_txt), (11, s.f11_txt), (12, s.f12_txt)
) AS v(factor_id, minutos_txt)
JOIN fact_lotes l ON l.lote_id = s.lote_txt::BIGINT   -- INNER: descarta huérfanos
WHERE v.minutos_txt IS NOT NULL;

COMMIT;

-- =============================================================================
-- 5. Demostración de ROLLBACK ante validación fallida (transacción con propósito).
-- =============================================================================
DO $$
BEGIN
    INSERT INTO fact_paros (lote_id, factor_id, minutos) VALUES (422111, 7, 999);
    RAISE NOTICE 'Inesperado: la fila inválida pasó (no debería).';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'ROLLBACK: minutos=999 rechazado por el CHECK (outlier) → carga intacta.';
END $$;

-- =============================================================================
-- 6. Refrescar la vista materializada
-- =============================================================================
REFRESH MATERIALIZED VIEW v_pareto_paros;