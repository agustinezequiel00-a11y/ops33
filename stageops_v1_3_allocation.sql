-- StageOPS v1.3 — Asignación óptima de stock entre lotes (best fit)
-- Migración ADITIVA. Se apoya en stageops_v1.sql

-- ============================================================
-- suggest_stock_allocation
--
-- Dado un producto, un depósito y una cantidad necesaria, devuelve
-- de qué lote(s) conviene tomar el stock para cubrirla, priorizando
-- dejar los lotes grandes lo más intactos posible.
--
-- Lógica:
--   1. Si UN SOLO lote alcanza por sí solo, se elige el más chico
--      de los que alcanzan (best fit) — así no se toca un lote grande
--      si uno chico ya cubre la necesidad.
--   2. Si ningún lote alcanza solo, se combinan empezando por el más
--      grande (para minimizar la cantidad de lotes distintos usados).
-- ============================================================
create or replace function public.suggest_stock_allocation(
  p_product_id uuid,
  p_warehouse_id uuid,
  p_needed_qty numeric
) returns table(
  lot_id uuid,
  lot_code text,
  allocate_qty numeric,
  remaining_after numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_remaining numeric := p_needed_qty;
  rec record;
  v_best_fit record;
begin
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'No organization context for current user';
  end if;
  if p_needed_qty <= 0 then
    raise exception 'Needed quantity must be positive';
  end if;

  -- Paso 1: buscar el lote más chico que alcance solo (best fit)
  select ib.lot_id, l.code, ib.quantity
    into v_best_fit
    from public.inventory_balances ib
    join public.lots l on l.id = ib.lot_id
    where ib.organization_id = v_org
      and ib.product_id = p_product_id
      and ib.warehouse_id = p_warehouse_id
      and ib.state = 'available'
      and ib.quantity >= p_needed_qty
    order by ib.quantity asc
    limit 1;

  if v_best_fit.lot_id is not null then
    lot_id := v_best_fit.lot_id;
    lot_code := v_best_fit.code;
    allocate_qty := p_needed_qty;
    remaining_after := v_best_fit.quantity - p_needed_qty;
    return next;
    return;
  end if;

  -- Paso 2: ningún lote alcanza solo -> combinar, empezando por el más grande
  -- (minimiza la cantidad de lotes distintos que terminan fragmentados)
  for rec in
    select ib.lot_id, l.code, ib.quantity
    from public.inventory_balances ib
    join public.lots l on l.id = ib.lot_id
    where ib.organization_id = v_org
      and ib.product_id = p_product_id
      and ib.warehouse_id = p_warehouse_id
      and ib.state = 'available'
      and ib.quantity > 0
    order by ib.quantity desc
  loop
    exit when v_remaining <= 0;
    lot_id := rec.lot_id;
    lot_code := rec.code;
    allocate_qty := least(rec.quantity, v_remaining);
    remaining_after := rec.quantity - allocate_qty;
    v_remaining := v_remaining - allocate_qty;
    return next;
  end loop;

  if v_remaining > 0 then
    raise notice 'Stock insuficiente: faltan % unidades de % que no se pudieron asignar', v_remaining, p_product_id;
  end if;
end;
$$;

grant execute on function public.suggest_stock_allocation(uuid, uuid, numeric) to authenticated;
