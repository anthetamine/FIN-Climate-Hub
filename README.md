# FIN Sustainability Reporting Portal

This is the cloud-backed version of the FIN Agency SME Reporting Portal.

**Architecture**

- **GitHub** — source code and version control
- **Vercel** — hosts the website
- **Supabase** — email sign-in, shared database, private evidence-file storage and audit history

The original browser-only portal used `localStorage` / IndexedDB. This version treats Supabase as the source of truth, so reopening the site or using another computer does not lose the shared register.

## One-time setup

### 1. Create the Supabase project

1. In Supabase, create a new project (for example `fin-sustainability-reporting`).
2. Open **SQL Editor**.
3. Paste the entire contents of `supabase-schema.sql` and run it once.
4. In **Project Settings → API**, copy:
   - the **Project URL**;
   - the **anon / publishable key**.

Do **not** use or expose the Supabase service-role key. This app does not need it.

### 2. Put this folder in GitHub

Create a new GitHub repository and upload/commit all files in this folder. A private repository is appropriate for this project.

### 3. Deploy the GitHub repository in Vercel

1. In Vercel, choose **Add New → Project** and import the GitHub repository.
2. No framework preset or build command is required; it is a static HTML site plus one Vercel API function.
3. Add these Vercel project **Environment Variables**:
   - `SUPABASE_URL` = your Supabase Project URL
   - `SUPABASE_ANON_KEY` = your Supabase anon/publishable key
4. Deploy.

### 4. Configure Supabase authentication URLs

Once Vercel gives you the production URL, open Supabase **Authentication → URL Configuration** and set:

- **Site URL**: your Vercel production URL, e.g. `https://fin-reporting.vercel.app`
- Add the same production URL to **Redirect URLs**.

The portal uses Supabase's email magic-link / OTP login. Make sure email authentication is enabled in Supabase Authentication providers.

### 5. First login

1. Open the Vercel URL.
2. Enter your email and click **Send sign-in link**.
3. Open the link in the email.
4. On first login, click **Create FIN workspace**.
5. The SME Climate Hub checklist seed will be loaded into the shared database automatically.

## Sharing it with FIN or collaborators

Sign in as the workspace owner and click **Share** in the top-right corner.

1. Enter the person's exact email address.
2. Choose **Editor** or **Viewer**.
3. Add the invitation.
4. Send them the Vercel URL.
5. They sign in with the same email address. The invitation is claimed automatically and the shared FIN register appears.

**Editor** can update the register and evidence. **Viewer** can read/download but not edit. Only the **Owner** can create/revoke invitations.

## Data persistence and audit trail

- Reporting items are stored in Supabase `register_items`.
- Every insert/update/delete is copied to `item_history` by a database trigger.
- Evidence uploads are stored in the private Supabase Storage bucket `evidence`.
- Database Row Level Security prevents users outside the workspace from reading FIN data.
- The portal still includes **Export JSON** for an independent backup.

## Migrating an export from the old portal

If you previously used **Export JSON** in the browser-only version:

1. Sign in to the new hosted portal.
2. Click **Import JSON**.
3. Select the old `SME-reporting-register.json` file.
4. Confirm replacement of the shared register.

The old JSON export did not include attachment binary files stored in IndexedDB. Those files must be uploaded again if needed.

## Important limitation for unrecovered old browser data

If data existed only in a previous temporary ChatGPT `file://` preview and was never exported, this deployment cannot automatically recover that old browser-local storage. If the original preview is still accessible in browser history, export from that old page before closing it; otherwise the entries may need to be re-entered.

## Files

- `index.html` — portal UI and client logic
- `api/config.js` — supplies the public Supabase URL/key from Vercel environment variables
- `supabase-schema.sql` — database, security, sharing, audit and storage setup
- `package.json` — marks Vercel API code as ES module

## Security notes

The Supabase anon/publishable key is designed for browser clients and is not a secret. Access control is enforced by Supabase Row Level Security policies. Never put the Supabase **service-role** key in this repository or browser code.
