# StageOPS V1 Starter

This is the NEW StageOPS SaaS project. It does not replace TecnoledHK.

## Quick visual test (no Supabase yet)
1. Open this folder in VS Code.
2. Run:
   npm.cmd install
   npm.cmd run dev
3. Open http://localhost:8080

Without a `.env`, StageOPS starts in DEMO mode so you can inspect the full dashboard immediately.

## Connect a NEW Supabase project
1. Create a new Supabase project named StageOPS.
2. SQL Editor -> New query.
3. Paste all of `supabase/stageops_v1.sql` and Run once.
4. Copy `.env.example` to `.env`.
5. Fill `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
6. Restart `npm.cmd run dev`.

## Build for Netlify
Run `npm.cmd run build` and upload the generated `dist` folder. `netlify.toml` already contains the SPA redirect.

## What is included
- English StageOPS UI
- New StageOPS brand/logo rendered in CSS
- Dashboard matching the approved concept
- Supabase Auth-ready login
- Multi-organization SaaS schema with RLS foundation
- Clients, branches, warehouses, products, lots, inventory, events, reservations, repairs, vehicles, flight cases and feature flags
- Navigation shells for the next implementation phase

## Important
The dashboard currently uses sample data intentionally. First we verify the project starts correctly; then the next iteration connects each module to live Supabase CRUD and adds smart lot planning, workshop prioritisation and logistics calculations.

