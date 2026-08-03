-- Enable the minimum live data required for chat, alerts, approval queues, and feeds.
-- Supabase Realtime still applies the authenticated subscriber's RLS policies.

do $$
declare
  v_table_name text;
begin
  if not exists (
    select 1
    from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) then
    raise notice 'supabase_realtime publication is unavailable; skipping publication setup';
    return;
  end if;

  foreach v_table_name in array array[
    'messages',
    'notifications',
    'membership_applications',
    'organization_memberships',
    'posts',
    'comments',
    'conversations',
    'conversation_reads'
  ]
  loop
    if not exists (
      select 1
      from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table_name
    ) then
      execute pg_catalog.format(
        'alter publication supabase_realtime add table public.%I',
        v_table_name
      );
    end if;
  end loop;
end;
$$;
