-- StageOPS v2.2 — Colaboradores (subcontratistas) para cubrir faltantes de stock propio
-- Migración ADITIVA. Se apoya en stageops_v1.sql y stageops_v1_7_reports.sql (event_profitability)

-- ============================================================
-- 1. Colaboradores: empresas externas a las que se les subcontrata
--    equipo cuando el stock propio no alcanza para un evento.
-- ============================================================
create table if not exists public.collaborators(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  tax_id text,
  contact_name text,
  phone text,
  email text,
  specialty_notes text, -- ej: "pantallas P2.6 y P3.9, cobertura CABA/GBA"
  active boolean default true,
  created_at timestamptz default now(),
  unique(organization_id, name)
);

alter table public.collaborators enable row level security;
create policy "collaborators_org_all" on public.collaborators
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 2. Una línea de reserva ahora puede salir del depósito propio
--    o de un colaborador — mismo evento, misma lista de equipo.
-- ============================================================
alter table public.event_reservations add column if not exists source text not null default 'internal'
  check (source in ('internal','collaborator'));
alter table public.event_reservations add column if not exists collaborator_id uuid references public.collaborators(id) on delete set null;
alter table public.event_reservations add column if not exists collaborator_cost numeric(14,2);

alter table public.event_reservations add constraint event_reservations_source_check
  check (
    (source = 'collaborator' and collaborator_id is not null)
    or (source = 'internal')
  );

-- ============================================================
-- 3. event_profitability ahora también resta lo pagado a colaboradores
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
  coalesce(col.collaborator_costs, 0) as collaborator_costs,
  coalesce(e.contract_amount, 0)
    - coalesce(r.repair_costs, 0)
    - coalesce(l.loss_costs, 0)
    - coalesce(col.collaborator_costs, 0) as margin
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
