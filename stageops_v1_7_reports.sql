-- StageOPS v1.7 — Reportes: costos por reparación, ingreso por evento, vista de rentabilidad
-- Migración ADITIVA. Se apoya en stageops_v1.sql

-- ============================================================
-- 1. Ingreso pactado por evento (hoy no existía ningún dato de facturación)
-- ============================================================
alter table public.events add column if not exists contract_amount numeric(14,2);

-- ============================================================
-- 2. Costos reales de cada reparación (mano de obra + repuestos)
-- ============================================================
alter table public.repairs add column if not exists labor_cost numeric(10,2);
alter table public.repairs add column if not exists parts_cost numeric(10,2);

-- ============================================================
-- 3. Vista de rentabilidad por evento
--    Ingreso (contract_amount) menos costos de reparación asociados
--    a ese evento, menos el valor de equipos perdidos durante ese evento.
-- ============================================================
create or replace view public.event_profitability as
select
  e.id as event_id,
  e.name as event_name,
  e.client_id,
  c.name as client_name,
  e.event_at,
  e.contract_amount,
  coalesce(r.repair_costs, 0) as repair_costs,
  coalesce(l.loss_costs, 0) as loss_costs,
  coalesce(e.contract_amount, 0) - coalesce(r.repair_costs, 0) - coalesce(l.loss_costs, 0) as margin
from public.events e
left join public.clients c on c.id = e.client_id
left join (
  select related_event_id, sum(coalesce(labor_cost,0) + coalesce(parts_cost,0)) as repair_costs
  from public.repairs
  where related_event_id is not null
  group by related_event_id
) r on r.related_event_id = e.id
left join (
  select current_event_id, sum(coalesce(purchase_cost,0)) as loss_costs
  from public.serial_units
  where status = 'lost' and current_event_id is not null
  group by current_event_id
) l on l.current_event_id = e.id
where e.organization_id = public.current_org_id();

-- ============================================================
-- 4. Consulta de referencia para fallas por zona (ya construida antes,
--    se repite acá porque es la base del reporte de fallas)
-- ============================================================
-- select zone, count(*) as fallas
-- from public.repairs
-- where organization_id = public.current_org_id()
-- group by zone
-- order by fallas desc;
