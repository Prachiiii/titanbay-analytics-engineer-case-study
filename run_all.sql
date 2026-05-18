-- Run this script top-to-bottom to build the full data model.
-- Each step creates a table that the next step depends on.
-- Order matters — do not rearrange.
--
-- PREREQUISITES:
--   The following raw tables must already exist (loaded from CSV):
--     - freshdesk_tickets
--     - platform_investors
--     - platform_entities
--     - platform_relationship_managers
--     - platform_partners
--     - platform_fund_closes
--
-- OUTPUT TABLES (what an analyst should query):
--   - mart_investor_support_summary   (one row per investor)
--   - mart_ticket_volume_vs_closes    (one row per month × partner)
--   - mart_ticket_tags_exploded       (one row per ticket per tag)
-- ============================================================


-- ============================================================
-- LAYER 1: STAGING
-- Clean and standardise each raw table
-- ============================================================

-- stg_freshdesk_tickets
-- Key fix: lowercases 34 mixed-case emails so they match investor/RM records downstream
CREATE OR REPLACE TABLE stg_freshdesk_tickets AS
SELECT
    ticket_id,
    lower(trim(requester_email))    AS requester_email,
    trim(requester_name)            AS requester_name,
    lower(trim(requester_name))     AS requester_name_norm,
    subject,
    status,
    priority,
    CAST(created_at AS TIMESTAMP)   AS created_at,
    CAST(resolved_at AS TIMESTAMP)  AS resolved_at,
    tags,
    lower(trim(partner_label))      AS partner_label
FROM freshdesk_tickets;


-- stg_platform_investors
-- Adds full_name_norm for name-based matching fallback
CREATE OR REPLACE TABLE stg_platform_investors AS
SELECT
    investor_id,
    user_id,
    lower(trim(email))              AS email,
    trim(full_name)                 AS full_name,
    lower(trim(full_name))          AS full_name_norm,
    entity_id,
    country,
    CAST(created_at AS TIMESTAMP)   AS created_at,
    relationship_manager_id
FROM platform_investors;


-- stg_platform_entities
-- trim applied wherever applicable
CREATE OR REPLACE TABLE stg_platform_entities AS
SELECT
    entity_id,
    trim(entity_name)   AS entity_name,
    partner_id,
    entity_type,
    kyc_status
FROM platform_entities;


-- stg_platform_relationship_managers
-- Lowercases emails
-- trim applied wherever applicable
CREATE OR REPLACE TABLE stg_platform_relationship_managers AS
SELECT
    rm_id,
    partner_id,
    trim(name)          AS rm_name,
    lower(trim(email))  AS email
FROM platform_relationship_managers;


-- stg_platform_partners
-- trim applied wherever applicable
CREATE OR REPLACE TABLE stg_platform_partners AS
SELECT
    partner_id,
    trim(partner_name)  AS partner_name,
    partner_type
FROM platform_partners;


-- stg_platform_fund_closes
-- trim applied wherever applicable
CREATE OR REPLACE TABLE stg_platform_fund_closes AS
SELECT
    close_id,
    fund_id,
    trim(fund_name)                     AS fund_name,
    partner_id,
    close_number,
    CAST(scheduled_close_date AS DATE)  AS scheduled_close_date,
    close_status,
    total_committed_aum
FROM platform_fund_closes;


-- ============================================================
-- LAYER 2: INTERMEDIATE
-- Business logic- resolve who raised each ticket
-- ============================================================

-- int_partner_label_normalised
-- Maps messy free-text partner labels to canonical partner names
CREATE OR REPLACE TABLE int_partner_label_normalised AS
WITH raw_labels AS (
    SELECT DISTINCT
        partner_label
    FROM stg_freshdesk_tickets
    WHERE partner_label IS NOT NULL
),
mapped AS (
    SELECT
        partner_label,
        CASE
            WHEN partner_label LIKE '%foxmore%'    THEN 'Foxmore Investor Platform'
            WHEN partner_label LIKE '%clearwater%' THEN 'Clearwater Direct'
            WHEN partner_label LIKE '%aldgate%'    THEN 'Aldgate Direct Access'
            WHEN partner_label LIKE '%waverly%'    THEN 'Waverly Investment Group'
            WHEN partner_label LIKE '%thornton%'   THEN 'Thornton Asset Management'
            WHEN partner_label LIKE '%granville%'  THEN 'Granville Capital'
            WHEN partner_label LIKE '%brockton%'   THEN 'Brockton Wealth Partners'
            WHEN partner_label LIKE '%pemberton%'  THEN 'Pemberton Wealth Advisors'
            WHEN partner_label LIKE '%stirling%'   THEN 'Stirling Wealth Advisors'
            WHEN partner_label LIKE '%meridian%'   THEN 'Meridian Capital Partners'
            WHEN partner_label LIKE '%cavendish%'  THEN 'Cavendish Private Clients'
            WHEN partner_label LIKE '%ashford%'    THEN 'Ashford Wealth Management'
            WHEN partner_label LIKE '%kingsley%'   THEN 'Kingsley Family Office'
            WHEN partner_label LIKE '%hadley%'     THEN 'Hadley & Associates'
            WHEN partner_label LIKE '%norbury%'    THEN 'Norbury & Partners'
            ELSE NULL
        END AS canonical_partner_name
    FROM raw_labels
)
SELECT
    m.partner_label,
    m.canonical_partner_name,
    p.partner_id,
    CASE WHEN m.canonical_partner_name IS NULL THEN TRUE ELSE FALSE END AS is_unrecognised_label
FROM mapped m
LEFT JOIN stg_platform_partners p ON m.canonical_partner_name = p.partner_name;


-- int_ticket_requester_resolved
-- Core entity resolution- classifies every ticket by who raised it
CREATE OR REPLACE TABLE int_ticket_requester_resolved AS
WITH
investor_name_counts AS (
    SELECT full_name_norm, COUNT(*) AS name_count
    FROM stg_platform_investors
    GROUP BY full_name_norm
),
investor_tickets AS (
    SELECT
        t.ticket_id,
        'investor'  AS requester_type,
        i.investor_id,
        i.relationship_manager_id,
        i.entity_id,
        e.partner_id,
        NULL        AS rm_id,
        TRUE        AS investor_resolved,
        FALSE       AS is_ambiguous_match
    FROM stg_freshdesk_tickets t
    INNER JOIN stg_platform_investors i ON t.requester_email = i.email
    INNER JOIN stg_platform_entities e  ON i.entity_id = e.entity_id
),
rm_tickets AS (
    SELECT
        t.ticket_id,
        'rm'        AS requester_type,
        NULL        AS investor_id,
        NULL        AS relationship_manager_id,
        NULL        AS entity_id,
        rm.partner_id,
        rm.rm_id,
        FALSE       AS investor_resolved,
        FALSE       AS is_ambiguous_match
    FROM stg_freshdesk_tickets t
    INNER JOIN stg_platform_relationship_managers rm ON t.requester_email = rm.email
),
internal_tickets AS (
    SELECT
        t.ticket_id,
        'internal_staff' AS requester_type,
        NULL        AS investor_id,
        NULL        AS relationship_manager_id,
        NULL        AS entity_id,
        pl.partner_id,
        NULL        AS rm_id,
        FALSE       AS investor_resolved,
        FALSE       AS is_ambiguous_match
    FROM stg_freshdesk_tickets t
    LEFT JOIN int_partner_label_normalised pl ON t.partner_label = pl.partner_label
    WHERE t.requester_email LIKE '%@titanbay.com'
       OR t.requester_email LIKE '%@titanbay.co.uk'
),
personal_email_tickets AS (
    SELECT
        t.ticket_id,
        'personal_email_investor_match' AS requester_type,
        CASE WHEN nc.name_count = 1 THEN i.investor_id ELSE NULL END        AS investor_id,
        CASE WHEN nc.name_count = 1 THEN i.relationship_manager_id ELSE NULL END AS relationship_manager_id,
        CASE WHEN nc.name_count = 1 THEN i.entity_id ELSE NULL END          AS entity_id,
        CASE WHEN nc.name_count = 1 THEN e.partner_id ELSE pl.partner_id END AS partner_id,
        NULL                                                                 AS rm_id,
        CASE WHEN nc.name_count = 1 THEN TRUE ELSE FALSE END                AS investor_resolved,
        CASE WHEN nc.name_count > 1 THEN TRUE ELSE FALSE END                AS is_ambiguous_match
    FROM stg_freshdesk_tickets t
    LEFT JOIN stg_platform_investors investor_check ON t.requester_email = investor_check.email
    LEFT JOIN stg_platform_relationship_managers rm_check ON t.requester_email = rm_check.email
    INNER JOIN stg_platform_investors i ON t.requester_name_norm = i.full_name_norm
    INNER JOIN investor_name_counts nc  ON i.full_name_norm = nc.full_name_norm
    LEFT JOIN stg_platform_entities e   ON i.entity_id = e.entity_id
    LEFT JOIN int_partner_label_normalised pl ON t.partner_label = pl.partner_label
    WHERE investor_check.investor_id IS NULL
      AND rm_check.rm_id IS NULL
      AND t.requester_email NOT LIKE '%@titanbay.com'
      AND t.requester_email NOT LIKE '%@titanbay.co.uk'
),
all_resolved AS (
    SELECT * FROM investor_tickets
    UNION ALL SELECT * FROM rm_tickets
    UNION ALL SELECT * FROM internal_tickets
    UNION ALL SELECT * FROM personal_email_tickets
)
SELECT
    t.ticket_id,
    t.requester_email,
    t.requester_name,
    t.subject,
    t.status,
    t.priority,
    t.created_at,
    t.resolved_at,
    t.tags,
    t.partner_label,
    r.requester_type,
    r.investor_id,
    r.rm_id,
    r.entity_id,
    r.partner_id,
    r.relationship_manager_id,
    r.investor_resolved,
    r.is_ambiguous_match,
    t.resolved_at IS NOT NULL                       AS is_resolved,
    DATEDIFF('hour', t.created_at, t.resolved_at)  AS resolution_hours
FROM stg_freshdesk_tickets t
INNER JOIN all_resolved r ON t.ticket_id = r.ticket_id;


-- ============================================================
-- LAYER 3: MARTS
-- Analyst-facing output tables- start here for analysis
-- ============================================================

-- mart_investor_support_summary
-- One row per investor- who raises tickets and what patterns exist?
CREATE OR REPLACE TABLE mart_investor_support_summary AS
WITH
investor_tickets AS (
    SELECT * FROM int_ticket_requester_resolved WHERE investor_resolved = TRUE
),
ticket_counts AS (
    SELECT
        investor_id,
        COUNT(*)                                                   AS total_tickets,
        COUNT(*) FILTER (WHERE status = 'open')                    AS tickets_open,
        COUNT(*) FILTER (WHERE status = 'pending')                 AS tickets_pending,
        COUNT(*) FILTER (WHERE status IN ('resolved','closed'))    AS tickets_resolved_closed,
        COUNT(*) FILTER (WHERE priority = 'urgent')                AS tickets_urgent,
        COUNT(*) FILTER (WHERE priority = 'high')                  AS tickets_high,
        COUNT(*) FILTER (WHERE priority = 'medium')                AS tickets_medium,
        COUNT(*) FILTER (WHERE priority = 'low')                   AS tickets_low,
        MIN(created_at)                                            AS first_ticket_at,
        MAX(created_at)                                            AS last_ticket_at,
        AVG(resolution_hours) FILTER (WHERE is_resolved)           AS avg_resolution_hours,
        MAX(resolution_hours)                                      AS max_resolution_hours
    FROM investor_tickets
    GROUP BY investor_id
)
SELECT
    i.investor_id,
    i.full_name                                     AS investor_name,
    i.email                                         AS investor_email,
    i.country,
    i.created_at                                    AS investor_registered_at,
    e.entity_id,
    e.entity_name,
    e.entity_type,
    e.kyc_status,
    p.partner_id,
    p.partner_name,
    p.partner_type,
    rm.rm_id,
    rm.rm_name,
    CASE WHEN i.relationship_manager_id IS NOT NULL THEN TRUE ELSE FALSE END AS is_rm_managed,
    COALESCE(tc.total_tickets, 0)                   AS total_tickets,
    COALESCE(tc.tickets_open, 0)                    AS tickets_open,
    COALESCE(tc.tickets_pending, 0)                 AS tickets_pending,
    COALESCE(tc.tickets_resolved_closed, 0)         AS tickets_resolved_closed,
    COALESCE(tc.tickets_urgent, 0)                  AS tickets_urgent,
    COALESCE(tc.tickets_high, 0)                    AS tickets_high,
    COALESCE(tc.tickets_medium, 0)                  AS tickets_medium,
    COALESCE(tc.tickets_low, 0)                     AS tickets_low,
    tc.first_ticket_at,
    tc.last_ticket_at,
    ROUND(tc.avg_resolution_hours, 1)               AS avg_resolution_hours,
    tc.max_resolution_hours,
    CASE WHEN COALESCE(tc.total_tickets, 0) = 0 THEN TRUE ELSE FALSE END AS has_no_tickets
FROM stg_platform_investors i
INNER JOIN stg_platform_entities e              ON i.entity_id = e.entity_id
INNER JOIN stg_platform_partners p              ON e.partner_id = p.partner_id
LEFT JOIN stg_platform_relationship_managers rm ON i.relationship_manager_id = rm.rm_id
LEFT JOIN ticket_counts tc                      ON i.investor_id = tc.investor_id;


-- mart_ticket_volume_vs_closes
-- One row per month × partner — when will the IS team be under pressure?
CREATE OR REPLACE TABLE mart_ticket_volume_vs_closes AS
WITH
monthly_tickets AS (
    SELECT
        DATE_TRUNC('month', created_at)                            AS ticket_month,
        partner_id,
        COUNT(*)                                                   AS total_tickets,
        COUNT(*) FILTER (WHERE requester_type = 'investor')        AS tickets_from_investors,
        COUNT(*) FILTER (WHERE requester_type = 'rm')              AS tickets_from_rms,
        COUNT(*) FILTER (WHERE requester_type = 'internal_staff')  AS tickets_from_internal,
        COUNT(*) FILTER (WHERE priority IN ('high','urgent'))      AS high_or_urgent_tickets,
        COUNT(*) FILTER (WHERE is_resolved = FALSE)                AS tickets_still_open,
        AVG(resolution_hours) FILTER (WHERE is_resolved)           AS avg_resolution_hours
    FROM int_ticket_requester_resolved
    GROUP BY 1, 2
),
monthly_closes AS (
    SELECT
        DATE_TRUNC('month', scheduled_close_date)                   AS close_month,
        partner_id,
        COUNT(*)                                                    AS closes_in_month,
        SUM(total_committed_aum)                                   AS total_aum_closing,
        MIN(scheduled_close_date)                                  AS earliest_close_date,
        MAX(scheduled_close_date)                                  AS latest_close_date,
        COUNT(*) FILTER (WHERE close_status = 'upcoming')          AS upcoming_closes,
        COUNT(*) FILTER (WHERE close_status = 'completed')         AS completed_closes,
        COUNT(*) FILTER (WHERE close_status = 'cancelled')         AS cancelled_closes,
        STRING_AGG(DISTINCT fund_name, ' | ')                      AS funds_with_closes
    FROM stg_platform_fund_closes
    GROUP BY 1, 2
),
spine AS (
    SELECT
        COALESCE(mt.ticket_month, mc.close_month)   AS month,
        COALESCE(mt.partner_id, mc.partner_id)      AS partner_id,
        mt.total_tickets,
        mt.tickets_from_investors,
        mt.tickets_from_rms,
        mt.tickets_from_internal,
        mt.high_or_urgent_tickets,
        mt.tickets_still_open,
        mt.avg_resolution_hours,
        mc.closes_in_month,
        mc.total_aum_closing,
        mc.earliest_close_date,
        mc.latest_close_date,
        mc.upcoming_closes,
        mc.completed_closes,
        mc.cancelled_closes,
        mc.funds_with_closes
    FROM monthly_tickets mt
    FULL OUTER JOIN monthly_closes mc
        ON mt.ticket_month = mc.close_month
        AND mt.partner_id  = mc.partner_id
)

SELECT
    s.month                                         AS ticket_month,
    s.partner_id,
    p.partner_name,
    p.partner_type,
    COALESCE(s.total_tickets, 0)                    AS total_tickets,
    COALESCE(s.tickets_from_investors, 0)           AS tickets_from_investors,
    COALESCE(s.tickets_from_rms, 0)                 AS tickets_from_rms,
    COALESCE(s.tickets_from_internal, 0)            AS tickets_from_internal,
    COALESCE(s.high_or_urgent_tickets, 0)           AS high_or_urgent_tickets,
    COALESCE(s.tickets_still_open, 0)               AS tickets_still_open,
    ROUND(s.avg_resolution_hours, 1)                AS avg_resolution_hours,
    COALESCE(s.closes_in_month, 0)                  AS closes_in_month,
    COALESCE(s.total_aum_closing, 0)                AS total_aum_closing_gbp,
    s.earliest_close_date,
    s.latest_close_date,
    COALESCE(s.upcoming_closes, 0)                  AS upcoming_closes,
    COALESCE(s.completed_closes, 0)                 AS completed_closes,
    COALESCE(s.cancelled_closes, 0)                 AS cancelled_closes,
    s.funds_with_closes,

    -- Basic pressure flag: true when the month has above-average ticket volume
    -- AND at least one close is scheduled. A simple starting signal for the IS
    -- team to identify months that warrant attention.
    -- See README "What I Would Build Next" for a more sophisticated approach.
    CASE
        WHEN COALESCE(s.total_tickets, 0) > (
            SELECT AVG(total_tickets)
            FROM spine
            WHERE total_tickets > 0
        )
        OR COALESCE(s.closes_in_month, 0) > 0
            THEN TRUE
        ELSE FALSE
    END                                             AS is_pressure_month

FROM spine s
LEFT JOIN stg_platform_partners p ON s.partner_id = p.partner_id
ORDER BY s.month, p.partner_name;

-- mart_ticket_tags_exploded
-- Grain: ONE ROW PER TICKET PER TAG
--        A ticket with 3 tags produces 3 rows.
CREATE OR REPLACE TABLE mart_ticket_tags_exploded AS

SELECT
    t.ticket_id,
    t.created_at,
    t.status,
    t.priority,
    t.requester_type,
    t.investor_id,
    t.rm_id,
    t.partner_id,
    t.investor_resolved,
    t.is_resolved,
    t.resolution_hours,

    -- The exploded tag — one row per tag per ticket
    TRIM(tag.value)                 AS tag,

    -- Investor context (where resolvable)
    i.full_name                     AS investor_name,
    i.country,

    -- Partner context
    p.partner_name,
    p.partner_type,

    -- RM context
    rm.rm_name

FROM int_ticket_requester_resolved t
-- UNNEST splits the comma-separated tags string into individual rows
CROSS JOIN UNNEST(string_split(t.tags, ',')) AS tag(value)
LEFT JOIN stg_platform_investors i
    ON t.investor_id = i.investor_id
LEFT JOIN stg_platform_partners p
    ON t.partner_id = p.partner_id
LEFT JOIN stg_platform_relationship_managers rm
    ON t.rm_id = rm.rm_id;