# SMART BUSINESS — Starter Prototype
Owned by ABS KANO LTD

## Included
- Responsive web-app interface
- Local demo registration/login
- Dashboard, sales, products, expenses, customers and reports
- JSON export of demo data
- Basic PWA manifest and service worker

## Important limitations
This is a front-end prototype, not a production-ready multi-user SaaS.
- Login is local demo-only and is NOT secure authentication.
- Data stays in the browser/device and does not sync across devices.
- No cloud database, payment gateway, role permissions, secure backups, or production offline sync yet.
- Do not enter real customer, financial, or confidential information.

## Next development stage
Connect Supabase (Auth + Postgres + Row Level Security), then implement tenant/business isolation, secure sessions, audit logs, subscriptions, cloud backup and tested offline sync.

## Run locally
Open `index.html` in a browser for a quick preview. For PWA/service-worker testing, serve this folder over HTTPS or localhost.

## Publish later
After backend integration and testing, deploy the app to a hosting provider and connect its own domain. Domain purchase is intentionally postponed.
