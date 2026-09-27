# Aether — self-hosted cold email (Quickly)

A lightweight, self-hosted cold-email setup built on [Quickly](https://github.com/AbdelftahZowail/Quickly)
(MIT-licensed, v2.4.0) — the simplest open-source tool that covers everything
you asked for and nothing you didn't: multi-inbox rotation, sequences,
CSV import, sending limits, and automatic stop-on-reply/bounce/unsubscribe,
with no AI reply generation, no CRM, no lead sourcing.

## Why Quickly, and one thing to know before you connect real inboxes

Quickly is a small, actively maintained project (43 stars, MIT license,
regular releases — currently v2.4.0). It's real and it fits every
requirement cleanly, but it is not a large, heavily-audited project like
Postfix or Nginx. Since you'll be handing it OAuth access to real mailboxes,
treat step 10 (test with addresses you control) as mandatory, not optional
— run a full campaign end-to-end against your own inboxes before touching a
single real lead. The install below also runs it in an isolated Docker
volume/network so it cannot see or touch anything else on your VPS.

## What this repo contains

```
deploy/
  install.sh                     one-shot installer for the VPS
  docker-compose.no-caddy.yml    default: runs behind your EXISTING reverse proxy
  docker-compose.caddy.yml       alternative: for a bare VPS with nothing on 80/443
  Caddyfile                      only used by the caddy variant
  .env.example                   config template
  nginx-quickly.conf.example     sample vhost if you use nginx
  samples/leads.csv              example CSV in the required format
```

The installer never touches Docker containers, volumes, or apt sources
belonging to anything else already running on your VPS. It creates its own
`quickly` Docker project and `quickly_pgdata` volume, and by default binds
the app to `127.0.0.1:8000` only — it does not take over ports 80/443 unless
you explicitly tell it to (and it detects if something's already listening
there first).

## Installation (run on your Ubuntu VPS, not here)

1. Copy this repo's `deploy/` folder to your VPS, e.g.:
   ```
   scp -r deploy your-vps:/tmp/quickly-deploy
   ssh your-vps
   ```
2. Before running anything, confirm what's already using ports 80/443 if
   you're not sure:
   ```
   sudo ss -ltnp | grep -E ':80|:443'
   ```
3. Run the installer:
   ```
   cd /tmp/quickly-deploy
   sudo bash install.sh
   ```
   - If something is already on 80/443 (your existing site/app), it
     auto-selects the **no-caddy** variant — Quickly only binds to
     `127.0.0.1:8000`, and you point your existing reverse proxy at it
     (sample config: `nginx-quickly.conf.example`).
   - If nothing is on 80/443, it asks whether you want Quickly's bundled
     Caddy to handle HTTPS automatically for a domain you give it.
4. Once it's reachable at `https://your-domain`, open it in a browser.
   **The first account you create becomes the admin, and registration
   closes after that** — so do this yourself first, immediately.

If you ever need to add Gmail or Microsoft OAuth, edit
`/opt/quickly/.env` on the VPS, then re-run:
```
docker compose -p quickly -f docker-compose.no-caddy.yml up -d
```
(swap the filename if you used the caddy variant).

---

## Exactly how to use it

### 1. Connect an inbox

- **Gmail**: In Google Cloud Console, enable the Gmail API, configure the
  OAuth consent screen, and create an OAuth Web Application client with
  redirect URIs `https://YOUR_DOMAIN/oauth/app/google/callback` and
  `https://YOUR_DOMAIN/oauth/google/callback`. Put the client ID/secret in
  `/opt/quickly/.env` as `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`,
  restart the stack, then in Quickly go to **Inboxes → Connect → Google**
  and sign in.
- **Outlook / Microsoft 365**: In Azure Portal, register an app with
  redirect URIs `https://YOUR_DOMAIN/oauth/office365/callback` and
  `https://YOUR_DOMAIN/oauth/app/office365/callback`, and delegated
  permissions `Mail.ReadWrite`, `Mail.Send`, `User.Read`, `offline_access`.
  Put the client ID/secret/tenant in `.env` as `OFFICE365_CLIENT_ID` /
  `OFFICE365_CLIENT_SECRET` / `OFFICE365_TENANT_ID`, restart, then
  **Inboxes → Connect → Microsoft 365**.
- **Generic SMTP**: No `.env` changes needed. **Inboxes → Connect → SMTP**,
  enter host/port/username/password and (optionally) IMAP details so
  replies can be detected. Quickly tests the connection immediately and
  flags it if login fails.

You can mix all three types in the same campaign.

### 2. Upload a CSV of leads

Go to a campaign → **Leads → Import CSV**. Use these column headers exactly
(see `deploy/samples/leads.csv` for a working example):

```
first_name,business_name,email,personalised_line
```

`personalised_line` is optional — leave it blank for rows that don't have
one.

### 3. Write Email 1 + follow-ups

In the campaign's **Sequence** tab, add steps:

- **Step 1**: your opening email.
- Set **wait N days**, add **Step 2** (follow-up 1).
- Set **wait N days** again, add **Step 3** (follow-up 2).

In any step's subject/body, use:

```
{{first_name}}   {{business_name}}   {{personalised_line}}
```

Quickly fills these in per lead at send time.

### 4. Set daily limits, sending hours, and delays

- **Per-inbox daily limit**: Inboxes → click an inbox → set its daily send
  cap. Rotation automatically respects each inbox's own limit.
- **Sending hours / days**: Campaign → **Schedule** — set the sending
  window and which days it's active (recipient-timezone aware).
- **Delay between emails**: Campaign → **Schedule** — set the jitter/delay
  between individual sends so they don't all fire at once.

### 5. Launch / pause / stop a campaign

Campaign page has **Start**, **Pause**, and **Stop** controls at the top.
Pause halts sending but keeps all progress (each lead's current sequence
step); Stop ends it. Starting is only enabled once you have at least one
connected inbox and one sequence step.

### 6. How automatic reply-stopping works

Every campaign has **"Stop sending to a lead after they reply"** — on by
default, and it's a plain toggle, not AI: as soon as a reply is detected on
the thread (via the inbox's Gmail/Graph API or IMAP sync), that lead's
remaining follow-ups are cancelled immediately. The same happens
automatically when a lead's status becomes **bounced** or **unsubscribed**
— all pending sends for that lead are cleared. None of this requires any AI
provider configured; leave the AI/Settings section alone entirely — it's
optional and unrelated to reply-stopping.

### Dashboard

The main dashboard shows connected inboxes (with health/status), campaigns,
lead counts, sent/replied/bounced totals, and each lead's current sequence
step — exactly what you asked for, nothing more.

### 10. Test before real outreach (do this first)

1. Connect one or two inboxes you own.
2. Build a CSV with only your own email addresses (use `deploy/samples/leads.csv`
   as a template).
3. Create a short sequence with short wait times (e.g. 2 minutes instead of
   days — Quickly's wait field accepts small values for testing).
4. Launch the campaign and confirm: emails arrive, variables render
   correctly, replying to Email 1 stops Email 2/3 for that lead, and the
   dashboard counts update.
5. Only after that, switch wait times back to real days and import real leads.

## Maintenance

- Logs: `docker compose -p quickly -f <compose-file> logs -f`
- Stop: `docker compose -p quickly -f <compose-file> down` (data persists in
  the `quickly_pgdata` volume)
- Upgrade: bump the image tag in the compose file (check
  [Quickly's releases](https://github.com/AbdelftahZowail/Quickly/releases))
  and re-run `docker compose -p quickly -f <compose-file> up -d`
- Backups: Postgres data lives in the `quickly_pgdata` Docker volume;
  the app also writes local backups to `/opt/quickly/backups`.
