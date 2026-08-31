-- App Store UGC safety gate.
--
-- This intentionally remains a small, deterministic deny-list for only the
-- clearest severe abuse categories.  It is a write-time guard, not a replacement
-- for the existing report, block, scoped moderation, or support flows.  Rejected
-- text is never copied into audit/moderation tables and the error is deliberately
-- generic so sensitive content is not echoed into client or infrastructure logs.

create or replace function private.ugc_text_is_allowed(p_text text)
returns boolean
language plpgsql
immutable
parallel safe
set search_path = pg_catalog
as $$
declare
  v_compact text;
  v_term text;
begin
  if p_text is null then
    return true;
  end if;

  -- Ignore separators commonly used to evade a basic safety filter, including
  -- zero-width characters.  A limited leetspeak fold is applied only to this
  -- in-memory comparison value; the user's text is never retained or rewritten.
  v_compact := pg_catalog.lower(p_text);
  v_compact := pg_catalog.translate(
    v_compact,
    pg_catalog.chr(8203)
      || pg_catalog.chr(8204)
      || pg_catalog.chr(8205)
      || pg_catalog.chr(8288)
      || pg_catalog.chr(65279),
    ''
  );
  v_compact := pg_catalog.translate(v_compact, '013457!', 'oieasti');
  v_compact := pg_catalog.regexp_replace(
    v_compact,
    '[[:space:][:punct:]]+',
    '',
    'g'
  );

  foreach v_term in array array[
    -- Child sexual exploitation terminology.
    '아동성착취',
    '미성년자성착취',
    '아동음란물',
    '미성년자음란물',
    'childporn',
    'childsexualabusematerial',
    'sexualabuseofchildren',
    -- Direct, targeted threats of killing or sexual violence.
    '너를죽여버리',
    '널죽여버리',
    '너를죽이겠다',
    '널죽이겠다',
    '네가족을죽이',
    '니가족을죽이',
    'iwillkillyou',
    'imgonnakillyou',
    'iamgoingtokillyou',
    '너를강간',
    '널강간',
    '강간하고싶',
    'rapeachild',
    'rapekids',
    -- Unambiguously abusive profanity in a member-directed community context.
    '씨발',
    '개새끼',
    '죆같',
    'fuckyou'
  ]::text[]
  loop
    if pg_catalog.strpos(v_compact, v_term) > 0 then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

comment on function private.ugc_text_is_allowed(text) is
  'In-memory minimal UGC deny-list comparison. It stores, audits, and returns no submitted text.';

create or replace function private.enforce_ugc_text_safety()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_text text;
begin
  if tg_table_name = 'posts' then
    v_text := coalesce(new.title, '') || pg_catalog.chr(10) || coalesce(new.body, '');
  elsif tg_table_name in ('comments', 'messages') then
    v_text := new.body;
  else
    raise exception 'ugc_safety_trigger_misconfigured' using errcode = '55000';
  end if;

  if not private.ugc_text_is_allowed(v_text) then
    raise exception 'unsafe_content_rejected' using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function private.enforce_ugc_text_safety() is
  'Rejects clearly severe abusive post, comment, and message text at the authoritative database write boundary without logging the submitted text.';

drop trigger if exists posts_enforce_ugc_text_safety on public.posts;
create trigger posts_enforce_ugc_text_safety
before insert or update of title, body on public.posts
for each row execute function private.enforce_ugc_text_safety();

drop trigger if exists comments_enforce_ugc_text_safety on public.comments;
create trigger comments_enforce_ugc_text_safety
before insert or update of body on public.comments
for each row execute function private.enforce_ugc_text_safety();

drop trigger if exists messages_enforce_ugc_text_safety on public.messages;
create trigger messages_enforce_ugc_text_safety
before insert or update of body on public.messages
for each row execute function private.enforce_ugc_text_safety();

revoke all on function private.ugc_text_is_allowed(text)
  from public, anon, authenticated;
revoke all on function private.enforce_ugc_text_safety()
  from public, anon, authenticated;
