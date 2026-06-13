# Proyecto Final SQL — Eficiencia de una Línea de Embotellado

Diseño, implementación y análisis de una base de datos relacional (modelo estrella) sobre la
producción y los paros de una línea embotelladora de refrescos. **Motor: PostgreSQL 15.**

**Pregunta de negocio central:** *¿Dónde y por qué pierde tiempo de producción la línea, y qué
factores/operadores lo explican?*

---

## 1. Origen de datos (real + extensión propia)

Dataset público reconocido: **Manufacturing Downtime** (Maven Analytics; espejo en
[Kaggle/agungpambudi](https://www.kaggle.com/datasets/agungpambudi/predict-manufacturing-downtime-performance-dataset)).
Línea embotelladora real, **31 lotes**, 29-ago → 03-sep 2024. Los CSV originales están en `dataset/`.

El dataset trae **2 hechos** y **2 dimensiones**; para llegar al mínimo de la rúbrica (≥5 tablas,
≥4 dimensiones) se **crean 3 dimensiones propias** (`dim_calendario`, `dim_operador`, `dim_turno`),
documentadas como extensión. Es un híbrido **real + propio**, defendible y anticipado por el enunciado.

> **Decisión clave:** el dataset **no tiene datos de calidad/scrap**, por lo que el **OEE completo
> no es calculable**. La métrica central es la **eficiencia de línea** (tiempo estándar / tiempo
> real) y el **Pareto de paros**, que sí están soportados por los datos. Se usa lo que el dato
> permite, no lo que sería ideal.

---

## 2. Modelo de datos (estrella)

**2 tablas de hechos + 5 dimensiones.** Diagrama: `model.png` (fuente editable: `model.dbml`).

### Hechos
- **`fact_lotes`** — granularidad: **1 fila = 1 lote producido**. Medidas: `duracion_min` (derivada).
- **`fact_paros`** — granularidad: **1 fila = 1 lote × 1 factor de paro** (tras *unpivot*). Medida: `minutos`.

### Dimensiones
| Tabla | Origen | Clave | Notas |
|---|---|---|---|
| `dim_producto` | real | surrogate `producto_id` | `codigo` UNIQUE; `min_batch_time` (tiempo estándar) |
| `dim_factor_paro` | real | natural `factor_id` (1–12) | `es_error_operador BOOLEAN` |
| `dim_operador` | creada | manual (incluye `-1`) | `-1 = SIN_ASIGNAR`; `especialidad`/`fecha_ingreso` sintéticos |
| `dim_turno` | creada | manual (1–3) | Mañana/Tarde/Noche; el turno del lote se deriva de la hora |
| `dim_calendario` | creada (`generate_series`) | natural `fecha_id` (YYYYMMDD) | calendario completo de 2 semanas |

### Justificación de PK/FK (resumen)
- **PK natural** donde el origen impone un id estable: `fact_lotes.lote_id` (nº de batch),
  `dim_factor_paro` (1–12), `dim_calendario` (YYYYMMDD, convención de DW).
- **PK surrogate** en las dimensiones que gestionamos (`dim_producto`) y en `fact_paros` (un lote
  tiene varios factores → no hay clave natural simple). El surrogate aísla la fact de recodificaciones.
- **FK** de los hechos a todas sus dimensiones; `fact_lotes.operador_id` es **NULL permitido**
  a propósito (registro sin login en planta → caso de calidad de datos).
- **3FN**: el motivo de paro no se escribe como texto libre en el hecho → catálogo `dim_factor_paro`.

### Alcance
- **Dentro:** producción por lote, paros por factor, eficiencia vs tiempo estándar, calidad de datos.
- **Fuera:** calidad/scrap (no está en el dato), costes, inventario, mantenimiento correctivo, multi-línea.

---

## 3. Arquitectura y ficheros

| Fichero | Capa | Contenido |
|---|---|---|
| `01_schema.sql` | modelo | DDL idempotente (DROP/CREATE `IF EXISTS`), constraints, 2 índices, 2 vistas, 1 función |
| `02_data.sql` | staging + carga | carga por código (INSERT), staging como TEXT, *unpivot*, limpieza, transacciones |
| `03_eda.sql` | análisis (CORE) | detección de calidad + 10 consultas de negocio comentadas |
| `model.dbml` / `model.png` | diseño | diagrama ER |
| `docker-compose.yml` | infra | Postgres 15 + pgAdmin dedicados |
| `dataset/` | datos | CSV originales del dataset |

**Vistas, función e índice:**
- `v_eficiencia_lote` (vista) — eficiencia y paro por lote.
- `v_pareto_paros` (vista **materializada**) — Pareto 80/20 con % acumulado (ventana).
- `fn_eficiencia_periodo(desde, hasta)` (función `LANGUAGE sql`) — eficiencia agregada de la línea.
- `idx_paros_lote_factor` + `idx_lotes_fecha` — aceleran las agregaciones por lote/factor y por fecha.

---

## 4. Cómo ejecutar (de cero)

Requisitos: Docker. Desde esta carpeta:

```bash
# 1. Levantar la base de datos (Postgres 15 en el puerto 5434)
docker compose up -d

# 2. Ejecutar los scripts en orden
PGPASSWORD=proyecto psql -h localhost -p 5434 -U proyecto -d embotelladora -f 01_schema.sql
PGPASSWORD=proyecto psql -h localhost -p 5434 -U proyecto -d embotelladora -f 02_data.sql
PGPASSWORD=proyecto psql -h localhost -p 5434 -U proyecto -d embotelladora -f 03_eda.sql
```

Conexión (DBeaver / pgAdmin / psql): `host=localhost · port=5434 · db=embotelladora · user=proyecto · pass=proyecto`.
pgAdmin web: `http://localhost:8081`.

---

## 5. Calidad de datos

El dataset real ya trae **anomalías genuinas** (no inventadas): un fin de lote que cruza medianoche
con fecha basura `1900-01-01` (corregido +1 día), lotes huérfanos `422137–422143` con paros pero sin
producción (excluidos por FK), formato ancho que exige *unpivot*. Se **siembran** solo dos casos que
el dato no fuerza —nulos de operador y duplicados exactos— para ejercitar `IS NULL`/`UPDATE` y
`ROW_NUMBER()`/dedup. Todo se corrige en `02_data.sql` (transacciones + demo de `ROLLBACK`) y se
**detecta** en `03_eda.sql` sobre la capa staging.

---

## 6. Insights de negocio

1. **Pareto 80/20:** ~5 factores explican el **80.8%** del paro; `Machine failure` lidera (20.9%).
   → priorizar mantenimiento de máquina antes que disciplina de operador.
2. **Operadores:** la eficiencia media entre operadores varía poco (~4 puntos) → **el operador no es
   el driver del problema**; el paro es de proceso/máquina.
3. **Tendencia:** la media móvil de paro **repunta al final** del periodo en los lotes de formato 2 L
   → ese formato concentra más paro.

Contexto: **eficiencia global 64.5%**, **16/31 lotes en estado 'Crítico'** (<70%).

---

## 7. Notas de defensa

- Técnicas no vistas en clase que se usan aquí (repasadas a propósito): `LAG()` (MTBF), `CREATE
  FUNCTION` (`LANGUAGE sql` vs `plpgsql`), `generate_series` (calendario).
- El **MTBF** es un proxy en tiempo de calendario (incluye noches/fin de semana) — declarado como tal.
- La **media móvil** usa ventana de 5 lotes (no 7 días) por la corta duración real del periodo.
