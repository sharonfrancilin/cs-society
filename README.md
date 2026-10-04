# CS Society

Report local problems, find volunteers, follow the fix.
Front end: one static page (`index.html`) hosted on **GitHub Pages**.
Backend: **Supabase** (login, database, photo storage).

---

## Part 1: Create the backend (Supabase)

1. Go to https://supabase.com and sign up (free). Click **New project**. Choose a name, a strong database password and the region closest to you. Wait for it to finish.
2. Open **SQL Editor -> New query**. Open `supabase/schema.sql` from this folder, copy everything, paste it, and click **Run**. You should see "Success".
3. Open **Project Settings -> API**. Copy:
   - **Project URL**
   - **anon public** key (NOT the service_role key)
4. Open `config.js` in this folder and paste those two values in place of the placeholders. Save.
5. In Supabase open **Authentication -> Providers -> Email**.
   - For a college demo you can turn **Confirm email** off, so people can sign in right after signing up.
   - For public use keep it on, so every account has a real email.

## Part 2: Put it on GitHub

1. Go to https://github.com and sign in. Click **New repository**. Name it, for example, `cs-society`. Keep it **Public**. Click **Create repository**.
2. Click **uploading an existing file**. Drag in **everything from this folder** (`index.html`, `config.js`, `.nojekyll`, `README.md` and the `supabase` folder). Click **Commit changes**.
3. Open **Settings -> Pages**. Under **Build and deployment** choose **Deploy from a branch**, branch **main**, folder **/ (root)**, then **Save**.
4. After a minute your site is live at `https://YOUR-USERNAME.github.io/cs-society/`.

## Part 3: Tell Supabase about your site address

In Supabase open **Authentication -> URL Configuration**.
- **Site URL**: your GitHub Pages address from Part 2.
- **Redirect URLs**: add the same address.

This makes the confirmation and password-reset emails open your site.

## Part 4: Test it

1. Open your site and create an account.
2. Sign out and sign in again. Your name and location should still be there.
3. In Supabase open **Table Editor -> profiles**. Your account should be listed.

## What works now

- Real sign-up, sign-in, sign-out, password reset.
- Profile name, roles, location and notification choices saved to your account.

## What comes next

1. Reports saved to the shared database, so everyone sees the same ones.
2. Claiming, updates and resolving through the database, plus live notifications.
3. Photos uploaded to Supabase Storage.
4. Moderation and an admin screen.

The database for all of these is already created by `schema.sql`.

## Safety notes

- `config.js` may be public. It holds only the public anon key. The security rules in `schema.sql` protect the data.
- Never put the `service_role` key anywhere in this repository.
