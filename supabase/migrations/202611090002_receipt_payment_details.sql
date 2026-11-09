-- Receipt payment details: store the method and exact payment breakdown.
begin;

alter table public.sales
  add column if not exists payment_method text,
  add column if not exists subtotal numeric(14,2),
  add column if not exists discount_amount numeric(14,2) not null default 0,
  add column if not exists amount_paid numeric(14,2),
  add column if not exists balance_due numeric(14,2),
  add column if not exists customer_name_snapshot text,
  add column if not exists customer_phone_snapshot text;

-- Existing records remain unchanged. New sales will be populated by
-- record_multi_product_sale, which already writes these optional columns
-- when present.

notify pgrst, 'reload schema';
commit;
