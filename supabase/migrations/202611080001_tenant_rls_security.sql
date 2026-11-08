-- ABS KANO LTD Smart Business App
-- Tenant isolation and single-owner Super Admin policies.
-- Safe to run after the app's existing tables are created. This migration
-- does not drop tables or records. Review table names before applying.
begin;

create or replace function public.abs_is_business_owner(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.businesses b
    where b.id = p_business_id
      and b.owner_id = auth.uid()
  );
$$;

revoke all on function public.abs_is_business_owner(uuid) from public;
grant execute on function public.abs_is_business_owner(uuid) to authenticated;

-- The single Super Admin account is the owner UUID already configured in
-- the current app. Ordinary users cannot assign this identity to themselves.
drop policy if exists abs_business_owner_or_super_admin on public.businesses;
create policy abs_business_owner_or_super_admin
on public.businesses
for all
to authenticated
using (
  owner_id = auth.uid()
  or auth.uid() = 'eb455b8f-450a-4457-90ea-9b314f1d7c45'::uuid
)
with check (
  owner_id = auth.uid()
  or auth.uid() = 'eb455b8f-450a-4457-90ea-9b314f1d7c45'::uuid
);

-- Apply tenant isolation only to existing app tables that contain business_id.
do $$
declare
  t text;
  app_tables text[] := array[
    'business_settings',
    'products',
    'categories',
    'sales',
    'purchases',
    'customers',
    'suppliers',
    'expenses',
    'sale_items',
    'purchase_items'
  ];
begin
  foreach t in array app_tables loop
    if exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = t
        and column_name = 'business_id'
    ) then
      execute format('alter table public.%I enable row level security', t);
      execute format('drop policy if exists abs_business_tenant_access on public.%I', t);
      execute format(
        'create policy abs_business_tenant_access on public.%I
         for all to authenticated
         using (
           public.abs_is_business_owner(business_id)
           or auth.uid() = %L::uuid
         )
         with check (
           public.abs_is_business_owner(business_id)
           or auth.uid() = %L::uuid
         )',
        t,
        'eb455b8f-450a-4457-90ea-9b314f1d7c45',
        'eb455b8f-450a-4457-90ea-9b314f1d7c45'
      );
    end if;
  end loop;
end $$;

-- Product uploads are stored under <business_id>/<filename>.
-- These policies restrict writes to folders belonging to the signed-in owner.
drop policy if exists abs_owner_upload_product_images on storage.objects;
create policy abs_owner_upload_product_images
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'product-images'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists abs_owner_update_product_images on storage.objects;
create policy abs_owner_update_product_images
on storage.objects
for update to authenticated
using (
  bucket_id = 'product-images'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
    else false
  end
)
with check (
  bucket_id = 'product-images'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists abs_owner_delete_product_images on storage.objects;
create policy abs_owner_delete_product_images
on storage.objects
for delete to authenticated
using (
  bucket_id = 'product-images'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
    else false
  end
);


-- Restrictive policies are intentional: PostgreSQL combines permissive policies
-- with OR. These restrictive checks ensure an older broad policy cannot bypass
-- the tenant boundary established above.
drop policy if exists abs_business_tenant_boundary on public.businesses;
create policy abs_business_tenant_boundary
on public.businesses
as restrictive
for all
to public
using (
  owner_id = auth.uid()
  or auth.uid() = 'eb455b8f-450a-4457-90ea-9b314f1d7c45'::uuid
)
with check (
  owner_id = auth.uid()
  or auth.uid() = 'eb455b8f-450a-4457-90ea-9b314f1d7c45'::uuid
);

do $
declare
  t text;
  app_tables text[] := array[
    'business_settings','products','categories','sales','purchases',
    'customers','suppliers','expenses','sale_items','purchase_items'
  ];
begin
  foreach t in array app_tables loop
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = t and column_name = 'business_id'
    ) then
      execute format('drop policy if exists abs_business_tenant_boundary on public.%I', t);
      execute format(
        'create policy abs_business_tenant_boundary on public.%I
         as restrictive for all to public
         using (public.abs_is_business_owner(business_id) or auth.uid() = %L::uuid)
         with check (public.abs_is_business_owner(business_id) or auth.uid() = %L::uuid)',
        t,
        'eb455b8f-450a-4457-90ea-9b314f1d7c45',
        'eb455b8f-450a-4457-90ea-9b314f1d7c45'
      );
    end if;
  end loop;
end $;

-- Keep unrelated storage buckets unchanged while enforcing the product-images
-- tenant boundary even if another permissive storage policy already exists.
drop policy if exists abs_product_images_tenant_boundary on storage.objects;
create policy abs_product_images_tenant_boundary
on storage.objects
as restrictive
for all
to authenticated
using (
  bucket_id <> 'product-images'
  or (
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
-- IMPORTANT:
-- 1) This migration secures existing business_id tables and product-image writes.
-- 2) It does not create or alter the record_product_sale, record_purchase, or
--    get_public_marketplace RPCs. Those must be checked against the live schema.
-- 3) Apply this file in Supabase SQL Editor, then test each app workflow.

      then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
      else false
    end
  )
)
with check (
  bucket_id <> 'product-images'
  or (
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
-- IMPORTANT:
-- 1) This migration secures existing business_id tables and product-image writes.
-- 2) It does not create or alter the record_product_sale, record_purchase, or
--    get_public_marketplace RPCs. Those must be checked against the live schema.
-- 3) Apply this file in Supabase SQL Editor, then test each app workflow.

      then public.abs_is_business_owner(((storage.foldername(name))[1])::uuid)
      else false
    end
  )
);

commit;

-- IMPORTANT:
-- 1) This migration secures existing business_id tables and product-image writes.
-- 2) It does not create or alter the record_product_sale, record_purchase, or
--    get_public_marketplace RPCs. Those must be checked against the live schema.
-- 3) Apply this file in Supabase SQL Editor, then test each app workflow.
