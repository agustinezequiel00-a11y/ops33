-- StageOPS v2.0 — Productos multi-categoría (pantallas, iluminación, audio, comunicación)
-- Migración ADITIVA. Se apoya en stageops_v1.sql

-- ============================================================
-- 1. Categoría del producto
--    Se relaciona conceptualmente con los flags que ya existían
--    en organization_features (led_operations, lighting_operations, audio_operations).
-- ============================================================
alter table public.products add column if not exists category text
  check (category in ('led_screen','lighting','audio','communication','rigging','other'))
  default 'other';

-- ============================================================
-- 2. Especificaciones flexibles por producto
--    "Espacio vacío" para atributos propios de cada categoría sin tener
--    que agregar una columna nueva cada vez que sumás un tipo de equipo.
--    Ejemplos de uso:
--      Handy:     {"frequency_mhz": 462.7, "channels": 16}
--      Luz:       {"dmx_channels": 12, "power_draw_w": 300, "beam_angle_deg": 8}
--      Pantalla:  {"pixel_pitch_mm": 3.9, "brightness_nits": 5000}
-- ============================================================
alter table public.products add column if not exists specs jsonb not null default '{}'::jsonb;

create index if not exists products_category_idx on public.products(category);
create index if not exists products_specs_idx on public.products using gin(specs);

-- ============================================================
-- 3. Nota: cabinet_types.product_id (de la migración de gabinetes) sigue
--    siendo opcional — solo tiene sentido completarlo para productos de
--    category='led_screen'. Un handy o una luz nunca van a tener cabinet_type,
--    y eso está bien: inventario, movimientos, reservas y reparaciones les
--    funcionan igual sin necesidad de gabinetes.
-- ============================================================
