-- StageOPS v1.1 — Movimientos de stock, proveedores, ubicaciones y trazabilidad por serie
-- Migración ADITIVA: no modifica ni borra nada de stageops_v1.sql, solo agrega.
-- Correr DESPUES de stageops_v1.sql en el SQL Editor de Supabase.

-- ============================================================
-- 1. SUPPLIERS (proveedores normalizados)
-- ============================================================
create table if not exists public.suppliers(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  tax_id text,
  email text,
  phone text,
  notes text,
  created_at timestamptz default now(),
  unique(organization_id, name)
);

-- lots.supplier queda como texto legado; se agrega el FK real
alter table public.lots add column if not exists supplier_id uuid references public.suppliers(id) on delete set null;

-- ============================================================
-- 2. WAREHOUSE_LOCATIONS (ubicaciones dentro de un depósito)
-- ============================================================
create table if not exists public.warehouse_locations(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  code text not null,
  description text,
  zone text,
  active boolean default true,
  created_at timestamptz default now(),
  unique(organization_id, warehouse_id, code)
);

-- ============================================================
-- 3. SERIAL_UNITS (trazabilidad individual, para productos con track_serials=true)
-- ============================================================
create table if not exists public.serial_units(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  lot_id uuid references public.lots(id) on delete set null,
  serial_code text not null,
  status text not null default 'available'
    check (status in ('available','reserved','in_transit','at_event','in_repair','retired','lost')),
  current_warehouse_id uuid references public.warehouses(id) on delete set null,
  current_location_id uuid references public.warehouse_locations(id) on delete set null,
  current_event_id uuid references public.events(id) on delete set null,
  purchase_cost numeric(14,2),
  received_at date,
  retired_at date,
  notes text,
  created_at timestamptz default now(),
  unique(organization_id, serial_code)
);

-- ============================================================
-- 4. STOCK_MOVEMENTS (historial completo: entradas, salidas, transferencias, ajustes)
-- ============================================================
create table if not exists public.stock_movements(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  lot_id uuid references public.lots(id) on delete set null,
  serial_unit_id uuid references public.serial_units(id) on delete set null,
  movement_type text not null
    check (movement_type in ('inbound','outbound','transfer','adjustment','reservation_hold','reservation_release','repair_in','repair_out')),
  quantity numeric(14,3) not null check (quantity <> 0),
  from_warehouse_id uuid references public.warehouses(id) on delete set null,
  from_location_id uuid references public.warehouse_locations(id) on delete set null,
  from_state text,
  to_warehouse_id uuid references public.warehouses(id) on delete set null,
  to_location_id uuid references public.warehouse_locations(id) on delete set null,
  to_state text default 'available',
  reference_type text, -- 'event' | 'repair' | 'purchase_order' | 'manual'
  reference_id uuid,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists stock_movements_org_product_idx on public.stock_movements(organization_id, product_id);
create index if not exists stock_movements_reference_idx on public.stock_movements(reference_type, reference_id);
create index if not exists serial_units_org_status_idx on public.serial_units(organization_id, status);

-- ============================================================
-- 5. Preparar inventory_balances para upserts atómicos
--    (lot_id es nullable; se agrega columna generada para poder
--     usar ON CONFLICT correctamente incluso sin lote)
-- ============================================================
alter table public.inventory_balances
  add column if not exists lot_key uuid generated always as (
    coalesce(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) stored;

create unique index if not exists inventory_balances_unique_bucket
  on public.inventory_balances(organization_id, product_id, lot_key, warehouse_id, state);

-- ============================================================
-- 6. Función RPC: record_stock_movement
--    Registra el movimiento Y actualiza inventory_balances
--    en la misma transacción (evita que queden desincronizados).
--    Se llama desde la app en vez de escribir directo a las tablas.
-- ============================================================
create or replace function public.record_stock_movement(
  p_product_id uuid,
  p_lot_id uuid,
  p_movement_type text,
  p_quantity numeric,
  p_from_warehouse_id uuid,
  p_from_location_id uuid,
  p_from_state text,
  p_to_warehouse_id uuid,
  p_to_location_id uuid,
  p_to_state text,
  p_reference_type text,
  p_reference_id uuid,
  p_notes text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_movement_id uuid;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be a positive number';
  end if;

  -- Descuenta del origen (si corresponde, ej: salida o transferencia)
  if p_from_warehouse_id is not null then
    update public.inventory_balances
      set quantity = quantity - p_quantity
      where organization_id = v_org
        and product_id = p_product_id
        and lot_key = coalesce(p_lot_id, '00000000-0000-0000-0000-000000000000'::uuid)
        and warehouse_id = p_from_warehouse_id
        and state = coalesce(p_from_state, 'available');
    if not found then
      raise exception 'No matching balance found to decrement (product/lot/warehouse/state)';
    end if;
  end if;

  -- Suma al destino (si corresponde, ej: entrada o transferencia)
  if p_to_warehouse_id is not null then
    insert into public.inventory_balances(organization_id, product_id, lot_id, warehouse_id, state, quantity)
    values (v_org, p_product_id, p_lot_id, p_to_warehouse_id, coalesce(p_to_state, 'available'), p_quantity)
    on conflict (organization_id, product_id, lot_key, warehouse_id, state)
    do update set quantity = public.inventory_balances.quantity + excluded.quantity;
  end if;

  insert into public.stock_movements(
    organization_id, product_id, lot_id, movement_type, quantity,
    from_warehouse_id, from_location_id, from_state,
    to_warehouse_id, to_location_id, to_state,
    reference_type, reference_id, notes, created_by
  ) values (
    v_org, p_product_id, p_lot_id, p_movement_type, p_quantity,
    p_from_warehouse_id, p_from_location_id, p_from_state,
    p_to_warehouse_id, p_to_location_id, p_to_state,
    p_reference_type, p_reference_id, p_notes, auth.uid()
  ) returning id into v_movement_id;

  return v_movement_id;
end;
$$;

grant execute on function public.record_stock_movement(
  uuid, uuid, text, numeric, uuid, uuid, text, uuid, uuid, text, text, uuid, text
) to authenticated;

-- ============================================================
-- 7. RLS para las tablas nuevas
-- ============================================================
alter table public.suppliers enable row level security;
alter table public.warehouse_locations enable row level security;
alter table public.serial_units enable row level security;
alter table public.stock_movements enable row level security;

create policy "suppliers_org_all" on public.suppliers
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "warehouse_locations_org_all" on public.warehouse_locations
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "serial_units_org_all" on public.serial_units
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "stock_movements_org_all" on public.stock_movements
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());
