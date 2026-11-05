# X posts from the IEA Kenya account

`.github/workflows/x-posts.yml` runs every hour (at :07 Nairobi time). It posts
the rows of the **`x_posts`** tab in the IEA Google Sheet whose status is
`ready` and whose time has come, from the **IEA Kenya** X account. The tab is
created with its headers on the first run.

Nothing goes out unless someone sets a row to `ready`, so whoever edits the
tab (e.g. Communications) approves every post.

## Writing a post (one row each)

| Column | What to put |
|---|---|
| `post_at` | When to post, Nairobi time: `2026-11-10 09:00` (it goes out within the hour) |
| `text` | The post, with `{placeholders}` for live figures (below). Max 280 characters once filled in. |
| `visual` | `counter` (video of the ticking total), `per_person`, `chart` (the animated debt-trend chart as the post's video), `terms` / `terms_real` (debt by president, plain or adjusted with the GDP deflator), `service` (debt service in the latest fiscal year), `maturity` (when the debt falls due, end June), `lenders` (who Kenya owes: debt by lender at home and abroad, from the Annual Public Debt Report; update the figures in `render_fri.py` each year), `counter+chart` (adds a reply with the animated debt-trend chart), `per_person+chart`, or `none` |
| `status` | `draft` while writing; **`ready`** to post. The job then sets `posting`, `posted`, `failed` or `missed`. |
| `posted_at`, `post_url`, `note` | Filled in by the job. |
| `repeat` | Optional. `weekly` or `fortnightly`: after the row goes out, the job adds the same post 7 (or 14) days later as a new `ready` row, so it repeats every week. To stop, set the next row's status to `stop`. |

Wednesdays alternate between the debt service and maturity pictures: two rows a week apart, each `fortnightly`. Other weekly posts: Monday 09:00, the counter video
(`visual` `counter`); Tuesday 09:00, the debt-trend chart (`visual` `chart`,
text about the rise since August 2022). Both have `repeat` `weekly`.

A row more than 6 hours late is marked `missed` rather than posted (set a new
time and `ready` again to post it).

Placeholders: `{debt_total}` (KSh 13.71 trillion), `{debt_total_full}`,
`{debt_per_person}`, `{growth_per_second}`, `{growth_per_day}`, `{domestic}`,
`{external}`, `{domestic_share}`, `{external_share}`, `{population}`,
`{debt_to_gdp}`, `{date}`, `{time}`, `{since_increase}`, `{since_from}`,
`{since_to}`, `{since_per_year}` (change since August 2022), and `{link}`
(the dashboard, tagged so visits from X can be counted).

Example:

```
At {time} today, Kenya's public debt stood at {debt_total} ({debt_to_gdp} of GDP), rising by about {growth_per_second} every second.

👉 See the live figure, ticking right now: {link}
```

## Cost

Paid from the prepaid credit on IEA Kenya's X developer account (console.x.com
→ Credits). Roughly US$0.015 for a text post, more with a link or a video;
check Usage there. When the credit runs out, posts fail with a note and
nothing else is affected.

## Trying it

Actions → "X posts (IEA Kenya account)" → Run workflow, with **dry run** ticked:
it renders the due rows and shows them in the run summary without posting.
`only_row` posts one row now, whatever its time.

## Keys

Repository secrets `X_API_KEY`, `X_API_SECRET`, `X_ACCESS_TOKEN`,
`X_ACCESS_TOKEN_SECRET`, from the "Kenya Debt Counter" app on IEA Kenya's X
developer account (permissions: Read and write). If a key leaks, regenerate it
there and update the secret. `x-posts-test/` on the Mac is the old test copy
for a personal account.
