-- Correct the production Korean profanity term without mutating the already
-- applied 016 migration. Keep the same in-memory, no-retention safety boundary.

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
    '아동성착취',
    '미성년자성착취',
    '아동음란물',
    '미성년자음란물',
    'childporn',
    'childsexualabusematerial',
    'sexualabuseofchildren',
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
    '씨발',
    '개새끼',
    '좆같',
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

revoke all on function private.ugc_text_is_allowed(text)
  from public, anon, authenticated;
