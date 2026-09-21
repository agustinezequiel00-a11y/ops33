-- StageOPS v2.8 — Personal (empleados fijos y colaboradores eventuales)
-- Migración ADITIVA. Se apoya en stageops_v1.sql y stageops_v2_3_cost_visibility.sql (mask_cost, current_user_role)

-- ============================================================
-- 1. Personal: gente que trabaja en los eventos, sea de planta o
--    freelance. profile_id es opcional: solo se completa si esa
--    persona además tiene usuario para entrar a StageOPS.
-- ============================================================
create table if not exists public.personnel(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid references public.profiles(id) on delete set null,
  full_name text not null,
  tax_id text,
  phone text,
  email text,
  specialties text[] not null default '{}', -- ej: {'tecnico_led','rigging','chofer'}
  employment_type text not null check (employment_type in ('fijo','eventual')),
  day_rate numeric(10,2), -- tarifa por jornada, sensible, se enmascara abajo
  active boolean not null default true,
  notes text,
  created_at timestamptz default now()
);

alter table public.personnel enable row level security;
create policy "personnel_org_all" on public.personnel
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 2. Tarifa protegida: mismo criterio que costos de compra y fletes
--    (solo lectura/escritura para 'owner', bloqueado a nivel de columna)
-- ============================================================
revoke select (day_rate) on public.personnel from authenticated;
revoke update (day_rate) on public.personnel from authenticated;

create or replace view public.personnel_display as
select
  id, organization_id, profile_id, full_name, tax_id, phone, email,
  specialties, employment_type, active, notes, created_at,
  public.mask_cost(day_rate) as day_rate
from public.personnel
where organization_id = public.current_org_id();

create or replace function public.set_personnel_rate(
  p_personnel_id uuid,
  p_day_rate numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() <> 'owner' then
    raise exception 'Solo el dueño puede cargar tarifas de personal';
  end if;
  update public.personnel set day_rate = p_day_rate where id = p_personnel_id;
end;
$$;

grant execute on function public.set_personnel_rate(uuid, numeric) to authenticated;
