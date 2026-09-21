-- StageOPS v1.8 — Resumen por cliente
-- Migración ADITIVA. Se apoya en stageops_v1.sql y stageops_v1_7_reports.sql (event_profitability)

create or replace view public.client_summary as
select
  c.id as client_id,
  c.name,
  c.tax_id,
  c.email,
  c.phone,
  count(e.id) as total_events,
  coalesce(sum(ep.contract_amount), 0) as total_revenue,
  coalesce(sum(ep.margin), 0) as total_margin,
  max(e.event_at) as last_event_at
from public.clients c
left join public.events e on e.client_id = c.id
left join public.event_profitability ep on ep.event_id = e.id
where c.organization_id = public.current_org_id()
group by c.id, c.name, c.tax_id, c.email, c.phone;
