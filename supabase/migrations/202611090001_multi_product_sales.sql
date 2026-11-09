-- Multi-product sales terminal for Smart Business.
-- Run this migration in Supabase SQL Editor before enabling the new checkout UI.
begin;

create or replace function public.record_multi_product_sale(
  p_items jsonb,
  p_customer_id uuid default null,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_payment_status text default 'paid',
  p_payment_method text default 'cash',
  p_amount_paid numeric default null,
  p_discount numeric default 0,
  p_sale_date timestamptz default now()
) returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_business_id uuid;
  v_sale_id uuid;
  v_total numeric := 0;
  v_subtotal numeric := 0;
  v_discount numeric := greatest(coalesce(p_discount,0),0);
  v_paid numeric := greatest(coalesce(p_amount_paid,0),0);
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_price numeric;
  v_stock integer;
  v_name text;
  v_phone text;
  v_has_biz boolean;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select id into v_business_id from public.businesses where owner_id=auth.uid() limit 1;
  if v_business_id is null then raise exception 'Business workspace not found'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Add at least one product to the cart';
  end if;
  if p_payment_status not in ('paid','partial','unpaid') then raise exception 'Invalid payment status'; end if;
  if p_payment_method not in ('cash','transfer','pos') then raise exception 'Invalid payment method'; end if;
  if v_discount < 0 then raise exception 'Discount cannot be negative'; end if;

  if p_customer_id is not null then
    select name, phone into v_name, v_phone from public.customers
    where id=p_customer_id and business_id=v_business_id;
    if not found then raise exception 'Customer not found in this business'; end if;
  else
    v_name := nullif(trim(coalesce(p_customer_name,'')),'');
    v_phone := nullif(trim(coalesce(p_customer_phone,'')),'');
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    if v_qty is null or v_qty < 1 or v_price is null or v_price < 0 then
      raise exception 'Invalid item quantity or price';
    end if;
    select quantity into v_stock from public.products
      where id=v_product_id and business_id=v_business_id for update;
    if not found then raise exception 'A selected product was not found'; end if;
    if v_stock < v_qty then raise exception 'Insufficient stock for product %',v_product_id; end if;
    v_subtotal := v_subtotal + (v_qty*v_price);
  end loop;

  if v_discount > v_subtotal then raise exception 'Discount cannot exceed subtotal'; end if;
  v_total := v_subtotal-v_discount;
  if p_payment_status='paid' then v_paid:=v_total;
  elsif p_payment_status='unpaid' then v_paid:=0;
  else
    if v_paid<=0 or v_paid>=v_total then raise exception 'Part payment must be greater than zero and less than total'; end if;
  end if;
  if v_paid>v_total then raise exception 'Amount paid cannot exceed total'; end if;

  insert into public.sales(business_id,customer_id,total_amount,payment_status,sale_date)
  values(v_business_id,p_customer_id,v_total,p_payment_status,coalesce(p_sale_date,now()))
  returning id into v_sale_id;

  -- Populate optional receipt/payment columns only when they exist in this project's schema.
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='subtotal') then
    execute 'update public.sales set subtotal=$1 where id=$2' using v_subtotal,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='discount_amount') then
    execute 'update public.sales set discount_amount=$1 where id=$2' using v_discount,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='amount_paid') then
    execute 'update public.sales set amount_paid=$1 where id=$2' using v_paid,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='balance_due') then
    execute 'update public.sales set balance_due=$1 where id=$2' using (v_total-v_paid),v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='payment_method') then
    execute 'update public.sales set payment_method=$1 where id=$2' using p_payment_method,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='customer_name_snapshot') then
    execute 'update public.sales set customer_name_snapshot=$1 where id=$2' using coalesce(v_name,'Walk-in'),v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='customer_phone_snapshot') then
    execute 'update public.sales set customer_phone_snapshot=$1 where id=$2' using v_phone,v_sale_id;
  end if;

  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='sale_items' and column_name='business_id') into v_has_biz;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    if v_has_biz then
      insert into public.sale_items(business_id,sale_id,product_id,quantity,unit_price)
      values(v_business_id,v_sale_id,v_product_id,v_qty,v_price);
    else
      insert into public.sale_items(sale_id,product_id,quantity,unit_price)
      values(v_sale_id,v_product_id,v_qty,v_price);
    end if;
    update public.products set quantity=quantity-v_qty
      where id=v_product_id and business_id=v_business_id;
  end loop;
  return v_sale_id;
end;
$$;

revoke all on function public.record_multi_product_sale(jsonb,uuid,text,text,text,text,numeric,numeric,timestamptz) from public;
grant execute on function public.record_multi_product_sale(jsonb,uuid,text,text,text,text,numeric,numeric,timestamptz) to authenticated;
commit;

-- Refresh the API schema cache so the new RPC is immediately discoverable.
notify pgrst, 'reload schema';
