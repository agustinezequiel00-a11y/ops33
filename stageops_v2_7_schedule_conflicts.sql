-- StageOPS v2.7 — Detección de conflictos de agenda (montaje/evento/desmontaje se solapan)
-- Migración ADITIVA. Se apoya en stageops_v1.sql (events ya tenía setup_at/teardown_at, sin usar hasta ahora)

-- ============================================================
-- event_schedule_conflicts
--
-- Compara la ventana completa de cada evento (desde que arranca el
-- montaje hasta que termina el desmontaje) contra la de todos los
-- demás eventos, y devuelve los pares que se superponen en el tiempo.
-- No mira equipo, vehículos ni personal — solo fechas. Es una alerta
-- para que una persona revise si en la práctica alcanza el recurso
-- para las dos cosas a la vez.
-- ============================================================
create or replace view public.event_schedule_conflicts as
select
  e1.id as event_id,
  e1.name as event_name,
  e1.setup_at,
  e1.teardown_at,
  e2.id as conflicting_event_id,
  e2.name as conflicting_event_name,
  e2.setup_at as conflicting_setup_at,
  e2.teardown_at as conflicting_teardown_at
from public.events e1
join public.events e2
  on e2.organization_id = e1.organization_id
  and e2.id <> e1.id
  and e1.setup_at is not null and e1.teardown_at is not null
  and e2.setup_at is not null and e2.teardown_at is not null
  and e1.setup_at < e2.teardown_at
  and e2.setup_at < e1.teardown_at
where e1.organization_id = public.current_org_id();
