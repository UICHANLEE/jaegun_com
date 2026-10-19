-- Community identity is projected on the server; raw author-bearing rows are not a client API.
alter table public.posts add column is_anonymous boolean not null default false;
alter table public.posts add column revision bigint not null default 1 check(revision > 0);
create function private.enforce_board_anonymity() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 new.is_anonymous:=exists(select 1 from public.boards where id=new.board_id and slug='anonymous-qa');
 return new;
end; $$;
revoke all on function private.enforce_board_anonymity() from public,anon,authenticated;
create trigger posts_enforce_board_anonymity before insert or update on public.posts for each row execute function private.enforce_board_anonymity();
create table private.post_reactions (
 post_id uuid not null references public.posts(id) on delete cascade,
 actor_id uuid not null references public.profiles(id) on delete cascade,
 kind text not null check(kind in ('amen','prayer','receipt')),
 post_revision bigint not null default 1 check(post_revision>0),
 created_at timestamptz not null default statement_timestamp(),
 primary key(post_id,actor_id,kind)
);
alter table private.post_reactions enable row level security;
revoke all on private.post_reactions from public,anon,authenticated;
create table private.anonymous_author_blocks(
 id uuid primary key default gen_random_uuid(),
 blocker_id uuid not null references public.profiles(id) on delete cascade,
 blocked_user_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default statement_timestamp(),
 unique(blocker_id,blocked_user_id),check(blocker_id<>blocked_user_id)
);
alter table private.anonymous_author_blocks enable row level security;
revoke all on private.anonymous_author_blocks from public,anon,authenticated;
create or replace function private.user_has_blocked(p_actor_id uuid,p_target_user_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select p_actor_id is not null and p_target_user_id is not null and
 (exists(select 1 from public.user_blocks b where b.blocker_id=p_actor_id and b.blocked_user_id=p_target_user_id)
 or exists(select 1 from private.anonymous_author_blocks b where b.blocker_id=p_actor_id and b.blocked_user_id=p_target_user_id));
$$;
create or replace function private.users_are_blocked(p_left_user_id uuid,p_right_user_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.user_has_blocked(p_left_user_id,p_right_user_id) or private.user_has_blocked(p_right_user_id,p_left_user_id);
$$;
revoke all on public.posts from public,anon,authenticated;
revoke select on public.post_media from public,anon,authenticated;
revoke all on public.content_reports,public.moderation_actions from public,anon,authenticated;
-- Table-level REVOKE alone does not remove independent column grants.
do $$ declare name text; columns text; begin
 foreach name in array array['posts','comments','post_media','content_reports','moderation_actions'] loop
 select string_agg(format('%I',a.attname),',' order by a.attnum) into columns
 from pg_catalog.pg_attribute a where a.attrelid=format('public.%I',name)::regclass and a.attnum>0 and not a.attisdropped;
 execute format('revoke all privileges (%s) on table public.%I from public,anon,authenticated',columns,name);
 end loop;
end $$;
grant select(id,post_id,storage_path,kind,mime_type,byte_size,alt_text,sort_order,width,height,duration_seconds) on public.post_media to authenticated;
revoke select,update,delete on public.comments from public,anon,authenticated;

insert into public.boards(organization_id,slug,name,sort_order,staff_only_posting)
select o.id,b.slug,b.name,b.sort_order,b.staff from public.organizations o cross join
(values ('anonymous-qa','익명 질문·답변',50,false),('official-document','공문',60,true),('family-news','경조사',70,false)) b(slug,name,sort_order,staff)
on conflict (organization_id,slug) where organization_id is not null do nothing;
create function private.create_community_boards() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 insert into public.boards(organization_id,slug,name,sort_order,staff_only_posting) values
 (new.id,'anonymous-qa','익명 질문·답변',50,false),(new.id,'official-document','공문',60,true),(new.id,'family-news','경조사',70,false)
 on conflict (organization_id,slug) where organization_id is not null do nothing;
 return new;
end; $$;
revoke all on function private.create_community_boards() from public,anon,authenticated;
create trigger organizations_community_boards after insert on public.organizations for each row execute function private.create_community_boards();

create function private.community_post_visible(p_id uuid,p_actor uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.has_current_required_consents(p_actor) and exists(select 1 from public.posts p where p.id=p_id and p.status='published'
 and (p.organization_id is null or private.is_active_member(p.organization_id,p_actor))
 and (p.author_id is null or (private.has_current_required_consents(p.author_id) and not private.user_has_blocked(p_actor,p.author_id))));
$$;
revoke all on function private.community_post_visible(uuid,uuid) from public,anon,authenticated;
create or replace function private.can_read_post(p_post_id uuid,p_actor_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.community_post_visible(p_post_id,p_actor_id)
 or (private.has_current_required_consents(p_actor_id) and exists(select 1 from public.posts p where p.id=p_post_id
 and p.author_id=p_actor_id and private.is_active_member(p.organization_id,p_actor_id) and p.status in ('draft','hidden')));
$$;
create function private.owns_community_post(p_post_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.has_current_required_consents(auth.uid()) and exists(select 1 from public.posts p where p.id=p_post_id
 and p.author_id=auth.uid() and private.is_active_member(p.organization_id,auth.uid()) and p.status in ('draft','published'));
$$;
revoke all on function private.owns_community_post(uuid) from public,anon,authenticated;
grant execute on function private.owns_community_post(uuid) to authenticated;
-- Only authors attach or remove media; incident moderation uses audited report RPCs.
revoke update,delete on public.post_media from public,anon,authenticated;
drop policy if exists post_media_insert_authorized on public.post_media;
create policy post_media_insert_authorized on public.post_media for insert to authenticated with check(
 uploader_id=auth.uid() and private.has_current_required_consents(auth.uid())
 and private.post_media_path_matches(post_id,storage_path)
 and private.owns_community_post(post_id));
create function public.list_community_posts(p_post_id uuid default null,p_board_id uuid default null,p_limit integer default 50,p_offset integer default 0)
returns setof jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor();
begin
 if p_limit is null or p_limit not between 1 and 500 or p_offset is null or p_offset<0 then raise exception 'invalid_community_page' using errcode='22023'; end if;
 return query select jsonb_build_object('id',p.id,'organization_id',p.organization_id,'board_id',p.board_id,'board_slug',b.slug,
 'author_id',case when p.is_anonymous then null else p.author_id end,'author_label',case when p.is_anonymous then '익명' else coalesce(p.author_label,(select profile.display_name from public.profiles profile where profile.id=p.author_id and private.can_view_profile(profile.id,actor))) end,
 'is_anonymous',p.is_anonymous,'is_owner',p.author_id=actor,'revision',p.revision,'title',p.title,'body',p.body,'status',p.status,
 'is_system',p.is_system,'is_pinned',p.is_pinned,'allow_comments',p.allow_comments,'published_at',p.published_at,'created_at',p.created_at,
 'amen_count',(select count(*) from private.post_reactions r where r.post_id=p.id and r.kind='amen'),
 'prayer_count',(select count(*) from private.post_reactions r where r.post_id=p.id and r.kind='prayer'),
 'receipt_count',(select count(*) from private.post_reactions r where r.post_id=p.id and r.kind='receipt' and r.post_revision=p.revision),
 'reacted_amen',exists(select 1 from private.post_reactions r where r.post_id=p.id and r.actor_id=actor and r.kind='amen'),
 'reacted_prayer',exists(select 1 from private.post_reactions r where r.post_id=p.id and r.actor_id=actor and r.kind='prayer'),
 'acknowledged',exists(select 1 from private.post_reactions r where r.post_id=p.id and r.actor_id=actor and r.kind='receipt' and r.post_revision=p.revision))
 from public.posts p join public.boards b on b.id=p.board_id
 where (p_post_id is null or p.id=p_post_id) and (p_board_id is null or p.board_id=p_board_id) and private.community_post_visible(p.id,actor)
 order by p.is_pinned desc,p.published_at desc,p.id desc limit p_limit offset p_offset;
end; $$;
create function public.list_community_comments(p_post_ids uuid[],p_comment_id uuid default null,p_limit integer default 500,p_offset integer default 0)
returns setof jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor();
begin
 if p_limit is null or p_limit not between 1 and 1000 or p_offset is null or p_offset<0 or cardinality(p_post_ids)>500 then raise exception 'invalid_comment_page' using errcode='22023'; end if;
 return query select jsonb_build_object('id',c.id,'post_id',c.post_id,'author_id',case when p.is_anonymous then null else c.author_id end,
 'author_label',case when p.is_anonymous then case when c.author_id=p.author_id then '익명 작성자' else '익명 답변' end else (select profile.display_name from public.profiles profile where profile.id=c.author_id and private.can_view_profile(profile.id,actor)) end,'is_owner',c.author_id=actor,'body',c.body,'status',c.status,'created_at',c.created_at)
 from public.comments c join public.posts p on p.id=c.post_id
 where c.post_id=any(p_post_ids) and (p_comment_id is null or c.id=p_comment_id)
 and (c.status='active' or (p_comment_id is not null and c.author_id=actor))
 and private.community_post_visible(p.id,actor) and (c.author_id is null or (private.has_current_required_consents(c.author_id) and not private.user_has_blocked(actor,c.author_id)))
 order by c.created_at,c.id limit p_limit offset p_offset;
end; $$;

-- Notifications must not deanonymize an answer that the board projection hides.
create or replace function private.notify_post_comment() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare post public.posts%rowtype; commenter text;
begin
 select * into post from public.posts where id=new.post_id;
 if post.author_id is null or post.author_id=new.author_id then return new; end if;
 if not post.is_anonymous then select display_name into commenter from public.profiles where id=new.author_id; end if;
 insert into public.notifications(user_id,kind,title,body,entity_type,entity_id,metadata)
 values(post.author_id,'post_comment','새 댓글이 달렸습니다',
 case when post.is_anonymous then '익명 답변이 등록되었습니다.' else coalesce(commenter,'회원')||'님이 게시물에 댓글을 남겼습니다.' end,
 'post',post.id,jsonb_build_object('comment_id',new.id));
 return new;
end; $$;
revoke all on function private.notify_post_comment() from public,anon,authenticated;

create function public.save_community_post_draft(p_post_id uuid,p_expected_author_id uuid,p_organization_id uuid,p_board_id uuid,p_title text,p_body text,p_is_anonymous boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb; slug text;
begin
 if actor is distinct from p_expected_author_id then raise exception 'post_author_session_changed' using errcode='42501'; end if;
 select b.slug into slug from public.boards b where b.id=p_board_id;
 if p_is_anonymous is null or (p_is_anonymous and slug<>'anonymous-qa') then raise exception 'anonymous_board_required' using errcode='22023'; end if;
 result:=public.save_owned_post_draft(p_post_id,p_expected_author_id,p_organization_id,p_board_id,p_title,p_body);
 update public.posts set is_anonymous=(slug='anonymous-qa') where id=p_post_id and author_id=actor and status='draft';
 return result;
end; $$;

create function public.set_post_reaction(p_post_id uuid,p_kind text,p_active boolean,p_expected_actor_id uuid,p_expected_revision bigint default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); slug text; result jsonb; changed integer:=0; revision bigint;
begin
 if p_expected_actor_id is distinct from actor then raise exception 'community_actor_session_changed' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('amen','prayer','receipt') or p_active is null then raise exception 'invalid_post_reaction' using errcode='22023'; end if;
 perform private.consume_rate_limit(actor,'community_reactions',120,60,1);
 perform pg_advisory_xact_lock(hashtextextended('post:'||p_post_id::text,0));
 if not private.community_post_visible(p_post_id,actor) then raise exception 'post_not_found_or_forbidden' using errcode='42501'; end if;
 select b.slug,p.revision into slug,revision from public.posts p join public.boards b on b.id=p.board_id where p.id=p_post_id;
 if p_kind='receipt' and slug<>'official-document' then raise exception 'official_document_required' using errcode='22023'; end if;
 if p_kind='receipt' and p_expected_revision is distinct from revision then raise exception 'document_revision_conflict' using errcode='40001'; end if;
 if p_kind='prayer' and slug<>'prayer' then raise exception 'prayer_board_required' using errcode='22023'; end if;
 if p_active then
 insert into private.post_reactions as existing(post_id,actor_id,kind,post_revision) values(p_post_id,actor,p_kind,revision)
 on conflict(post_id,actor_id,kind) do update set post_revision=excluded.post_revision
 where p_kind='receipt' and existing.post_revision<>excluded.post_revision;
 get diagnostics changed = row_count;
 elsif p_kind<>'receipt' then delete from private.post_reactions where post_id=p_post_id and actor_id=actor and kind=p_kind;
 end if;
 if p_kind='receipt' and p_active and changed>0 then perform private.write_audit(actor,'community.document_acknowledged','post',p_post_id,(select organization_id from public.posts where id=p_post_id),actor,jsonb_build_object('revision',revision)); end if;
 select * into result from public.list_community_posts(p_post_id,null,1,0); return result;
end; $$;

create function public.update_owned_community_post(p_post_id uuid,p_expected_revision bigint,p_title text,p_body text,p_delete boolean default false,p_remove_media_ids uuid[] default '{}',p_add_media jsonb default '[]')
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); post public.posts%rowtype; media jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended('post:'||p_post_id::text,0));
 select * into post from public.posts where id=p_post_id for update;
 if post.id is null or post.author_id is distinct from actor or not private.is_active_member(post.organization_id,actor) or post.is_system then raise exception 'post_owner_required' using errcode='42501'; end if;
 if p_delete and post.status='deleted' then return jsonb_build_object('deleted',true,'revision',post.revision); end if;
 if post.revision is distinct from p_expected_revision or post.status<>'published' then raise exception 'post_revision_conflict' using errcode='40001'; end if;
 perform private.consume_rate_limit(actor,'community_post_edits',20,300,1);
 with detached as (
 delete from public.post_media where post_id=p_post_id and (p_delete or id=any(p_remove_media_ids))
 returning uploader_id,storage_path
 )
 insert into private.media_cleanup_items(uploader_id,bucket_id,storage_path,reason)
 select uploader_id,'community-media',storage_path,'user_abandoned' from detached
 where uploader_id=actor and not exists(select 1 from public.media_upload_intents i where i.approved_path=detached.storage_path and i.approved_bucket_id='community-media')
 on conflict(bucket_id,storage_path) do nothing;
 if p_delete then update public.posts set status='deleted',deleted_at=statement_timestamp(),revision=revision+1 where id=p_post_id;
 else
 if p_title is null or char_length(btrim(p_title)) not between 1 and 200 or p_body is null or char_length(btrim(p_body)) not between 1 and 50000 then raise exception 'invalid_post_input' using errcode='22023'; end if;
 if p_add_media is null or jsonb_typeof(p_add_media)<>'array' or jsonb_array_length(p_add_media)>6 then raise exception 'invalid_post_media' using errcode='22023'; end if;
 if (select count(*) from public.post_media where post_id=p_post_id)+jsonb_array_length(p_add_media)>6 then raise exception 'post_media_limit_exceeded' using errcode='22023'; end if;
 for media in select value from jsonb_array_elements(p_add_media) loop
 if not private.post_media_path_matches(p_post_id,media->>'storage_path') or not exists(
 select 1 from storage.objects o where o.bucket_id='community-media' and o.name=media->>'storage_path' and coalesce(o.owner_id,o.owner::text)=actor::text)
 then raise exception 'post_media_owner_required' using errcode='42501'; end if;
 insert into public.post_media(post_id,uploader_id,storage_path,kind,mime_type,byte_size,alt_text,sort_order)
 values(p_post_id,actor,media->>'storage_path',(media->>'kind')::public.media_kind,media->>'mime_type',(media->>'byte_size')::bigint,left(media->>'file_name',1000),(select count(*) from public.post_media where post_id=p_post_id));
 end loop;
 update public.posts set title=btrim(p_title),body=btrim(p_body),edited_at=statement_timestamp(),revision=revision+1 where id=p_post_id;
 end if;
 perform private.write_audit(actor,case when p_delete then 'community.post_deleted' else 'community.post_edited' end,'post',p_post_id,post.organization_id,actor,jsonb_build_object('revision',post.revision));
 return jsonb_build_object('deleted',p_delete,'revision',post.revision+1);
end; $$;
create function public.block_community_post_author(p_post_id uuid,p_expected_actor_id uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); target uuid; anonymous boolean;
begin
 if p_expected_actor_id is distinct from actor then raise exception 'community_actor_session_changed' using errcode='42501'; end if;
 select author_id,is_anonymous into target,anonymous from public.posts where id=p_post_id and (organization_id is null or private.is_active_member(organization_id,actor));
 if target is null or target=actor then raise exception 'invalid_block_target' using errcode='22023'; end if;
 if private.user_has_blocked(actor,target) then return true; end if;
 if not private.community_post_visible(p_post_id,actor) then raise exception 'post_not_found_or_forbidden' using errcode='42501'; end if;
 if anonymous then
 perform private.consume_rate_limit(actor,'anonymous_author_block',30,600,1);
 insert into private.anonymous_author_blocks(blocker_id,blocked_user_id) values(actor,target) on conflict do nothing;
 if found then perform private.write_audit(actor,'community.anonymous_author_blocked','post',p_post_id,(select organization_id from public.posts where id=p_post_id),null,'{}'::jsonb); end if;
 else perform public.block_user(target,'게시글 작성자 차단');
 end if;
 return true;
end; $$;
revoke all on function public.list_community_posts(uuid,uuid,integer,integer),public.list_community_comments(uuid[],uuid,integer,integer),public.save_community_post_draft(uuid,uuid,uuid,uuid,text,text,boolean),public.set_post_reaction(uuid,text,boolean,uuid,bigint),public.update_owned_community_post(uuid,bigint,text,text,boolean,uuid[],jsonb),public.block_community_post_author(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_community_posts(uuid,uuid,integer,integer),public.list_community_comments(uuid[],uuid,integer,integer),public.save_community_post_draft(uuid,uuid,uuid,uuid,text,text,boolean),public.set_post_reaction(uuid,text,boolean,uuid,bigint),public.update_owned_community_post(uuid,bigint,text,text,boolean,uuid[],jsonb),public.block_community_post_author(uuid,uuid) to authenticated;
create function public.block_community_comment_author(p_comment_id uuid,p_expected_actor_id uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); target uuid; anonymous boolean; post_id uuid; org uuid;
begin
 if p_expected_actor_id is distinct from actor then raise exception 'community_actor_session_changed' using errcode='42501'; end if;
 select c.author_id,p.is_anonymous,p.id,p.organization_id into target,anonymous,post_id,org
 from public.comments c join public.posts p on p.id=c.post_id where c.id=p_comment_id and c.status='active'
 and (p.organization_id is null or private.is_active_member(p.organization_id,actor));
 if target is null or target=actor then raise exception 'invalid_block_target' using errcode='22023'; end if;
 if private.user_has_blocked(actor,target) then return true; end if;
 if not private.community_post_visible(post_id,actor) then raise exception 'post_not_found_or_forbidden' using errcode='42501'; end if;
 if anonymous then
 perform private.consume_rate_limit(actor,'anonymous_author_block',30,600,1);
 insert into private.anonymous_author_blocks(blocker_id,blocked_user_id) values(actor,target) on conflict do nothing;
 if found then perform private.write_audit(actor,'community.anonymous_author_blocked','comment',p_comment_id,org,null,'{}'::jsonb); end if;
 else perform public.block_user(target,'댓글 작성자 차단');
 end if;
 return true;
end; $$;
revoke all on function public.block_community_comment_author(uuid,uuid) from public,anon,authenticated;
grant execute on function public.block_community_comment_author(uuid,uuid) to authenticated;
create function public.list_my_anonymous_blocks() returns setof jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor();
begin
 return query select jsonb_build_object('id',b.id,'label','익명 작성자','created_at',b.created_at)
 from private.anonymous_author_blocks b where b.blocker_id=actor order by b.created_at desc,b.id;
end; $$;
create function public.remove_my_anonymous_block(p_block_id uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); changed boolean;
begin
 delete from private.anonymous_author_blocks where id=p_block_id and blocker_id=actor;
 changed:=found;
 if changed then perform private.write_audit(actor,'community.anonymous_author_unblocked','anonymous_block',p_block_id,null,null,'{}'::jsonb); end if;
 return true;
end; $$;
revoke all on function public.list_my_anonymous_blocks(),public.remove_my_anonymous_block(uuid) from public,anon,authenticated;
grant execute on function public.list_my_anonymous_blocks(),public.remove_my_anonymous_block(uuid) to authenticated;

-- The moderation queue itself must not be an author investigation endpoint.
alter function public.list_moderation_reports(text,integer) set schema private;
alter function private.list_moderation_reports(text,integer) rename to list_moderation_reports_before_anonymity;
revoke all on function private.list_moderation_reports_before_anonymity(text,integer) from public,anon,authenticated;
create function public.list_moderation_reports(p_status text default null,p_limit integer default 50)
returns table(id uuid,organization_id uuid,organization_name text,target_type text,target_id uuid,reported_user_id uuid,target_author_name text,reporter_display_name text,reason_code text,details text,evidence_summary text,status text,created_at timestamptz,resolved_at timestamptz,resolution_reason text)
language sql stable security definer set search_path=pg_catalog as $$
 select r.id,r.organization_id,r.organization_name,r.target_type,r.target_id,
 null::uuid,'신고 대상'::text,r.reporter_display_name,r.reason_code,null::text,
 '사건 열람에는 사유와 최근 본인 확인이 필요합니다.'::text,r.status,r.created_at,r.resolved_at,r.resolution_reason
 from private.list_moderation_reports_before_anonymity(p_status,p_limit) r;
$$;
revoke all on function public.list_moderation_reports(text,integer) from public,anon,authenticated;
grant execute on function public.list_moderation_reports(text,integer) to authenticated;

-- Realtime emits scope-only invalidations, never the author-bearing source rows.
create table public.community_board_changes (
 id bigint generated always as identity primary key,
 organization_id uuid references public.organizations(id) on delete cascade,
 created_at timestamptz not null default statement_timestamp()
);
create index community_board_changes_scope_retention_idx on public.community_board_changes(organization_id,created_at,id);
alter table public.community_board_changes enable row level security;
revoke all on public.community_board_changes from public,anon,authenticated;
grant select(id,organization_id,created_at) on public.community_board_changes to authenticated;
create policy community_board_changes_scoped on public.community_board_changes for select to authenticated using(
 private.has_current_required_consents(auth.uid()) and (organization_id is null or private.is_active_member(organization_id,auth.uid())));
create function private.emit_community_board_change() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare entity uuid; org uuid;
begin
 if tg_table_name='posts' then
 if tg_op='DELETE' then org:=old.organization_id; else org:=new.organization_id; end if;
 else
 if tg_op='DELETE' then entity:=old.post_id; else entity:=new.post_id; end if;
 select organization_id into org from public.posts where id=entity;
 end if;
 insert into public.community_board_changes(organization_id) values(org);
 delete from public.community_board_changes where id in (select id from public.community_board_changes where organization_id is not distinct from org and created_at<statement_timestamp()-interval '1 day' order by id limit 100);
 if tg_op='DELETE' then return old; end if; return new;
end; $$;
revoke all on function private.emit_community_board_change() from public,anon,authenticated;
create trigger posts_community_change after insert or update or delete on public.posts for each row execute function private.emit_community_board_change();
create trigger comments_community_change after insert or update or delete on public.comments for each row execute function private.emit_community_board_change();
create trigger post_media_community_change after insert or update or delete on public.post_media for each row execute function private.emit_community_board_change();
create trigger reactions_community_change after insert or update or delete on private.post_reactions for each row execute function private.emit_community_board_change();
do $$ declare name text; begin
 if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime' and not puballtables) then
 foreach name in array array['posts','comments','post_media'] loop
 if exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=name) then
 execute format('alter publication supabase_realtime drop table public.%I',name);
 end if;
 end loop;
 alter publication supabase_realtime add table public.community_board_changes;
 end if;
end $$;
