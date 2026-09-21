-- StageOPS v3.1 — Multi-moneda para costos, y cotización simple de eventos
-- Migración ADITIVA. Se apoya en stageops_v2_1, v2_3, v2_9 y v3_0

-- ============================================================
-- 1. Tipos de cambio: se cargan a mano (fecha + cotización), no se
--    inventan. Sirven para convertir costos en USD a la moneda base
--    de la organización (la que ya existía en organizations.currency_code).
-- ============================================================
create table if not exists public.exchange_rates(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  from_currency text not null,
  to_currency text not null,
  rate numeric(14,6) not null check (rate > 0),
  effective_date date not null default current_date,
  created_at timestamptz default now(),
  unique(organization_id, from_currency, to_currency, effective_date)
);

alter table public.exchange_rates enable row level security;
create policy "exchange_rates_org_all" on public.exchange_rates
  for all using (organization_id = public.current_org_id())
  with check (organization_id = public.current_org_id());

-- ============================================================
-- 2. Cada lote de compra puede estar cargado en una moneda distinta
--    a la moneda base (típico: equipo importado en USD).
-- ============================================================
alter table public.lots add column if not exists purchase_cost_currency text not null default 'ARS'
  check (purchase_cost_currency in ('ARS','USD','EUR'));

-- ============================================================
-- 3. Función de conversión: usa el tipo de cambio cargado más
--    reciente hasta la fecha pedida. Si no hay ninguno cargado,
--    devuelve NULL en vez de inventar un valor.
-- ============================================================
create or replace function public.convert_to_base_currency(
  p_amount numeric,
  p_from_currency text,
  p_as_of date default current_date
) returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_base text;
  v_rate numeric;
begin
  v_org := public.current_org_id();
  if p_amount is null then
    return null;
  end if;

  select currency_code into v_base from public.organizations where id = v_org;

  if p_from_currency = v_base then
    return p_amount;
  end if;

  select rate into v_rate
    from public.exchange_rates
    where organization_id = v_org
      and from_currency = p_from_currency
      and to_currency = v_base
      and effective_date <= p_as_of
    order by effective_date desc
    limit 1;

  if v_rate is null then
    return null; -- sin tipo de cambio cargado para esa fecha: no se estima, se avisa
  end if;

  return round(p_amount * v_rate, 2);
end;
$$;

grant execute on function public.convert_to_base_currency(numeric, text, date) to authenticated;

-- ============================================================
-- 4. Valor total del stock, convertido a la moneda base de hoy.
--    Responde directamente "¿cuánto vale mi stock ahora mismo?"
-- ============================================================
create or replace view public.stock_value_summary as
select
  public.mask_cost(
    sum(coalesce(public.convert_to_base_currency(l.purchase_cost, l.purchase_cost_currency, current_date), 0))
  ) as total_stock_value,
  (select currency_code from public.organizations where id = public.current_org_id()) as currency,
  count(*) filter (where l.purchase_cost is not null
    and public.convert_to_base_currency(l.purchase_cost, l.purchase_cost_currency, current_date) is null
  ) as lots_missing_exchange_rate
from public.lots l
where l.organization_id = public.current_org_id();

-- ============================================================
-- 5. Las vistas de costo ya existentes ahora también muestran
--    en qué moneda estaba cargado cada uno (el monto sigue protegido,
--    la moneda en sí no es un dato sensible).
-- ============================================================
create or replace view public.lots_display as
select
  id, organization_id, product_id, code, lot_type, parent_lot_id,
  supplier, supplier_id, received_at, technical_notes, active,
  purchase_cost_currency,
  public.mask_cost(purchase_cost) as purchase_cost
from public.lots
where organization_id = public.current_org_id();

create or replace view public.supplier_purchase_history as
select
  l.id as lot_id,
  l.supplier_id,
  l.code as lot_code,
  p.name as product_name,
  l.received_at,
  coalesce(cb.unit_count, 0) + coalesce(su.unit_count, 0) as units_received,
  l.purchase_cost_currency,
  public.mask_cost(l.purchase_cost) as purchase_cost
from public.lots l
join public.products p on p.id = l.product_id
left join (select lot_id, count(*) as unit_count from public.cabinets group by lot_id) cb on cb.lot_id = l.id
left join (select lot_id, count(*) as unit_count from public.serial_units group by lot_id) su on su.lot_id = l.id
where l.organization_id = public.current_org_id()
  and l.supplier_id is not null;

create or replace view public.lot_amortization as
select
  l.id as lot_id,
  l.code,
  l.product_id,
  l.received_at as purchase_date,
  l.purchase_cost_currency,
  public.mask_cost(l.purchase_cost) as purchase_cost,
  public.mask_cost(coalesce(sum(er.line_amount), 0)) as revenue_generated,
  count(distinct er.event_id) as events_used_in,
  case
    when l.purchase_cost > 0
    then round(
      coalesce(sum(er.line_amount), 0)
      / nullif(public.convert_to_base_currency(l.purchase_cost, l.purchase_cost_currency, current_date), 0)
      * 100, 1)
    else null
  end as amortization_pct
from public.lots l
left join public.event_reservations er on er.lot_id = l.id and er.line_amount is not null
where l.organization_id = public.current_org_id()
group by l.id, l.code, l.product_id, l.received_at, l.purchase_cost_currency, l.purchase_cost;

-- ============================================================
-- 6. Cotización simple de eventos: moneda del contrato, y una
--    etapa de "presupuesto" previa a la confirmación. No genera
--    ningún PDF ni propuesta — solo deja registrado el estado.
-- ============================================================
alter table public.events add column if not exists contract_currency text not null default 'ARS'
  check (contract_currency in ('ARS','USD','EUR'));
alter table public.events add column if not exists quote_valid_until date;

alter table public.events drop constraint if exists events_status_check;
alter table public.events add constraint events_status_check
  check (status in ('draft','quoted','confirmed','in_progress','completed','cancelled'));

create or replace view public.events_display as
select
  id, organization_id, client_id, branch_id, name, location,
  setup_at, event_at, teardown_at, status, notes, created_at,
  contract_currency, quote_valid_until,
  public.mask_cost(contract_amount) as contract_amount
from public.events
where organization_id = public.current_org_id();
