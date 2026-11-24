# Bowling Strike Tournament 2026 – Registration (GitHub Pages)

Same look and rules as the laptop version. The page is hosted on GitHub Pages; the shared data lives in a free Supabase database.

## 1. Create the database (5 min, once)
1. Go to https://supabase.com, sign in, **New project** (free plan is enough). Wait until it is ready.
2. Open `supabase-setup.sql`, change `CHANGE_ME_TO_YOUR_OWN_PASSWORD` (the admin key), copy everything.
3. Supabase > **SQL Editor** > New query > paste > **Run**.
4. Supabase > **Project Settings > API** (or "API Keys"): copy the **Project URL** and the **anon / publishable key**.

## 2. Put the keys in the page
Open `index.html`, find `SUPABASE_URL` and `SUPABASE_KEY` (near the top of the script) and paste the two values. (The anon key is meant to be public; the tables are locked and only the rule-checking functions are callable.)

## 3. Publish on GitHub
1. Create a new GitHub repository (e.g. `bowling-strike`). Public is needed for free GitHub Pages.
2. Upload `index.html`, `poster.jpg`, `.nojekyll`, `README.md`, `supabase-setup.sql`.
3. Repo > **Settings > Pages** > Source: *Deploy from a branch* > Branch `main` / `(root)` > Save.
4. After ~1 minute the link is `https://<your-username>.github.io/<repo-name>/` – share this with participants.

## Notes
- Rules enforced in the database: 34 teams (Support 6, Plant 1 14, Plant 2 14), 6 members = 3 male + 3 female, one team per Badge ID, unique team name, closes 10 Dec 2026 23:59 (+08:00).
- Admin tab: enter your admin key to delete a team or **Export to Excel** (built in the browser).
- Change the deadline / admin key later: Supabase > Table Editor > `app_config`. (Also update `DEADLINE` in `index.html` for the countdown.)
- Reset test data before launch: Supabase > SQL Editor > `delete from teams;`
- Free Supabase projects pause after 7 days of no use; open the dashboard and click Restore if that happens.
- Data is also viewable/downloadable any time in Supabase > Table Editor > `teams`.
