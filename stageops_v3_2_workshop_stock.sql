-- StageOPS v3.2 — Stock de repuestos para taller (independiente del stock de alquiler)
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_1_movements.sql, v2_0_categories.sql y v2_3_cost_visibility.sql

-- ============================================================
-- 0. CORRECCIÓN: en v2_3 se bloqueó labor_cost/parts_cost de repairs
--    para todos, pero nunca se creó la vista que se los devuelve al
--    dueño. Sin esto, ni el dueño podía leerlos. Se agrega ahora.
-- ============================================================
create or replace view public.repairs_display as
select
  id, organization_id, product_id, lot_id, serial_code, quantity,
  failure_type, damage_zone, probable_cause, related_event_id, priority,
  status, opened_at, closed_at, notes, serial_unit_id, cabinet_slot_id,
  zone, assigned_to, resolution,
  public.mask_cost(labor_cost) as labor_cost,
  public.mask_cost(parts_cost) as parts_cost
from public.repairs
where organization_id = public.current_org_id();

-- ============================================================
-- 1. Los repuestos son productos como cualquier otro (misma tabla),
--    solo que con su propia categoría — así heredan gratis todo el
--    motor de lotes, depósitos y movimientos que ya existía.
-- ============================================================
alter table public.products drop constraint if exists products_category_check;
alter table public.products add constraint products_category_check
  check (category in ('led_screen','lighting','audio','communication','rigging','spare_part','other'));

-- ============================================================
-- 2. Un depósito puede marcarse como "de taller" — así el stock de
--    repuestos se puede mirar como algo propio, separado del
--    depósito de alquiler, sin que sea una tabla distinta.
-- ============================================================
alter table public.warehouses add column if not exists is_workshop boolean not null default false;

-- ============================================================
-- 3. Registro de qué repuesto puntual se usó en qué reparación,
--    con su costo (protegido) al momento de usarlo.
-- ============================================================
create table if not exists public.repair_parts_used(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  repair_id uuid not null references public.repairs(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_cost numeric(10,2),
  warehouse_id uuid references public.warehouses(id) on delete set null,
  used_at timestamptz default now()
);

alter table public.repair_parts_used enable row level security;
create policy "repair_parts_used_org_all" on public.repair_parts_used
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

revoke select (unit_cost) on public.repair_parts_used from authenticated;
revoke update (unit_cost) on public.repair_parts_used from authenticated;

create or replace view public.repair_parts_used_display as
select
  id, organization_id, repair_id, product_id, quantity, warehouse_id, used_at,
  public.mask_cost(unit_cost) as unit_cost
from public.repair_parts_used
where organization_id = public.current_org_id();

-- ============================================================
-- 4. Usar un repuesto: descuenta del depósito de taller (mismo
--    mecanismo que cualquier salida de stock) y suma el costo a
--    la reparación automáticamente, en vez de tipearlo a mano.
-- ============================================================
create or replace function public.use_repair_part(
  p_repair_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_warehouse_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be positive';
  end if;

  perform public.record_stock_movement(
    p_product_id => p_product_id,
    p_lot_id => null,
    p_movement_type => 'outbound',
    p_quantity => p_quantity,
    p_from_warehouse_id => p_warehouse_id,
    p_from_location_id => null,
    p_from_state => 'available',
    p_to_warehouse_id => null,
    p_to_location_id => null,
    p_to_state => null,
    p_reference_type => 'repair',
    p_reference_id => p_repair_id,
    p_notes => 'Repuesto consumido en reparación'
  );

  insert into public.repair_parts_used(organization_id, repair_id, product_id, quantity, unit_cost, warehouse_id)
  values (v_org, p_repair_id, p_product_id, p_quantity, p_unit_cost, p_warehouse_id);

  update public.repairs
    set parts_cost = coalesce(parts_cost, 0) + coalesce(p_unit_cost, 0) * p_quantity
    where id = p_repair_id;
end;
$$;

grant execute on function public.use_repair_part(uuid, uuid, numeric, numeric, uuid) to authenticated;

-- ============================================================
-- 5. Resumen del stock de taller: solo productos de categoría
--    'spare_part' en depósitos marcados como is_workshop.
-- ============================================================
create or replace view public.workshop_stock_summary as
select
  p.id as product_id,
  p.name as product_name,
  w.id as warehouse_id,
  w.name as warehouse_name,
  ib.state,
  ib.quantity
from public.inventory_balances ib
join public.products p on p.id = ib.product_id
join public.warehouses w on w.id = ib.warehouse_id
where ib.organization_id = public.current_org_id()
  and p.category = 'spare_part'
  and w.is_workshop = true;
