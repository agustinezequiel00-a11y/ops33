-- StageOPS v2.5 — Seguimiento de vehículos: km por viaje y mantenimiento
-- Migración ADITIVA. Se apoya en stageops_v1.sql y stageops_v1_4_transport.sql

-- ============================================================
-- 1. Odómetro acumulado del vehículo y próximo service
-- ============================================================
alter table public.vehicles add column if not exists current_km numeric(10,1) default 0;
alter table public.vehicles add column if not exists next_service_km numeric(10,1);

-- ============================================================
-- 2. Cada viaje (vehicle_loads) guarda:
--    - planned_distance_km: el estimado antes de salir (viene de una
--      API de mapas desde el frontend, la base solo lo almacena)
--    - odometer_start / odometer_end: lectura real del odómetro,
--      para llevar el km real recorrido y actualizar el vehículo
-- ============================================================
alter table public.vehicle_loads add column if not exists planned_distance_km numeric(10,1);
alter table public.vehicle_loads add column if not exists odometer_start numeric(10,1);
alter table public.vehicle_loads add column if not exists odometer_end numeric(10,1);
alter table public.vehicle_loads add column if not exists actual_distance_km numeric(10,1)
  generated always as (odometer_end - odometer_start) stored;

-- ============================================================
-- 3. Historial de mantenimiento
-- ============================================================
create table if not exists public.vehicle_maintenance(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  maintenance_type text not null check (maintenance_type in ('service','tires','brakes','inspection','other')),
  performed_at date not null default current_date,
  odometer_km numeric(10,1),
  cost numeric(10,2),
  next_due_km numeric(10,1),
  notes text,
  created_at timestamptz default now()
);

alter table public.vehicle_maintenance enable row level security;
create policy "vehicle_maintenance_org_all" on public.vehicle_maintenance
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 4. Salida y retorno del vehículo: registran el odómetro y
--    mantienen sincronizado vehicles.current_km automáticamente.
-- ============================================================
create or replace function public.record_vehicle_departure(
  p_vehicle_load_id uuid,
  p_odometer_start numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle_id uuid;
begin
  update public.vehicle_loads
    set odometer_start = p_odometer_start, status = 'departed'
    where id = p_vehicle_load_id
    returning vehicle_id into v_vehicle_id;

  if v_vehicle_id is null then
    raise exception 'Vehicle load not found: %', p_vehicle_load_id;
  end if;

  update public.vehicles set status = 'in_use' where id = v_vehicle_id;
end;
$$;

create or replace function public.record_vehicle_return(
  p_vehicle_load_id uuid,
  p_odometer_end numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle_id uuid;
begin
  update public.vehicle_loads
    set odometer_end = p_odometer_end, status = 'returned'
    where id = p_vehicle_load_id
    returning vehicle_id into v_vehicle_id;

  if v_vehicle_id is null then
    raise exception 'Vehicle load not found: %', p_vehicle_load_id;
  end if;

  update public.vehicles
    set current_km = p_odometer_end, status = 'available'
    where id = v_vehicle_id and (current_km is null or p_odometer_end > current_km);
end;
$$;

grant execute on function public.record_vehicle_departure(uuid, numeric) to authenticated;
grant execute on function public.record_vehicle_return(uuid, numeric) to authenticated;

-- ============================================================
-- 5. Vista de estado de flota: km actual, próximo service,
--    y resumen de uso por vehículo.
-- ============================================================
create or replace view public.vehicle_status as
select
  v.id as vehicle_id,
  v.name,
  v.plate,
  v.status,
  v.current_km,
  v.next_service_km,
  case when v.next_service_km is not null then v.next_service_km - v.current_km else null end as km_to_service,
  count(vl.id) as total_trips,
  coalesce(sum(vl.actual_distance_km), 0) as total_km_traveled,
  max(vl.departure_at) as last_trip_at
from public.vehicles v
left join public.vehicle_loads vl on vl.vehicle_id = v.id
where v.organization_id = public.current_org_id()
group by v.id, v.name, v.plate, v.status, v.current_km, v.next_service_km;
