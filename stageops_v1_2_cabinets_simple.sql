-- StageOPS v1.2 (simplificado) — Gabinetes, posiciones de módulos, sin historial de slot_assignments
-- Reemplaza a stageops_v1_2_cabinets.sql (esta versión es la que hay que correr)
-- Se apoya en stageops_v1.sql + stageops_v1_1_movements.sql

-- ============================================================
-- 1. CABINET_TYPES (grilla filas x columnas de cada modelo de gabinete)
-- ============================================================
create table if not exists public.cabinet_types(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  rows integer not null check (rows > 0),
  cols integer not null check (cols > 0),
  created_at timestamptz default now(),
  unique(organization_id, name)
);

-- ============================================================
-- 2. CABINETS (gabinete físico serializado)
-- ============================================================
create table if not exists public.cabinets(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  cabinet_type_id uuid not null references public.cabinet_types(id) on delete restrict,
  serial_code text not null,
  status text not null default 'available'
    check (status in ('available','reserved','in_transit','at_event','in_repair','retired')),
  current_warehouse_id uuid references public.warehouses(id) on delete set null,
  current_location_id uuid references public.warehouse_locations(id) on delete set null,
  current_event_id uuid references public.events(id) on delete set null,
  created_at timestamptz default now(),
  unique(organization_id, serial_code)
);

-- ============================================================
-- 3. CABINET_SLOTS (cada posición del gabinete, con su zona y ocupante actual)
--    Sin historial: solo guarda quién está AHORA en cada posición.
-- ============================================================
create table if not exists public.cabinet_slots(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  cabinet_id uuid not null references public.cabinets(id) on delete cascade,
  row_index integer not null,
  col_index integer not null,
  zone text not null check (zone in ('corner','edge','center')),
  current_serial_unit_id uuid references public.serial_units(id) on delete set null,
  unique(organization_id, cabinet_id, row_index, col_index)
);

-- ============================================================
-- 4. Vincular repairs con la posición donde falló el módulo
--    (esto solo, ya alcanza para el análisis por zona)
-- ============================================================
alter table public.repairs add column if not exists serial_unit_id uuid references public.serial_units(id) on delete set null;
alter table public.repairs add column if not exists cabinet_slot_id uuid references public.cabinet_slots(id) on delete set null;
alter table public.repairs add column if not exists zone text check (zone in ('corner','edge','center'));
alter table public.repairs add column if not exists assigned_to uuid references public.profiles(id) on delete set null;
alter table public.repairs add column if not exists resolution text check (resolution in ('repaired','scrapped'));

create index if not exists repairs_zone_idx on public.repairs(zone);

-- ============================================================
-- 5. Función: generar automáticamente los slots de un gabinete nuevo
-- ============================================================
create or replace function public.generate_cabinet_slots(p_cabinet_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_rows int;
  v_cols int;
  r int;
  c int;
  v_zone text;
begin
  select cb.organization_id, ct.rows, ct.cols
    into v_org, v_rows, v_cols
    from public.cabinets cb
    join public.cabinet_types ct on ct.id = cb.cabinet_type_id
    where cb.id = p_cabinet_id;

  if v_org is null then
    raise exception 'Cabinet not found: %', p_cabinet_id;
  end if;

  for r in 1..v_rows loop
    for c in 1..v_cols loop
      if (r = 1 or r = v_rows) and (c = 1 or c = v_cols) then
        v_zone := 'corner';
      elsif r = 1 or r = v_rows or c = 1 or c = v_cols then
        v_zone := 'edge';
      else
        v_zone := 'center';
      end if;

      insert into public.cabinet_slots(organization_id, cabinet_id, row_index, col_index, zone)
      values (v_org, p_cabinet_id, r, c, v_zone)
      on conflict (organization_id, cabinet_id, row_index, col_index) do nothing;
    end loop;
  end loop;
end;
$$;

grant execute on function public.generate_cabinet_slots(uuid) to authenticated;

-- ============================================================
-- 6. RLS
-- ============================================================
alter table public.cabinet_types enable row level security;
alter table public.cabinets enable row level security;
alter table public.cabinet_slots enable row level security;

create policy "cabinet_types_org_all" on public.cabinet_types
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "cabinets_org_all" on public.cabinets
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "cabinet_slots_org_all" on public.cabinet_slots
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 7. Consulta de referencia para el reporte de capacitación
--    (ya no hace falta slot_assignments: repairs.zone alcanza)
-- ============================================================
-- select zone, count(*) as fallas
-- from public.repairs
-- where organization_id = public.current_org_id()
-- group by zone
-- order by fallas desc;
