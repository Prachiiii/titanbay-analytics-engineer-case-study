# Titanbay IS Team Support Analytics: Data Model

## Business Problem

The Investor Services (IS) team currently handles support tickets reactively with no structured view of investor behaviour or team workload. The Head of IS asked two questions:

1. **Which investors raise the most tickets, and what patterns exist in that behaviour?**
2. **When is our team likely to be under more pressure than usual, so we can resource in advance?**

This model addresses both by linking Freshdesk support tickets to the platform's investor, entity, partner, and fund close data.

---

## What an Analyst Can Now Do

**Before this model:** raw Freshdesk exports and platform tables sit in separate systems with no reliable join key between them.

**After this model:**

The Head of IS asked two specific questions. These can now be answered directly:

| Question | Model to use |
|---|---|
| Which investors raise the most tickets? | `mart_investor_support_summary` ORDER BY total_tickets DESC |
| What patterns exist in their behaviour? | `mart_investor_support_summary` — priority breakdown, resolution times, recency |
| When will the team be under more pressure than usual? | `mart_ticket_volume_vs_closes` months where ticket volume is above average or a close is scheduled |

The data also makes the following questions answerable, which were not explicitly asked but are natural follow-ons the IS team may find useful:

| Question | Model to use |
|---|---|
| What topics are investors struggling with? | `mart_ticket_tags_exploded` GROUP BY tag |
| How has topic volume changed month by month? | `mart_ticket_tags_exploded` GROUP BY month, tag |
| Does KYC status correlate with ticket volume? | `mart_investor_support_summary` GROUP BY kyc_status |
| Do RM-managed investors raise fewer tickets? | `mart_investor_support_summary` GROUP BY is_rm_managed |
| Which partner's close schedule carries the most capital? | `mart_ticket_volume_vs_closes` ORDER BY total_aum_closing_gbp DESC |
| Do cancellations drive ticket spikes? | `mart_ticket_volume_vs_closes` compare cancelled_closes vs total_tickets |

---

## Solution

This is a plain SQL solution. Run `run_all.sql` top-to-bottom to build the full model in one go.

A full schema reference including an ER diagram and explanation of how all six source tables relate to each other is in `schema.md`.

### Structure

The SQL is organised in three logical layers inside `run_all.sql`:

```
Layer 1: Staging
  stg_freshdesk_tickets
  stg_platform_investors
  stg_platform_entities
  stg_platform_relationship_managers
  stg_platform_partners
  stg_platform_fund_closes

Layer 2: Intermediate
  int_partner_label_normalised
  int_ticket_requester_resolved

Layer 3: Marts (analyst-facing output)
  mart_investor_support_summary
  mart_ticket_volume_vs_closes
  mart_ticket_tags_exploded
```

### Layer 1: Staging
One step per source table. Cleans and standardises only; no joins, no business logic, no filtering. All rows from the source are passed through so nothing is silently lost before downstream models see it.

| Table | What it does |
|---|---|
| `stg_freshdesk_tickets` | Lowercases 34 mixed-case requester emails (without this, those 34 tickets silently fail to match investors or RMs downstream). Lowercases `partner_label` for consistent LIKE matching later. Adds `requester_name_norm` for name-based matching. |
| `stg_platform_investors` | Adds `full_name_norm` (lowercased) for name-based matching fallback. `relationship_manager_id` is ~41% null by design, these are self-managed investors with no RM. |
| `stg_platform_entities` | Trim applied wherever relevant |
| `stg_platform_relationship_managers` | Lowercases emails |
| `stg_platform_partners` | Trim applied wherever relevant |
| `stg_platform_fund_closes` | Trim applied wherever relevant |

### Layer 2: Intermediate
Business logic only. Not intended to be queried directly by analysts.

| Table | What it does |
|---|---|
| `int_partner_label_normalised` | Maps 30+ spelling variants of partner names in `partner_label` to canonical names and partner_ids using LIKE pattern matching. Used as a fallback only, email matching is always preferred. |
| `int_ticket_requester_resolved` | Core model. Classifies all 2,000 tickets by who raised them and resolves each to the appropriate platform entity. See Entity Resolution section below. |

### Layer 3: Marts
Analyst-facing output. These are the tables to query.

| Table | Grain | Answers |
|---|---|---|
| `mart_investor_support_summary` | One row per investor | Who raises the most tickets? Ticket counts, priorities, resolution times. Join to `mart_ticket_tags_exploded` for topic breakdown. |
| `mart_ticket_volume_vs_closes` | One row per month × partner | When will the IS team be under pressure? |
| `mart_ticket_tags_exploded` | One row per ticket per tag | What topics drive ticket volume, and how does that change over time? |

---

## Key Decisions

### Entity Resolution

Freshdesk and the platform share no common identifier. The only link between a ticket and a platform user is an email address. Five distinct requester populations exist in the ticket data:

| Type | Tickets | How identified | Resolved to |
|---|---|---|---|
| `investor` | 1,060 | Email exactly matches `platform_investors.email` | investor_id, entity_id, partner_id |
| `rm` | 760 | Email exactly matches `platform_relationship_managers.email` | rm_id, partner_id only |
| `internal_staff` | 100 | @titanbay.com / @titanbay.co.uk domain, name does not match email | Nothing reliable, see below |
| `personal_email_investor_match` | 80 | No email match, but name matches an investor | investor_id if name is unique |
| `unresolved` | 0 | - | All 2,000 tickets classified |

**Why RM tickets are not resolved to individual investors:**
Each RM manages a median of 18 investors (max 35). Without knowing which specific investor the ticket is about, joining to all of the RM's investors would multiply rows and inflate every count. RM tickets are attributed to partner level only.

**Why internal staff tickets are not name-matched:**
The name on these tickets is the investor's name typed by the IS agent, so in theory name matching could work. In practice it doesn't: name matching was attempted and produced only 2 matches out of 100 tickets (2% hit rate). The primary reason is that IS agents record names with honorifics (Mr, Mrs, Dr), 30 of 100 tickets have a title prefix, but the platform stores investor names without titles. "Mr Terry Collins" never matches "Terry Collins". Given the near-zero match rate, name matching is not applied for this population.

**Why personal email tickets can be name-matched but internal staff cannot:**
For personal email tickets, the person typing the ticket is the investor themselves, they are writing their own name. For internal staff tickets, a third party (the IS agent) is writing the investor's name, introducing inconsistencies like honorifics and different formatting.

### Cancelled Fund Closes

Cancelled closes are retained in the model rather than filtered out. A cancellation may itself drive ticket volume; investors may contact the IS team confused about why a close was cancelled and what happens to their commitment. Filtering them would hide a potentially significant source of workload. A `cancelled_closes` column is exposed in `mart_ticket_volume_vs_closes` so analysts can investigate this relationship themselves.

### Grain Management

`mart_investor_support_summary` is one row per investor, including investors with zero tickets. Zero values filled with COALESCE so nulls never appear in the output.

`mart_ticket_volume_vs_closes` is one row per month × partner. There is no direct link from fund closes to investors; the path is `closes.partner_id → entities.partner_id → investors.entity_id`, which fans out at every step. Aggregating at partner level avoids row multiplication entirely.

`mart_ticket_tags_exploded` is one row per ticket per tag. A ticket with 3 tags produces 3 rows; this is intentional and correct for this grain.

---

## Assumptions

1. **Internal staff tickets** (@titanbay.com / @titanbay.co.uk) are IS team members raising tickets on behalf of investors, not investors themselves. Evidence: name and email consistently do not match (e.g. email `jordan.thomas@titanbay.com`, name `Shaun Webb`).

2. **Personal email matches**: when a requester name uniquely matches one investor's full name, we assume it is the same person using a personal email address not registered on the platform. Not applied when the name matches multiple investors (6 duplicate names exist in the platform).

3. **Static snapshot**: this dataset was provided as a fixed snapshot for assessment purposes. 15 closes have `close_status = 'upcoming'` but dates that appear to be in the past. These are not reclassified, comparing against `current_date` on a static dataset produces false positives. In a live pipeline this would be a valid data quality check.

4. **Tags are reliable**: comma-separated tags applied by the IS team appear consistently across 10 categories. No cleaning was required.

5. **resolved_at nulls are expected**: `resolved_at` is null for ~42% of tickets (open/pending). Resolution time metrics are computed only over resolved tickets using `FILTER (WHERE is_resolved)`.

---

## Data Quality Issues Found

| Issue | Severity | Handling |
|---|---|---|
| `partner_label` 44% null, 30+ spelling variants | High | Normalised via LIKE matching in `int_partner_label_normalised`. Email-derived partner_id always preferred over label-derived. |
| 34 mixed-case requester emails | High | Lowercased in `stg_freshdesk_tickets`. Without this fix, 34 tickets silently fail to match any investor or RM. |
| 100 tickets from @titanbay domains — IS team acting on behalf of investors | Medium | Classified as `internal_staff`. Name matching attempted but produced 2% hit rate due to honorific mismatch. Excluded from investor-level metrics. |
| 80 tickets from personal emails not on the platform | Medium | Name-based match applied where name is unique. 6 duplicate investor names flagged as ambiguous. |
| `resolved_at` 42% null | Expected | Handled with `FILTER (WHERE is_resolved)` in aggregations. Verified consistent with status field. |
| RM tickets cannot be attributed to a single investor | Structural | Resolved to partner level only. Fanning out to all RM investors would inflate counts. |
| 6 duplicate investor full names | Low | Ambiguous personal-email name matches not forced to an investor_id. |

---

## How I Used AI Tools

- After conducting initial analysis of table structure and raw data, checked with AI on additional data quality checks to look out for.
- Verified joining criteria and co-validated thinking around how to join vs drop certain records.
- AI drafted SQL based on agreed decisions, which were later reviewed and updated wherever necessary.
- Based on the discussions and decisions made, used AI to draft the README and reviewed it iteratively.

---

## Reflection: Long-Term Fix for the Linkage Problem

Three distinct linkage problems exist in the current data, each requiring a different upstream fix.

**1. No shared identifier between Freshdesk and the platform**
The fundamental problem is that Freshdesk and the platform share no common identifier. The ideal fix is to add a `platform_investor_id` and/or `platform_rm_id` field to every Freshdesk ticket at creation time, either by having the platform pass these fields to Freshdesk via API when a ticket is raised, or by requiring the person submitting the ticket to select the investor from a structured lookup. This would make the current email and name matching logic unnecessary entirely.

**2. Internal staff tickets are completely unattributable**
100 tickets per dataset are raised by IS agents on behalf of investors with no record of which investor the ticket concerns. This is not just a data quality issue, it is a workflow gap. When an IS agent logs a ticket on behalf of an investor, there is currently no step in the process that requires them to record which investor they are acting for. The fix is a mandatory investor selection field in the Freshdesk ticket form for internal staff enforced at submission, not optional. Until this exists, these tickets remain a permanent blind spot in any investor-level analysis.

**3. `partner_label` is a free-text field**
`partner_label` is manually entered by the IS team and has produced 30+ spelling variants for 15 partners. It should be replaced by a structured `partner_id` dropdown sourced directly from the platform, removing the possibility of inconsistent entry. This fix is lower priority than the above two since partner_label is only used as a fallback, but it would eliminate the need for the normalisation logic in `int_partner_label_normalised` entirely.

All three fixes require changes at the source (the Freshdesk ticket creation workflow), not in the data model.

---

## What I Would Build Next

1. **`mart_partner_support_summary`** the current model excludes 860 tickets (43% of the total) from investor-level analysis because they cannot be attributed to a specific investor, 760 RM tickets and 100 internal staff tickets. These are counted in the total workload figures in mart_ticket_volume_vs_closes but there is no dedicated model for analysing them at partner level. A mart_partner_support_summary with one row per partner would close this gap, giving the IS team a complete picture of workload by partner organisation rather than just the subset attributable to individual investors.

**A more sophisticated pressure signal** the current `is_pressure_month` flag in `mart_ticket_volume_vs_closes` looks at the problem from one angle: months where ticket volume is above average or a close is scheduled. This is a reasonable starting point but misses two things. First, not all closes are equal; a £500M close affects far more investors than a £10M one, and the current flag treats them identically. Second, months with very high ticket volume but no close scheduled are not flagged at all, even if the IS team is clearly under strain.
 
A better approach would be a weighted `pressure_score` combining three signals, each normalised to a 0–1 scale so they can be compared fairly:
 
| Signal | Suggested weight | Why |
|---|---|---|
| Ticket volume relative to monthly average | 0.4 | Directly measures IS team workload |
| Upcoming closes scheduled | 0.3 | Forward-looking, close activity drives investor queries |
| Total AUM closing that month | 0.3 | Larger closes affect more investors and carry more risk |
 
Normalisation is essential before combining, without it, raw AUM values in the hundreds of millions completely overwhelm ticket counts regardless of the weights. The IS team can calibrate the weights based on their experience of what actually drives pressure.
