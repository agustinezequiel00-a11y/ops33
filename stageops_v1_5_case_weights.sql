-- StageOPS v1.5 — Peso real de carga por envío (no por capacidad máxima del case)
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_1_movements.sql y v1_4_transport.sql

-- ============================================================
-- 1. Cada módulo queda asociado a un flight case desde el ingreso
-- ============================================================
alter table public.serial_units add column if not exists current_flight_case_id uuid references public.flight_cases(id) on delete set null;
create index if not exists serial_units_flight_case_idx on public.serial_units(current_flight_case_id);

-- ============================================================
-- 2. Helper para el ingreso: agrupa automáticamente los módulos
--    nuevos de un lote en flight cases de N unidades cada uno.
--    Ej: 40 módulos, 10 por case -> crea 4 flight cases y los asigna.
-- ============================================================
create or replace function public.assign_serials_to_flight_cases(
  p_lot_id uuid,
  p_units_per_case integer,
  p_code_prefix text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_product_id uuid;
  v_case_id uuid;
  v_count integer := 0;
  rec record;
  v_case_index integer := 0;
begin
  select organization_id, product_id into v_org, v_product_id
    from public.lots where id = p_lot_id;

  if v_org is null then
    raise exception 'Lot not found: %', p_lot_id;
  end if;
  if p_units_per_case <= 0 then
    raise exception 'units_per_case must be positive';
  end if;

  for rec in
    select id from public.serial_units
    where organization_id = v_org and lot_id = p_lot_id and current_flight_case_id is null
    order by serial_code
  loop
    if v_count % p_units_per_case = 0 then
      v_case_index := v_case_index + 1;
      insert into public.flight_cases(organization_id, code, compatible_product_id, capacity_units, status)
      values (v_org, p_code_prefix || '-' || v_case_index, v_product_id, p_units_per_case, 'available')
      returning id into v_case_id;
    end if;

    update public.serial_units set current_flight_case_id = v_case_id where id = rec.id;
    v_count := v_count + 1;
  end loop;
end;
$$;

grant execute on function public.assign_serials_to_flight_cases(uuid, integer, text) to authenticated;

-- ============================================================
-- 3. Peso y volumen REAL de cada flight case para un envío puntual
--    (solo cuenta los módulos que efectivamente van, no la capacidad máxima)
-- ============================================================
create or replace function public.get_shipment_case_weights(
  p_serial_unit_ids uuid[]
) returns table(
  flight_case_id uuid,
  case_code text,
  modules_included integer,
  case_weight_kg numeric,
  case_volume_m3 numeric
)
language sql
security definer
set search_path = public
as $$
  select
    fc.id as flight_case_id,
    fc.code as case_code,
    count(su.id)::integer as modules_included,
    coalesce(fc.empty_weight_kg,0) + coalesce(sum(p.weight_kg),0) as case_weight_kg,
    coalesce(fc.length_m,0) * coalesce(fc.width_m,0) * coalesce(fc.height_m,0) as case_volume_m3
  from public.serial_units su
  join public.flight_cases fc on fc.id = su.current_flight_case_id
  join public.products p on p.id = su.product_id
  where su.id = any(p_serial_unit_ids)
    and su.current_flight_case_id is not null
  group by fc.id, fc.code, fc.empty_weight_kg, fc.length_m, fc.width_m, fc.height_m;
$$;

grant execute on function public.get_shipment_case_weights(uuid[]) to authenticated;

-- ============================================================
-- 4. suggest_vehicle_loading ahora recibe los MÓDULOS puntuales que
--    viajan (no los flight cases completos), y calcula el peso real
--    de cada case a partir de eso antes de decidir en qué vehículo entra.
-- ============================================================
drop function if exists public.suggest_vehicle_loading(uuid, uuid[]);

create or replace function public.suggest_vehicle_loading(
  p_event_id uuid,
  p_serial_unit_ids uuid[]
) returns table(
  flight_case_id uuid,
  case_code text,
  modules_included integer,
  case_weight_kg numeric,
  case_volume_m3 numeric,
  vehicle_id uuid,
  vehicle_name text
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
    select * from public.get_shipment_case_weights(p_serial_unit_ids)
    order by case_volume_m3 desc
  loop
    select v.id, v.name into veh
    from public.vehicles v
    join tmp_vehicle_usage u on u.vehicle_id = v.id
    where v.organization_id = v_org
      and (u.used_volume + rec.case_volume_m3) <= (coalesce(v.usable_length_m,0) * coalesce(v.usable_width_m,0) * coalesce(v.usable_height_m,0))
      and (u.used_weight + rec.case_weight_kg) <= coalesce(v.max_weight_kg, 999999)
    order by (coalesce(v.usable_length_m,0) * coalesce(v.usable_width_m,0) * coalesce(v.usable_height_m,0)) asc
    limit 1;

    if veh.id is null then
      raise exception 'No hay vehículo con capacidad para el flight case %', rec.case_code;
    end if;

    update tmp_vehicle_usage
      set used_volume = used_volume + rec.case_volume_m3,
          used_weight = used_weight + rec.case_weight_kg
      where vehicle_id = veh.id;

    flight_case_id := rec.flight_case_id;
    case_code := rec.case_code;
    modules_included := rec.modules_included;
    case_weight_kg := rec.case_weight_kg;
    case_volume_m3 := rec.case_volume_m3;
    vehicle_id := veh.id;
    vehicle_name := veh.name;
    return next;
  end loop;
end;
$$;

grant execute on function public.suggest_vehicle_loading(uuid, uuid[]) to authenticated;
