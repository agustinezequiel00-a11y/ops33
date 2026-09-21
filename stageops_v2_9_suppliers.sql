-- StageOPS v2.9 — Registro de proveedores: resumen e historial de compras
-- Migración ADITIVA. Se apoya en stageops_v1_1_movements.sql (suppliers), v2_1 (lots.purchase_cost) y v2_3 (mask_cost)

-- ============================================================
-- 1. Resumen por proveedor: cuántas compras, cuánto se gastó,
--    cuándo fue la última — mismo patrón que client_summary.
-- ============================================================
create or replace view public.supplier_summary as
select
  s.id as supplier_id,
  s.name,
  s.tax_id,
  s.email,
  s.phone,
  count(l.id) as total_purchases,
  public.mask_cost(coalesce(sum(l.purchase_cost), 0)) as total_spent,
  max(l.received_at) as last_purchase_at
from public.suppliers s
left join public.lots l on l.supplier_id = s.id
where s.organization_id = public.current_org_id()
group by s.id, s.name, s.tax_id, s.email, s.phone;

-- ============================================================
-- 2. Historial de compras: cada lote que entró de ese proveedor,
--    con cuántas unidades trajo (gabinetes o módulos con serie)
--    y el costo, protegido para el dueño.
-- ============================================================
create or replace view public.supplier_purchase_history as
select
  l.id as lot_id,
  l.supplier_id,
  l.code as lot_code,
  p.name as product_name,
  l.received_at,
  coalesce(cb.unit_count, 0) + coalesce(su.unit_count, 0) as units_received,
  public.mask_cost(l.purchase_cost) as purchase_cost
from public.lots l
join public.products p on p.id = l.product_id
left join (select lot_id, count(*) as unit_count from public.cabinets group by lot_id) cb on cb.lot_id = l.id
left join (select lot_id, count(*) as unit_count from public.serial_units group by lot_id) su on su.lot_id = l.id
where l.organization_id = public.current_org_id()
  and l.supplier_id is not null;
