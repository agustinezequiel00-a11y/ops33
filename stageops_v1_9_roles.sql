-- StageOPS v1.9 — Roles definidos de usuario
-- Migración ADITIVA. Se apoya en stageops_v1.sql

-- Antes profiles.role era texto libre (riesgo de typos: "tecnico" vs "técnico" vs "Technician").
-- Se fija un set cerrado de roles.
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('owner','admin','warehouse','technician','sales','viewer'));

-- Helper para chequear el rol del usuario actual (útil para permisos en el frontend
-- o en políticas RLS más finas el día de mañana, por ejemplo restringir quién
-- puede cerrar reparaciones o ver rentabilidad).
create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid()
$$;

grant execute on function public.current_user_role() to authenticated;
