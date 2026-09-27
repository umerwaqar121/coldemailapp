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

The installer is **non-interactive** and never touches Docker/containerd
themselves, nginx's main config, or anything belonging to other services
already on the box. It only ever: creates `/opt/quickly`, an isolated
`quickly` Docker Compose project, a `quickly_pgdata` volume, and — only if
you pass a domain — one new file at `/etc/nginx/sites-available/quickly.conf`
(validated with `nginx -t` and rolled back automatically if that fails, then
reloaded, never restarted). It auto-picks a free loopback port in 8000–8010
instead of assuming 8000 is free. `docker-compose.caddy.yml` is included only
for a bare VPS with no existing web server — the installer never chooses it
on its own.

## Installation (run on your Ubuntu VPS, not here)

1. Copy this repo's `deploy/` folder to your VPS, e.g.:
   ```
   scp -r deploy your-vps:/tmp/quickly-deploy
   ssh your-vps
   ```
2. Run the installer. If you already have a domain/subdomain pointed at
   this VPS for Quickly, pass it so the script also wires up nginx:
   ```
   cd /tmp/quickly-deploy
   sudo QUICKLY_DOMAIN=mail.yourdomain.com bash install.sh
   ```
   Or, to just bring the containers up and wire the reverse proxy yourself
   later:
   ```
   sudo bash install.sh
   ```
   Read the top of `install.sh` first — it documents exactly what it will
   and won't touch, including the three existing `aether-*`/`voice-agent`
   services and nginx.
3. If you passed `QUICKLY_DOMAIN`, get a certificate the same way you do
   for your other sites, e.g. `sudo certbot --nginx -d mail.yourdomain.com`.
4. Open the site in a browser. **The first account you create becomes the
   admin, and registration closes after that** — so do this yourself
   first, immediately.

If you ever need to add Gmail or Microsoft OAuth, edit `/opt/quickly/.env`
on the VPS, then re-run:
```
docker compose -p quickly -f docker-compose.no-caddy.yml up -d
```

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
