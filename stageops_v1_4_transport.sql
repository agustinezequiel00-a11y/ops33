-- StageOPS v1.4 — Plan de carga: vehicle_loads, load_items, y sugerencia de asignación (bin packing)
-- Migración ADITIVA. Se apoya en stageops_v1.sql

-- ============================================================
-- 1. Peso por producto (faltaba para calcular carga real)
-- ============================================================
alter table public.products add column if not exists weight_kg numeric(10,3);

-- ============================================================
-- 2. VEHICLE_LOADS (qué vehículo lleva carga para qué evento)
-- ============================================================
create table if not exists public.vehicle_loads(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  departure_at timestamptz,
  status text not null default 'planned' check (status in ('planned','loaded','departed','returned')),
  notes text,
  created_at timestamptz default now()
);

-- ============================================================
-- 3. LOAD_ITEMS (qué va dentro de cada vehículo: flight cases o carga suelta)
-- ============================================================
create table if not exists public.load_items(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  vehicle_load_id uuid not null references public.vehicle_loads(id) on delete cascade,
  flight_case_id uuid references public.flight_cases(id) on delete set null,
  description text,
  weight_kg numeric(10,2),
  volume_m3 numeric(10,3),
  created_at timestamptz default now()
);

create index if not exists load_items_vehicle_load_idx on public.load_items(vehicle_load_id);

-- ============================================================
-- 4. Función: suggest_vehicle_loading
--
-- Recibe el evento y la lista de flight cases que hay que transportar.
-- Devuelve a qué vehículo conviene asignar cada uno, usando el mismo
-- criterio "best fit" que ya usamos para lotes: acomoda primero los
-- cases más grandes (First-Fit Decreasing) y, para cada uno, elige el
-- vehículo más chico donde todavía entra en volumen y peso — así no
-- se abre un camión grande de entrada si uno chico ya alcanza.
-- ============================================================
create or replace function public.suggest_vehicle_loading(
  p_event_id uuid,
  p_flight_case_ids uuid[]
) returns table(
  flight_case_id uuid,
  case_code text,
  vehicle_id uuid,
  vehicle_name text,
  case_volume_m3 numeric,
  case_weight_kg numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  rec record;
  veh record;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;

  create temporary table if not exists tmp_vehicle_usage(
    vehicle_id uuid primary key,
    used_volume numeric default 0,
    used_weight numeric default 0
  ) on commit drop;

  insert into tmp_vehicle_usage(vehicle_id)
  select id from public.vehicles
  where organization_id = v_org and status = 'available'
  on conflict do nothing;

  for rec in
    select fc.id, fc.code,
           coalesce(fc.length_m,0) * coalesce(fc.width_m,0) * coalesce(fc.height_m,0) as volume_m3,
           coalesce(fc.empty_weight_kg,0) as weight_kg
    from public.flight_cases fc
    where fc.organization_id = v_org
      and fc.id = any(p_flight_case_ids)
    order by volume_m3 desc
  loop
    select v.id, v.name into veh
    from public.vehicles v
    join tmp_vehicle_usage u on u.vehicle_id = v.id
    where v.organization_id = v_org
      and (u.used_volume + rec.volume_m3) <= (coalesce(v.usable_length_m,0) * coalesce(v.usable_width_m,0) * coalesce(v.usable_height_m,0))
      and (u.used_weight + rec.weight_kg) <= coalesce(v.max_weight_kg, 999999)
    order by (coalesce(v.usable_length_m,0) * coalesce(v.usable_width_m,0) * coalesce(v.usable_height_m,0)) asc
    limit 1;

    if veh.id is null then
      raise exception 'No hay vehículo disponible con capacidad para el flight case %', rec.code;
    end if;

    update tmp_vehicle_usage
      set used_volume = used_volume + rec.volume_m3,
          used_weight = used_weight + rec.weight_kg
      where vehicle_id = veh.id;

    flight_case_id := rec.id;
    case_code := rec.code;
    vehicle_id := veh.id;
    vehicle_name := veh.name;
    case_volume_m3 := rec.volume_m3;
    case_weight_kg := rec.weight_kg;
    return next;
  end loop;
end;
$$;

grant execute on function public.suggest_vehicle_loading(uuid, uuid[]) to authenticated;

-- ============================================================
-- 5. RLS
-- ============================================================
alter table public.vehicle_loads enable row level security;
alter table public.load_items enable row level security;

create policy "vehicle_loads_org_all" on public.vehicle_loads
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

create policy "load_items_org_all" on public.load_items
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());
