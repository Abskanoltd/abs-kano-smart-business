-- Retire the one-time staff invitation-code flow.
-- Existing staff accounts remain active; only the old invitation creation/claim
-- entry points are disabled. Staff accounts are now provisioned by the
-- authenticated create-staff-account Edge Function.
begin;
revoke all on function public.create_staff_invite(text,text) from public, anon, authenticated;
revoke all on function public.claim_staff_invite(uuid) from public, anon, authenticated;
notify pgrst, 'reload schema';
commit;
