-- StageOPS v2.3 — Costos visibles solo para el dueño (bloqueo real en la base, no solo en pantalla)
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_9_roles.sql, v1_7_reports.sql, v2_1 y v2_2

-- ============================================================
-- 1. Se agrega el rol 'supervisor' (antes solo existía admin/warehouse/technician)
-- ============================================================
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('owner','admin','supervisor','warehouse','technician','sales','viewer'));

-- ============================================================
-- 2. Función que devuelve un valor solo si quien pregunta es 'owner'.
--    Se evalúa por consulta, con el usuario real que está preguntando
--    (no queda "grabada" en la vista para todo el mundo).
-- ============================================================
create or replace function public.mask_cost(p_value numeric)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when public.current_user_role() = 'owner' then p_value else null end
$$;

grant execute on function public.mask_cost(numeric) to authenticated;

-- ============================================================
-- 3. Se bloquea el acceso directo a las columnas de costo/facturación.
--    Esto es lo que de verdad protege el dato: aunque alguien intente
--    consultar la tabla directo (no por la app), Postgres le va a
--    negar el acceso a esa columna puntual.
-- ============================================================
revoke select (purchase_cost) on public.cabinets from authenticated;
revoke select (purchase_cost) on public.lots from authenticated;
revoke select (purchase_cost) on public.serial_units from authenticated;
revoke select (contract_amount) on public.events from authenticated;
revoke select (line_amount, collaborator_cost) on public.event_reservations from authenticated;
revoke select (labor_cost, parts_cost) on public.repairs from authenticated;

-- ============================================================
-- 4. Vistas "de exhibición" que sí pueden mostrar el resto de cada
--    tabla con normalidad, pero con el costo pasado por mask_cost().
--    La app debe leer de estas vistas, no de las tablas crudas,
--    para cualquier pantalla que un supervisor u operario pueda ver.
-- ============================================================
create or replace view public.cabinets_display as
select
  id, organization_id, cabinet_type_id, serial_code, status,
  current_warehouse_id, current_location_id, current_event_id,
  lot_id, purchase_date,
  public.mask_cost(purchase_cost) as purchase_cost
from public.cabinets
where organization_id = public.current_org_id();

create or replace view public.lots_display as
select
  id, organization_id, product_id, code, lot_type, parent_lot_id,
  supplier, supplier_id, received_at, technical_notes, active,
  public.mask_cost(purchase_cost) as purchase_cost
from public.lots
where organization_id = public.current_org_id();

create or replace view public.events_display as
select
  id, organization_id, client_id, branch_id, name, location,
  setup_at, event_at, teardown_at, status, notes, created_at,
  public.mask_cost(contract_amount) as contract_amount
from public.events
where organization_id = public.current_org_id();

-- ============================================================
-- 5. Reportes: se enmascaran los montos, no los datos operativos
--    (cantidad de reparaciones, fechas, nombres siguen visibles
--    para cualquiera — eso no es plata, es operación diaria)
-- ============================================================
create or replace view public.event_profitability as
select
  e.id as event_id,
  e.name as event_name,
  e.client_id,
  c.name as client_name,
  e.event_at,
  public.mask_cost(e.contract_amount) as contract_amount,
  public.mask_cost(coalesce(r.repair_costs, 0)) as repair_costs,
  public.mask_cost(coalesce(l.loss_costs, 0)) as loss_costs,
  public.mask_cost(coalesce(col.collaborator_costs, 0)) as collaborator_costs,
  public.mask_cost(
    coalesce(e.contract_amount, 0)
    - coalesce(r.repair_costs, 0)
    - coalesce(l.loss_costs, 0)
    - coalesce(col.collaborator_costs, 0)
  ) as margin
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
left join (
  select event_id, sum(coalesce(collaborator_cost,0)) as collaborator_costs
  from public.event_reservations
  where source = 'collaborator'
  group by event_id
) col on col.event_id = e.id
where e.organization_id = public.current_org_id();

create or replace view public.lot_amortization as
select
  l.id as lot_id,
  l.code,
  l.product_id,
  l.received_at as purchase_date,
  public.mask_cost(l.purchase_cost) as purchase_cost,
  public.mask_cost(coalesce(sum(er.line_amount), 0)) as revenue_generated,
  count(distinct er.event_id) as events_used_in,
  case
    when l.purchase_cost > 0
    then round(coalesce(sum(er.line_amount), 0) / l.purchase_cost * 100, 1)
    else null
  end as amortization_pct  -- el % queda visible: indica desempeño, no revela el peso exacto
from public.lots l
left join public.event_reservations er on er.lot_id = l.id and er.line_amount is not null
where l.organization_id = public.current_org_id()
group by l.id, l.code, l.product_id, l.received_at, l.purchase_cost;

create or replace view public.cabinet_repair_history as
select
  cb.id as cabinet_id,
  cb.serial_code,
  cb.purchase_date,
  public.mask_cost(cb.purchase_cost) as purchase_cost,
  count(r.id) as total_repairs, -- cantidad de reparaciones: no es plata, visible para todos
  public.mask_cost(coalesce(sum(coalesce(r.labor_cost,0) + coalesce(r.parts_cost,0)), 0)) as total_repair_cost,
  max(r.opened_at) as last_repair_at
from public.cabinets cb
left join public.cabinet_slots cs on cs.cabinet_id = cb.id
left join public.repairs r on r.cabinet_slot_id = cs.id
where cb.organization_id = public.current_org_id()
group by cb.id, cb.serial_code, cb.purchase_date, cb.purchase_cost;
