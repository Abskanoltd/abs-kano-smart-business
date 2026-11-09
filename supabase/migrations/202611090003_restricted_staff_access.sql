-- Smart Business: secure, restricted staff accounts.
-- Staff never receive direct SELECT access to business tables. They use
-- narrowly scoped SECURITY DEFINER RPCs for product lookup, checkout and receipt.
begin;

create table if not exists public.business_staff (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null unique,
  email text not null,
  full_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invite_code uuid not null unique default gen_random_uuid(),
  email text not null,
  full_name text not null,
  expires_at timestamptz not null default (now() + interval '7 days'),
  used_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now()
);

alter table public.business_staff enable row level security;
alter table public.staff_invites enable row level security;
revoke all on public.business_staff from anon, authenticated;
revoke all on public.staff_invites from anon, authenticated;

alter table public.sales
  add column if not exists created_by uuid;

create or replace function public.create_staff_invite(p_email text, p_full_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_code uuid;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select id into v_business_id from public.businesses where owner_id=auth.uid() limit 1;
  if v_business_id is null then raise exception 'Only the business owner can add staff'; end if;
  if nullif(trim(p_email),'') is null or position('@' in p_email)=0 then
    raise exception 'Enter a valid staff email address';
  end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Enter the staff member name'; end if;

  v_code := gen_random_uuid();
  insert into public.staff_invites(business_id,invite_code,email,full_name,created_by)
  values(v_business_id,v_code,lower(trim(p_email)),trim(p_full_name),auth.uid());
  return v_code::text;
end;
$$;

create or replace function public.list_business_staff()
returns table(id uuid,email text,full_name text,active boolean,created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare v_business_id uuid;
begin
  select b.id into v_business_id from public.businesses b where b.owner_id=auth.uid() limit 1;
  if v_business_id is null then raise exception 'Owner access required'; end if;
  return query
    select s.id,s.email,s.full_name,s.active,s.created_at
    from public.business_staff s
    where s.business_id=v_business_id
    order by s.created_at desc;
end;
$$;

create or replace function public.set_business_staff_active(p_staff_id uuid,p_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_business_id uuid;
begin
  select b.id into v_business_id from public.businesses b where b.owner_id=auth.uid() limit 1;
  if v_business_id is null then raise exception 'Owner access required'; end if;
  update public.business_staff
    set active=p_active
    where id=p_staff_id and business_id=v_business_id;
  if not found then raise exception 'Staff member not found'; end if;
end;
$$;

create or replace function public.claim_staff_invite(p_code uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_inv public.staff_invites%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in before claiming a staff invite'; end if;
  select * into v_inv
    from public.staff_invites
    where invite_code=p_code
      and lower(email)=lower(coalesce(auth.jwt()->>'email',''))
      and used_at is null
      and expires_at>now()
    for update;
  if not found then raise exception 'Invitation code is invalid, expired, already used, or belongs to another email'; end if;

  if exists(select 1 from public.business_staff where user_id=auth.uid() and business_id<>v_inv.business_id) then
    raise exception 'This login is already assigned to another business';
  end if;

  insert into public.business_staff(business_id,user_id,email,full_name,active)
  values(v_inv.business_id,auth.uid(),lower(v_inv.email),v_inv.full_name,true)
  on conflict(user_id) do update
    set email=excluded.email,full_name=excluded.full_name,active=true
    where public.business_staff.business_id=excluded.business_id;

  update public.staff_invites set used_at=now() where id=v_inv.id;
  return true;
end;
$$;

create or replace function public.get_my_staff_access()
returns table(staff_id uuid,business_id uuid,business_name text,staff_name text,staff_email text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id,s.business_id,b.business_name,s.full_name,s.email
  from public.business_staff s
  join public.businesses b on b.id=s.business_id
  where s.user_id=auth.uid() and s.active=true
  limit 1;
$$;

create or replace function public.get_staff_products()
returns table(id uuid,name text,sku text,selling_price numeric,quantity numeric,category_name text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id,p.name,p.sku,p.selling_price,p.quantity::numeric,c.name
  from public.products p
  join public.business_staff s on s.business_id=p.business_id
  left join public.categories c on c.id=p.category_id and c.business_id=p.business_id
  where s.user_id=auth.uid() and s.active=true and p.quantity>0
  order by p.name;
$$;

create or replace function public.record_staff_multi_product_sale(
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_payment_status text default 'paid',
  p_payment_method text default 'cash',
  p_amount_paid numeric default null,
  p_discount numeric default 0,
  p_sale_date timestamptz default now()
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.business_staff%rowtype;
  v_sale_id uuid;
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_price numeric;
  v_stock numeric;
  v_subtotal numeric := 0;
  v_discount numeric := greatest(coalesce(p_discount,0),0);
  v_total numeric;
  v_paid numeric := greatest(coalesce(p_amount_paid,0),0);
  v_has_item_business boolean;
begin
  select * into v_staff from public.business_staff where user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Active staff access required'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one product'; end if;
  if p_payment_status not in ('paid','partial','unpaid') then raise exception 'Invalid payment status'; end if;
  if p_payment_method not in ('cash','transfer','pos') then raise exception 'Invalid payment method'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    if v_qty is null or v_qty<1 or v_price is null or v_price<0 then raise exception 'Invalid product quantity or price'; end if;
    select quantity into v_stock from public.products
      where id=v_product_id and business_id=v_staff.business_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_stock<v_qty then raise exception 'Insufficient stock for selected product'; end if;
    -- Never trust the price supplied by the browser: use the saved selling price.
    select selling_price into v_price from public.products where id=v_product_id and business_id=v_staff.business_id;
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;

  if v_discount>v_subtotal then raise exception 'Discount cannot exceed subtotal'; end if;
  v_total:=v_subtotal-v_discount;
  if p_payment_status='paid' then v_paid:=v_total;
  elsif p_payment_status='unpaid' then v_paid:=0;
  elsif v_paid<=0 or v_paid>=v_total then raise exception 'Part payment must be greater than zero and less than total';
  end if;
  if v_paid>v_total then raise exception 'Amount paid cannot exceed total'; end if;

  insert into public.sales(business_id,customer_id,total_amount,payment_status,sale_date,created_by)
  values(v_staff.business_id,null,v_total,p_payment_status,coalesce(p_sale_date,now()),auth.uid())
  returning id into v_sale_id;

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
    execute 'update public.sales set balance_due=$1 where id=$2' using v_total-v_paid,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='payment_method') then
    execute 'update public.sales set payment_method=$1 where id=$2' using p_payment_method,v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='customer_name_snapshot') then
    execute 'update public.sales set customer_name_snapshot=$1 where id=$2' using coalesce(nullif(trim(p_customer_name),''),'Walk-in'),v_sale_id;
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='customer_phone_snapshot') then
    execute 'update public.sales set customer_phone_snapshot=$1 where id=$2' using nullif(trim(coalesce(p_customer_phone,'')),''),v_sale_id;
  end if;

  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='sale_items' and column_name='business_id') into v_has_item_business;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id and business_id=v_staff.business_id;
    if v_has_item_business then
      insert into public.sale_items(business_id,sale_id,product_id,quantity,unit_price)
      values(v_staff.business_id,v_sale_id,v_product_id,v_qty,v_price);
    else
      insert into public.sale_items(sale_id,product_id,quantity,unit_price)
      values(v_sale_id,v_product_id,v_qty,v_price);
    end if;
    update public.products set quantity=quantity-v_qty where id=v_product_id and business_id=v_staff.business_id;
  end loop;
  return v_sale_id;
end;
$$;

create or replace function public.get_staff_sale_receipt(p_sale_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_staff public.business_staff%rowtype; v_head jsonb; v_items jsonb; v_shop jsonb;
begin
  select * into v_staff from public.business_staff where user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Active staff access required'; end if;
  select to_jsonb(s) into v_head from public.sales s
    where s.id=p_sale_id and s.business_id=v_staff.business_id and s.created_by=auth.uid();
  if v_head is null then raise exception 'Receipt not found'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'quantity',si.quantity,'unit_price',si.unit_price,
    'product',jsonb_build_object('name',p.name)
  ) order by p.name),'[]'::jsonb)
  into v_items
  from public.sale_items si join public.products p on p.id=si.product_id
  where si.sale_id=p_sale_id and p.business_id=v_staff.business_id;
  select to_jsonb(bs) into v_shop from public.business_settings bs where bs.business_id=v_staff.business_id limit 1;
  return jsonb_build_object('head',v_head,'items',v_items,'settings',coalesce(v_shop,'{}'::jsonb),
    'business_name',v_staff.business_name);
end;
$$;

revoke all on function public.create_staff_invite(text,text) from public;
revoke all on function public.list_business_staff() from public;
revoke all on function public.set_business_staff_active(uuid,boolean) from public;
revoke all on function public.claim_staff_invite(uuid) from public;
revoke all on function public.get_my_staff_access() from public;
revoke all on function public.get_staff_products() from public;
revoke all on function public.record_staff_multi_product_sale(jsonb,text,text,text,text,numeric,numeric,timestamptz) from public;
revoke all on function public.get_staff_sale_receipt(uuid) from public;

grant execute on function public.create_staff_invite(text,text) to authenticated;
grant execute on function public.list_business_staff() to authenticated;
grant execute on function public.set_business_staff_active(uuid,boolean) to authenticated;
grant execute on function public.claim_staff_invite(uuid) to authenticated;
grant execute on function public.get_my_staff_access() to authenticated;
grant execute on function public.get_staff_products() to authenticated;
grant execute on function public.record_staff_multi_product_sale(jsonb,text,text,text,text,numeric,numeric,timestamptz) to authenticated;
grant execute on function public.get_staff_sale_receipt(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
