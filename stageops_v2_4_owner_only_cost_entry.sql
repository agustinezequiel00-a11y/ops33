-- StageOPS v2.4 — Carga de costo de compra en un paso separado, restringida al dueño
-- Migración ADITIVA. Se apoya en stageops_v2_1_cabinet_traceability.sql y v2_3_cost_visibility.sql

-- ============================================================
-- 1. Se bloquea también la ESCRITURA directa de estas columnas
--    (v2_3 ya había bloqueado la lectura). Sin esto, alguien podría
--    escribir un costo a ciegas aunque no pueda verlo después.
-- ============================================================
revoke update (purchase_cost) on public.lots from authenticated;
revoke update (purchase_cost) on public.cabinets from authenticated;
revoke update (purchase_cost) on public.serial_units from authenticated;

-- ============================================================
-- 2. Única vía para cargar el costo de un lote: esta función,
--    que primero chequea que quien la llama sea 'owner'.
--    Recalcula el costo unitario y lo reparte en cabinets/serial_units
--    de ese lote (por si el ingreso ya había creado las unidades sin costo).
-- ============================================================
create or replace function public.set_lot_purchase_cost(
  p_lot_id uuid,
  p_purchase_cost numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_count integer;
begin
  if public.current_user_role() <> 'owner' then
    raise exception 'Solo el dueño puede cargar el costo de compra';
  end if;

  select organization_id into v_org from public.lots where id = p_lot_id;
  if v_org is null then
    raise exception 'Lot not found: %', p_lot_id;
  end if;
  if p_purchase_cost < 0 then
    raise exception 'Purchase cost must not be negative';
  end if;

  update public.lots set purchase_cost = p_purchase_cost where id = p_lot_id;

  select count(*) into v_count from public.cabinets where lot_id = p_lot_id;
  if v_count > 0 then
    update public.cabinets
      set purchase_cost = round(p_purchase_cost / v_count, 2)
      where lot_id = p_lot_id;
  end if;

  select count(*) into v_count from public.serial_units where lot_id = p_lot_id;
  if v_count > 0 then
    update public.serial_units
      set purchase_cost = round(p_purchase_cost / v_count, 2)
      where lot_id = p_lot_id;
  end if;
end;
$$;

grant execute on function public.set_lot_purchase_cost(uuid, numeric) to authenticated;

-- ============================================================
-- 3. Vista de referencia: lotes recibidos sin costo cargado todavía
--    (la pantalla "Costos pendientes de carga" sale de acá)
-- ============================================================
create or replace view public.lots_pending_cost as
select l.id as lot_id, l.code, l.product_id, l.received_at,
  coalesce(cb.cabinet_count, 0) + coalesce(su.serial_count, 0) as unit_count
from public.lots l
left join (select lot_id, count(*) as cabinet_count from public.cabinets group by lot_id) cb on cb.lot_id = l.id
left join (select lot_id, count(*) as serial_count from public.serial_units group by lot_id) su on su.lot_id = l.id
where l.organization_id = public.current_org_id()
  and l.purchase_cost is null;
