# Wix Adapter Expansion — Add All Available APIs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 15+ new Wix API resources to the adapter template, covering stores, events, bookings, groups, inbox, restaurants, forms, and more.

**Architecture:** All changes are JSON config in `wix.adapter.json` (template) and the instantiated `.api2file/adapter.json`. No Swift code changes needed — the adapter engine already handles all resource types via config.

**Tech Stack:** JSON adapter config, Wix REST APIs

---

## File Structure

- **Modify:** `Sources/API2FileCore/Resources/Adapters/wix.adapter.json` — add new resource blocks to the `resources` array
- **Modify:** `/Users/shayco/API2File-Data/wix/.api2file/adapter.json` — add same resources with actual site ID

## Resources to Add

### Task 1: Upgrade Existing Read-Only Resources

**Files:**
- Modify: `Sources/API2FileCore/Resources/Adapters/wix.adapter.json`

Upgrade these existing resources from read-only to writable:

- [ ] **Step 1: Members** — add `push.update` (PATCH /members/v1/members/{id}) and `push.delete` (DELETE /members/v1/members/{id}), remove `readOnly`
- [ ] **Step 2: Site Properties** — add `push.update` (PATCH /site-properties/v4/properties), keep as single-object collection
- [ ] **Step 3: Form Submissions** — add full CRUD push (POST/PUT/DELETE /forms/v4/submissions), remove `readOnly`
- [ ] **Step 4: Blog Tags** — switch from CMS pull to Blog API (POST /blog/v3/tags/query), add CRUD push
- [ ] **Step 5: Bookings Appointments** — add `push.create` (POST /bookings/v2/bookings), remove `readOnly`
- [ ] **Step 6: eCommerce Orders** — add `push.update` (PATCH /ecom/v1/orders/{id}), keep `readOnly` false but no create

### Task 2: Store/eCommerce Expansion

- [ ] **Step 1: Store Categories** — `POST /stores/v3/categories/query`, full CRUD
- [ ] **Step 2: Store Collections** — `GET /stores/v1/collections`, full CRUD
- [ ] **Step 3: Abandoned Carts** — `POST /ecom/v1/abandoned-checkouts/query`, read + delete
- [ ] **Step 4: Order Fulfillments** — as child of orders or standalone CSV

### Task 3: Events Full CRUD

- [ ] **Step 1: Upgrade events to V3** — `POST /events/v3/events/query`, add create/update/delete
- [ ] **Step 2: RSVP** — `POST /events/v2/rsvps/query`, full CRUD
- [ ] **Step 3: Ticket Definitions** — `POST /v1/events/ticket-definitions/query`, full CRUD
- [ ] **Step 4: Event Guests** — `POST /events/v1/guests/query`, read + check-in

### Task 4: Bookings Expansion

- [ ] **Step 1: Upgrade services to full CRUD** — add create/delete to bookings-services
- [ ] **Step 2: Staff Members** — `GET /bookings/v2/staff-members`, full CRUD
- [ ] **Step 3: Bookings Resources** — `GET /bookings/v1/resources`, full CRUD

### Task 5: Social & Communication

- [ ] **Step 1: Groups** — `POST /social-groups/v2/groups/query`, full CRUD
- [ ] **Step 2: Inbox Messages** — `GET /inbox/v2/messages`, send + read
- [ ] **Step 3: Comments** — `POST /comments/v1/comments/query`, full CRUD

### Task 6: Restaurants

- [ ] **Step 1: Restaurant Menus** — `POST /v1/menus/query`, full CRUD
- [ ] **Step 2: Restaurant Reservations** — `POST /v1/restaurants/reservations/query`, full CRUD
- [ ] **Step 3: Restaurant Orders** — read + status updates (accept/fulfill/cancel)

### Task 7: Additional Resources

- [ ] **Step 1: Email Marketing Campaigns** — `GET /v1/marketing/emails/campaigns`, read + publish
- [ ] **Step 2: Loyalty Accounts** — add `push.create` and adjust-points action
- [ ] **Step 3: Analytics** — `GET /analytics/v2/site-analytics/data`, read-only summary

### Task 8: Deploy and Test

- [ ] **Step 1: Copy template resources to instantiated adapter** (with actual site ID)
- [ ] **Step 2: Build and deploy**
- [ ] **Step 3: Force sync and verify all new resources appear**
- [ ] **Step 4: Test CRUD on 2-3 new resources**
