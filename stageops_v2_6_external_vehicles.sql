-- StageOPS v2.6 — Vehículos externos (fletes subcontratados)
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_4_transport.sql, v2_2_collaborators.sql y v2_3_cost_visibility.sql

-- ============================================================
-- 1. Un vehículo puede ser propio o externo. Si es externo, puede
--    venir de un colaborador ya cargado, o ser un fletero puntual
--    (sin necesidad de darlo de alta como colaborador fijo).
-- ============================================================
alter table public.vehicles add column if not exists is_own boolean not null default true;
alter table public.vehicles add column if not exists collaborator_id uuid references public.collaborators(id) on delete set null;
alter table public.vehicles add column if not exists external_provider text; -- nombre libre si no es un colaborador guardado

-- ============================================================
-- 2. Costo del flete para ese viaje puntual (solo aplica si el
--    vehículo usado en ese vehicle_load es externo)
-- ============================================================
alter table public.vehicle_loads add column if not exists rental_cost numeric(14,2);

-- Se protege igual que el resto de los costos: solo lectura/escritura para 'owner'
revoke select (rental_cost) on public.vehicle_loads from authenticated;
revoke update (rental_cost) on public.vehicle_loads from authenticated;

create or replace function public.set_vehicle_load_rental_cost(
  p_vehicle_load_id uuid,
  p_rental_cost numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() <> 'owner' then
    raise exception 'Solo el dueño puede cargar el costo de un flete externo';
  end if;
  update public.vehicle_loads set rental_cost = p_rental_cost where id = p_vehicle_load_id;
end;
$$;

grant execute on function public.set_vehicle_load_rental_cost(uuid, numeric) to authenticated;

-- ============================================================
-- 3. event_profitability ahora también resta lo pagado en fletes externos
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
  public.mask_cost(coalesce(veh.rental_costs, 0)) as vehicle_rental_costs,
  public.mask_cost(
    coalesce(e.contract_amount, 0)
    - coalesce(r.repair_costs, 0)
    - coalesce(l.loss_costs, 0)
    - coalesce(col.collaborator_costs, 0)
    - coalesce(veh.rental_costs, 0)
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
left join (
  select event_id, sum(coalesce(rental_cost,0)) as rental_costs
  from public.vehicle_loads
  where rental_cost is not null
  group by event_id
) veh on veh.event_id = e.id
where e.organization_id = public.current_org_id();

-- ============================================================
-- 4. vehicle_status distingue flota propia de externa
-- ============================================================
create or replace view public.vehicle_status as
select
  v.id as vehicle_id,
  v.name,
  v.plate,
  v.status,
  v.is_own,
  coalesce(v.external_provider, col.name) as external_provider_name,
  v.current_km,
  v.next_service_km,
  case when v.next_service_km is not null then v.next_service_km - v.current_km else null end as km_to_service,
  count(vl.id) as total_trips,
  coalesce(sum(vl.actual_distance_km), 0) as total_km_traveled,
  max(vl.departure_at) as last_trip_at
from public.vehicles v
left join public.collaborators col on col.id = v.collaborator_id
left join public.vehicle_loads vl on vl.vehicle_id = v.id
where v.organization_id = public.current_org_id()
group by v.id, v.name, v.plate, v.status, v.is_own, v.external_provider, col.name, v.current_km, v.next_service_km;
