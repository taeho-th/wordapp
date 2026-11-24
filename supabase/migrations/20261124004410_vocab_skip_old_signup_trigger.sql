-- 선생님으로 미리 등록해 둘 이메일. 이 이메일로 계정이 생기면 자동으로 vocab_teachers 에 들어감
create table public.vocab_teacher_emails (
  email text primary key check (email = lower(trim(email)))
);
alter table public.vocab_teacher_emails enable row level security;
comment on table public.vocab_teacher_emails is '선생님 이메일 허용 목록. 브라우저 허용 규칙 없음 — 가입 트리거만 읽음';

-- 예전 퀴즈 앱 가입 트리거: 단어앱 계정(익명 학생, 등록된 선생님 이메일)만 건너뜀. 나머지는 예전과 같음
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- 단어앱 학생 (익명 로그인)
  if new.is_anonymous then
    return new;
  end if;

  -- 단어앱 선생님
  if new.email is not null and exists (select 1 from public.vocab_teacher_emails e where e.email = lower(new.email)) then
    insert into public.vocab_teachers (user_id) values (new.id) on conflict do nothing;
    return new;
  end if;

  -- 이하 예전 퀴즈 앱 규칙 그대로
  if coalesce((new.raw_user_meta_data ->> 'privacy_agreed')::boolean, false) is not true then
    raise exception '개인정보 안내에 동의해야 가입할 수 있습니다.';
  end if;

  insert into public.profiles (id, nickname, affiliation, privacy_agreed_at)
  values (
    new.id,
    new.raw_user_meta_data ->> 'nickname',
    new.raw_user_meta_data ->> 'affiliation',
    now()
  );
  return new;
end;
$function$;
