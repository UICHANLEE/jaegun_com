-- Make the anonymous signup directory honor the caller's RLS context.
-- The underlying table remains column-restricted for anon: only the same five
-- values intentionally exposed by the directory view are selectable.

alter view public.public_organization_directory
  set (security_invoker = true, security_barrier = true);

drop policy if exists organizations_select_directory_anon
  on public.organizations;

create policy organizations_select_directory_anon
on public.organizations
for select
to anon
using (
  status in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  )
);

revoke all on table public.organizations from anon;
grant select (id, slug, display_name, presbytery, status)
  on table public.organizations
  to anon;

revoke all on table public.public_organization_directory
  from public, anon, authenticated;
grant select on table public.public_organization_directory
  to anon, authenticated;

comment on view public.public_organization_directory is
  'Anonymous-safe, security-invoker signup directory exposing only id, slug, display_name, presbytery, and status.';
