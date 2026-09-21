-- StageOPS v2.1 — Alta masiva de gabinetes con trazabilidad de compra y amortización
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_2_cabinets_simple.sql y v1_7_reports.sql

-- ============================================================
-- 1. Cada gabinete queda vinculado a un lote de compra (para saber
--    cuándo y a qué costo entró) igual que ya pasa con los módulos.
-- ============================================================
alter table public.lots add column if not exists purchase_cost numeric(14,2);
alter table public.cabinets add column if not exists lot_id uuid references public.lots(id) on delete set null;
alter table public.cabinets add column if not exists purchase_cost numeric(14,2);
alter table public.cabinets add column if not exists purchase_date date;

-- ============================================================
-- 2. Cuánto de la factura de un evento corresponde a cada línea
--    reservada (necesario para calcular amortización real, no estimada)
-- ============================================================
alter table public.event_reservations add column if not exists line_amount numeric(14,2);

-- ============================================================
-- 3. Alta masiva: crea N gabinetes con código individual, genera
--    sus slots automáticamente, y los deja asociados a un lote nuevo
--    para poder rastrear la compra en el tiempo.
--    Devuelve la lista de códigos, lista para imprimir etiquetas.
-- ============================================================
create or replace function public.create_cabinets_batch(
  p_cabinet_type_id uuid,
  p_quantity integer,
  p_code_prefix text,
  p_lot_code text,
  p_purchase_cost numeric,
  p_purchase_date date,
  p_warehouse_id uuid
) returns table(
  cabinet_id uuid,
  serial_code text,
  lot_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_product_id uuid;
  v_lot_id uuid;
  v_unit_cost numeric;
  v_cabinet_id uuid;
  i integer;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be positive';
  end if;

  select ct.product_id into v_product_id
    from public.cabinet_types ct
    where ct.id = p_cabinet_type_id and ct.organization_id = v_org;

  if v_product_id is null then
    raise exception 'Cabinet type not found or has no linked product: %', p_cabinet_type_id;
  end if;

  -- Se crea un lote nuevo para esta compra, igual que con módulos
  insert into public.lots(organization_id, product_id, code, lot_type, received_at, purchase_cost)
  values (v_org, v_product_id, p_lot_code, 'purchase', p_purchase_date, p_purchase_cost)
  returning id into v_lot_id;

  v_unit_cost := case when p_quantity > 0 then round(p_purchase_cost / p_quantity, 2) else null end;

  for i in 1..p_quantity loop
    insert into public.cabinets(
      organization_id, cabinet_type_id, serial_code, status,
      current_warehouse_id, lot_id, purchase_cost, purchase_date
    ) values (
      v_org, p_cabinet_type_id, p_code_prefix || '-' || lpad(i::text, 3, '0'), 'available',
      p_warehouse_id, v_lot_id, v_unit_cost, p_purchase_date
    ) returning id into v_cabinet_id;

    perform public.generate_cabinet_slots(v_cabinet_id);

    cabinet_id := v_cabinet_id;
    serial_code := p_code_prefix || '-' || lpad(i::text, 3, '0');
    lot_id := v_lot_id;
    return next;
  end loop;
end;
$$;

grant execute on function public.create_cabinets_batch(uuid, integer, text, text, numeric, date, uuid) to authenticated;

-- ============================================================
-- 4. Vista: historial de reparaciones por gabinete
-- ============================================================
create or replace view public.cabinet_repair_history as
select
  cb.id as cabinet_id,
  cb.serial_code,
  cb.purchase_date,
  cb.purchase_cost,
  count(r.id) as total_repairs,
  coalesce(sum(coalesce(r.labor_cost,0) + coalesce(r.parts_cost,0)), 0) as total_repair_cost,
  max(r.opened_at) as last_repair_at
from public.cabinets cb
left join public.cabinet_slots cs on cs.cabinet_id = cb.id
left join public.repairs r on r.cabinet_slot_id = cs.id
where cb.organization_id = public.current_org_id()
group by cb.id, cb.serial_code, cb.purchase_date, cb.purchase_cost;

-- ============================================================
-- 5. Vista: amortización por lote de compra
--    Usa event_reservations.line_amount (plata real facturada a esa
--    línea), NO un reparto estimado del total del evento.
-- ============================================================
create or replace view public.lot_amortization as
select
  l.id as lot_id,
  l.code,
  l.product_id,
  l.received_at as purchase_date,
  l.purchase_cost,
  coalesce(sum(er.line_amount), 0) as revenue_generated,
  count(distinct er.event_id) as events_used_in,
  case
    when l.purchase_cost > 0
    then round(coalesce(sum(er.line_amount), 0) / l.purchase_cost * 100, 1)
    else null
  end as amortization_pct
from public.lots l
left join public.event_reservations er on er.lot_id = l.id and er.line_amount is not null
where l.organization_id = public.current_org_id()
group by l.id, l.code, l.product_id, l.received_at, l.purchase_cost;
