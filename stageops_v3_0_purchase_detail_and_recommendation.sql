-- StageOPS v3.0 — Detalle de compra por unidad, y recomendación de proveedor por producto
-- Migración ADITIVA. Se apoya en stageops_v1_1_movements.sql, v2_1, v2_3 y v2_9

-- ============================================================
-- 1. Detalle de una compra puntual: cada gabinete o módulo con
--    serie que entró en ese lote, con su estado actual.
-- ============================================================
create or replace view public.lot_unit_detail as
select
  lot_id, organization_id, 'cabinet'::text as unit_type,
  serial_code, status, current_warehouse_id, current_location_id
from public.cabinets
where organization_id = public.current_org_id() and lot_id is not null
union all
select
  lot_id, organization_id, 'serial_unit'::text as unit_type,
  serial_code, status, current_warehouse_id, current_location_id
from public.serial_units
where organization_id = public.current_org_id() and lot_id is not null;

-- ============================================================
-- 2. Recomendación de proveedor por producto: a qué proveedores ya
--    le compraste ese producto, cuántas veces, y quién tuvo mejor
--    precio histórico. El precio en sí queda protegido para el
--    dueño (como el resto de los costos); el RANKING (1º, 2º...)
--    sí se muestra a todos, porque orienta sin revelar el peso exacto.
-- ============================================================
create or replace view public.product_supplier_options as
select
  product_id, product_name, supplier_id, supplier_name,
  times_purchased, last_purchased_at,
  public.mask_cost(avg_unit_cost) as avg_unit_cost,
  rank() over (partition by product_id order by avg_unit_cost asc nulls last) as price_rank
from (
  select
    l.product_id, p.name as product_name, s.id as supplier_id, s.name as supplier_name,
    count(l.id) as times_purchased,
    max(l.received_at) as last_purchased_at,
    avg(l.purchase_cost / nullif(coalesce(cb.unit_count,0) + coalesce(su.unit_count,0), 0)) as avg_unit_cost
  from public.lots l
  join public.products p on p.id = l.product_id
  join public.suppliers s on s.id = l.supplier_id
  left join (select lot_id, count(*) as unit_count from public.cabinets group by lot_id) cb on cb.lot_id = l.id
  left join (select lot_id, count(*) as unit_count from public.serial_units group by lot_id) su on su.lot_id = l.id
  where l.organization_id = public.current_org_id() and l.supplier_id is not null
  group by l.product_id, p.name, s.id, s.name
) sub;
