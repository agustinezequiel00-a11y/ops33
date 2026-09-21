-- StageOPS v1.6 — Asignación automática de series, minimizando cases fragmentados
-- Migración ADITIVA. Se apoya en stageops_v1.sql, v1_1_movements.sql y v1_5_case_weights.sql

-- ============================================================
-- suggest_serial_allocation
--
-- Dado un producto, lote, depósito y cantidad necesaria, sugiere
-- QUÉ números de serie puntuales usar, priorizando en este orden:
--   1. Módulos sueltos (sin flight case asignado) — no fragmentan nada.
--   2. Flight cases completos que entren enteros en lo que falta.
--   3. Como último recurso, UN SOLO flight case parcial (el más chico
--      que alcance) para cubrir el resto — nunca más de uno fragmentado.
-- ============================================================
create or replace function public.suggest_serial_allocation(
  p_product_id uuid,
  p_lot_id uuid,
  p_warehouse_id uuid,
  p_needed_qty integer
) returns table(
  serial_unit_id uuid,
  serial_code text,
  flight_case_id uuid,
  case_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_remaining integer := p_needed_qty;
  rec record;
  su_rec record;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;
  if p_needed_qty <= 0 then
    raise exception 'Needed quantity must be positive';
  end if;

  -- Paso 1: módulos sueltos, sin flight case
  for su_rec in
    select id, serial_code
    from public.serial_units
    where organization_id = v_org and product_id = p_product_id and lot_id = p_lot_id
      and current_warehouse_id = p_warehouse_id and status = 'available'
      and current_flight_case_id is null
    order by serial_code
  loop
    exit when v_remaining <= 0;
    serial_unit_id := su_rec.id;
    serial_code := su_rec.serial_code;
    flight_case_id := null;
    case_code := null;
    return next;
    v_remaining := v_remaining - 1;
  end loop;

  if v_remaining <= 0 then
    return;
  end if;

  -- Paso 2: flight cases completos que entren enteros, de mayor a menor
  for rec in
    select fc.id as fcid, fc.code, count(*) as cnt
    from public.serial_units su
    join public.flight_cases fc on fc.id = su.current_flight_case_id
    where su.organization_id = v_org and su.product_id = p_product_id and su.lot_id = p_lot_id
      and su.current_warehouse_id = p_warehouse_id and su.status = 'available'
    group by fc.id, fc.code
    order by count(*) desc
  loop
    exit when v_remaining <= 0;
    if rec.cnt <= v_remaining then
      for su_rec in
        select id, serial_code from public.serial_units
        where current_flight_case_id = rec.fcid and status = 'available'
          and organization_id = v_org and product_id = p_product_id and lot_id = p_lot_id
          and current_warehouse_id = p_warehouse_id
        order by serial_code
      loop
        serial_unit_id := su_rec.id;
        serial_code := su_rec.serial_code;
        flight_case_id := rec.fcid;
        case_code := rec.code;
        return next;
      end loop;
      v_remaining := v_remaining - rec.cnt;
    end if;
  end loop;

  if v_remaining <= 0 then
    return;
  end if;

  -- Paso 3: un único case parcial (best fit: el más chico que todavía alcance)
  select fc.id as fcid, fc.code
    into rec
    from public.serial_units su
    join public.flight_cases fc on fc.id = su.current_flight_case_id
    where su.organization_id = v_org and su.product_id = p_product_id and su.lot_id = p_lot_id
      and su.current_warehouse_id = p_warehouse_id and su.status = 'available'
    group by fc.id, fc.code
    having count(*) >= v_remaining
    order by count(*) asc
    limit 1;

  if rec.fcid is null then
    -- ningún case alcanza solo -> usar el más grande disponible como último recurso
    select fc.id as fcid, fc.code
      into rec
      from public.serial_units su
      join public.flight_cases fc on fc.id = su.current_flight_case_id
      where su.organization_id = v_org and su.product_id = p_product_id and su.lot_id = p_lot_id
        and su.current_warehouse_id = p_warehouse_id and su.status = 'available'
      group by fc.id, fc.code
      order by count(*) desc
      limit 1;
  end if;

  if rec.fcid is null then
    raise notice 'Stock insuficiente: faltan % unidades de las % pedidas', v_remaining, p_needed_qty;
    return;
  end if;

  for su_rec in
    select id, serial_code from public.serial_units
    where current_flight_case_id = rec.fcid and status = 'available'
      and organization_id = v_org and product_id = p_product_id and lot_id = p_lot_id
      and current_warehouse_id = p_warehouse_id
    order by serial_code
    limit v_remaining
  loop
    serial_unit_id := su_rec.id;
    serial_code := su_rec.serial_code;
    flight_case_id := rec.fcid;
    case_code := rec.code;
    return next;
  end loop;
end;
$$;

grant execute on function public.suggest_serial_allocation(uuid, uuid, uuid, integer) to authenticated;
