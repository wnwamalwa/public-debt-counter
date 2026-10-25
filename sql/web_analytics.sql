-- Readership data for the Kenya Debt Counter (from Vercel Web Analytics).
-- Run once in Supabase: Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to run again.
--
--   web_daily              one row per day: page views and readers
--   web_daily_breakdown    one row per day x dimension value
--                          (page, country, referrer, device, utm_source)
--   web_monthly, web_monthly_breakdown   the same, added up by month
--   visitor_metrics_summary_vercel   all-time and monthly totals, built from the two tables
--   visitor_metrics_summary          now reads visitor_metrics_summary_vercel; the old
--                                    session-tracker version is kept as
--                                    visitor_metrics_summary_legacy
--   storage bucket "reports"         public; the monthly PDF goes to reports/readers/

-- 1. Tables -------------------------------------------------------------------
create table if not exists public.web_daily (
  date        date primary key,
  pageviews   integer not null default 0,
  visitors    integer not null default 0,
  updated_at  timestamptz not null default now()
);

create table if not exists public.web_daily_breakdown (
  id          bigserial primary key,
  date        date not null,
  dimension   text not null check (dimension in ('page', 'country', 'referrer', 'device', 'utm_source')),
  value       text not null,
  pageviews   integer not null default 0,
  visitors    integer not null default 0,
  updated_at  timestamptz not null default now(),
  unique (date, dimension, value)
);
create index if not exists web_daily_breakdown_dim_date on public.web_daily_breakdown (dimension, date);

comment on table public.web_daily is 'Vercel Web Analytics, per UTC day. Visitors are counted once per device per day. Filled by public-debt-counter/web-analytics/collect.mjs.';
comment on table public.web_daily_breakdown is 'Vercel Web Analytics per UTC day and dimension value; top 100 values per day, the rest in "Others".';

-- The website reads with the anon key: allow reading, not writing.
alter table public.web_daily enable row level security;
alter table public.web_daily_breakdown enable row level security;
drop policy if exists "public read" on public.web_daily;
create policy "public read" on public.web_daily for select using (true);
drop policy if exists "public read" on public.web_daily_breakdown;
create policy "public read" on public.web_daily_breakdown for select using (true);

-- Monthly roll-ups for the website's /readers page (one small query each).
create or replace view public.web_monthly as
  select date_trunc('month', date)::date as month, sum(pageviews)::bigint as pageviews, sum(visitors)::bigint as visitors,
         count(*) as days
  from public.web_daily group by 1;
create or replace view public.web_monthly_breakdown as
  select date_trunc('month', date)::date as month, dimension, value,
         sum(pageviews)::bigint as pageviews, sum(visitors)::bigint as visitors
  from public.web_daily_breakdown group by 1, 2, 3;
grant select on public.web_monthly, public.web_monthly_breakdown to anon, authenticated;

-- 2. Summary view (same first seven columns as the old visitor_metrics_summary) -----
-- Old column            now means
-- total_visitors        all page views since tracking began
-- unique_visitors       all readers (sum of daily readers)
-- total_clicks, total_downloads, clicks_per_visitor, downloads_per_visitor,
-- avg_duration          not measured by Vercel Web Analytics: null
create or replace view public.visitor_metrics_summary_vercel as
with bounds as (
  select date_trunc('month', (now() at time zone 'Africa/Nairobi'))::date as this_month
),
m as (
  select date_trunc('month', date)::date as month, sum(pageviews)::bigint as pageviews, sum(visitors)::bigint as visitors
  from public.web_daily group by 1
),
last_full as (
  select m.* from m, bounds where m.month < bounds.this_month order by m.month desc limit 1
),
prev_full as (
  select m.* from m, last_full where m.month < last_full.month order by m.month desc limit 1
)
select
  (select coalesce(sum(pageviews), 0) from public.web_daily)::bigint                         as total_visitors,
  (select coalesce(sum(visitors), 0) from public.web_daily)::bigint                          as unique_visitors,
  null::bigint                                                                                as total_clicks,
  null::bigint                                                                                as total_downloads,
  null::numeric                                                                               as clicks_per_visitor,
  null::numeric                                                                               as downloads_per_visitor,
  null::numeric                                                                               as avg_duration,
  (select min(date) from public.web_daily)                                                    as first_date,
  (select max(date) from public.web_daily where pageviews > 0)                                as last_date,
  (select m.visitors from m, bounds where m.month = bounds.this_month)                        as readers_this_month,
  (select month from last_full)                                                               as last_full_month,
  (select visitors from last_full)                                                            as readers_last_full_month,
  (select pageviews from last_full)                                                           as pageviews_last_full_month,
  (select visitors from prev_full)                                                            as readers_previous_month,
  (select count(distinct value) from public.web_daily_breakdown b, last_full
     where b.dimension = 'country' and b.value not in ('(unknown)', 'Others')
       and date_trunc('month', b.date)::date = last_full.month)                               as countries_last_full_month,
  now()                                                                                       as computed_at;

grant select on public.visitor_metrics_summary_vercel to anon, authenticated;

-- 3. Point visitor_metrics_summary at the Vercel figures --------------------------
-- The old view (fed by the retired session tracker in visitor_metrics) is kept
-- as visitor_metrics_summary_legacy, so nothing is lost.
do $$
declare kind char;
begin
  select c.relkind into kind from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'visitor_metrics_summary';
  if kind is not null and not exists (
       select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = 'visitor_metrics_summary_legacy') then
    if kind in ('v', 'm') then
      execute 'alter ' || case kind when 'm' then 'materialized view' else 'view' end
           || ' public.visitor_metrics_summary rename to visitor_metrics_summary_legacy';
    else
      execute 'alter table public.visitor_metrics_summary rename to visitor_metrics_summary_legacy';
    end if;
  elsif kind is not null then
    execute 'drop view if exists public.visitor_metrics_summary';
  end if;
end $$;

create or replace view public.visitor_metrics_summary as
  select * from public.visitor_metrics_summary_vercel;
grant select on public.visitor_metrics_summary to anon, authenticated;

-- 4. Public bucket for the monthly PDF report -------------------------------------
insert into storage.buckets (id, name, public)
values ('reports', 'reports', true)
on conflict (id) do update set public = true;
