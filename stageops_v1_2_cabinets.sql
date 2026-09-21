-- StageOPS v1.2 — Gabinetes, posiciones de módulos y análisis de fallas por zona
-- Migración ADITIVA sobre stageops_v1.sql + stageops_v1_1_movements.sql

-- ============================================================
-- 1. CABINET_TYPES (define la grilla: filas x columnas de un modelo de gabinete)
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
-- 3. CABINET_SLOTS (cada posición dentro de un gabinete, con su zona)
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
-- 4. SLOT_ASSIGNMENTS (historial: qué módulo ocupó qué posición y cuándo)
--    Esto es lo que permite el análisis de frecuencia de falla por zona.
-- ============================================================
create table if not exists public.slot_assignments(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  cabinet_slot_id uuid not null references public.cabinet_slots(id) on delete cascade,
  serial_unit_id uuid not null references public.serial_units(id) on delete cascade,
  installed_at timestamptz not null default now(),
  removed_at timestamptz,
  removal_reason text check (removal_reason in ('failure','scheduled_swap','cabinet_retired'))
);

create index if not exists slot_assignments_slot_idx on public.slot_assignments(cabinet_slot_id);
create index if not exists slot_assignments_serial_idx on public.slot_assignments(serial_unit_id);

-- ============================================================
-- 5. Vincular repairs con la posición exacta donde falló el módulo
-- ============================================================
alter table public.repairs add column if not exists serial_unit_id uuid references public.serial_units(id) on delete set null;
alter table public.repairs add column if not exists cabinet_slot_id uuid references public.cabinet_slots(id) on delete set null;
alter table public.repairs add column if not exists zone text check (zone in ('corner','edge','center'));
alter table public.repairs add column if not exists assigned_to uuid references public.profiles(id) on delete set null;
alter table public.repairs add column if not exists resolution text check (resolution in ('repaired','scrapped'));

-- ============================================================
-- 6. Función: generar automáticamente los slots de un gabinete nuevo
--    (calcula la zona de cada posición según su lugar en la grilla)
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
-- 7. RLS
-- ============================================================
alter table public.cabinet_types enable row level security;
alter table public.cabinets enable row level security;
alter table public.cabinet_slots enable row level security;
alter table public.slot_assignments enable row level security;

create policy "cabinet_types_org_all" on public.cabinet_types
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "cabinets_org_all" on public.cabinets
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "cabinet_slots_org_all" on public.cabinet_slots
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "slot_assignments_org_all" on public.slot_assignments
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 8. Consulta de referencia: frecuencia de falla por zona
--    (para el reporte que vas a usar en la capacitación del equipo)
-- ============================================================
-- select cs.zone, count(*) as fallas
-- from public.slot_assignments sa
-- join public.cabinet_slots cs on cs.id = sa.cabinet_slot_id
-- where sa.removal_reason = 'failure'
--   and sa.cabinet_slot_id in (select id from public.cabinet_slots where organization_id = public.current_org_id())
-- group by cs.zone
-- order by fallas desc;
