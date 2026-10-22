-- E2: Proactive change: 1 price hike, 2 scheduled cancellations
SET session "app.sim_now" = '2025-01-15 10:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'admin', 'E2: Announce upcoming price hike and scheduled cancellations') 
    RETURNING tx_id INTO v_tx_id;

    -- E2(1): Basic plan price increases next month (Feb 1)
    SELECT version_id INTO v_vid 
    FROM plan_price_version 
    WHERE plan_id = 1 AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE plan_price_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, valid_to, tx_from, tx_id)
    SELECT plan_id, price_eur, valid_from, '2025-02-01', v_now, v_tx_id 
    FROM plan_price_version 
    WHERE version_id = v_vid;
    
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
    SELECT plan_id, 8.99, '2025-02-01', v_now, v_tx_id 
    FROM plan_price_version 
    WHERE version_id = v_vid;

    -- E2(2) & E2(3): Subscribers 1 & 2 schedule cancellation for Feb 1
    FOR i IN 1..2 LOOP
        SELECT version_id INTO v_vid 
        FROM subscription_version 
        WHERE subscriber_id = i AND tx_to = '9999-12-31 23:59:59.999999';

        UPDATE subscription_version 
        SET tx_to = v_now 
        WHERE version_id = v_vid;

        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        SELECT subscriber_id, plan_id, valid_from, '2025-02-01', v_now, v_tx_id 
        FROM subscription_version 
        WHERE version_id = v_vid;
    END LOOP;
END $$;

-- E3: Late entry: 1 price change, 4 subscription upgrades
SET session "app.sim_now" = '2025-03-10 14:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'clerk', 'E3: Late entries for Premium price and subscription upgrades') 
    RETURNING tx_id INTO v_tx_id;

    -- E3(1): Clerk records that Premium price changed to 17.99 on 1 Mar (9 days late)
    SELECT version_id INTO v_vid 
    FROM plan_price_version 
    WHERE plan_id = 3 AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE plan_price_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, valid_to, tx_from, tx_id)
    SELECT plan_id, price_eur, valid_from, '2025-03-01', v_now, v_tx_id 
    FROM plan_price_version 
    WHERE version_id = v_vid;
    
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
    SELECT plan_id, 17.99, '2025-03-01', v_now, v_tx_id 
    FROM plan_price_version
    WHERE version_id = v_vid;

    -- E3(2-5): Subscribers 5 to 8 upgraded their plan to Plan 5 (Crew) on Mar 1, recorded Mar 10 (9 days late)
    FOR i IN 5..8 LOOP
        SELECT version_id INTO v_vid 
        FROM subscription_version 
        WHERE subscriber_id = i AND tx_to = '9999-12-31 23:59:59.999999';
        
        UPDATE subscription_version 
        SET tx_to = v_now
        WHERE version_id = v_vid;
        
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        SELECT subscriber_id, plan_id, valid_from, '2025-03-01', v_now, v_tx_id 
        FROM subscription_version 
        WHERE version_id = v_vid;
        
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
        SELECT subscriber_id, 5, '2025-03-01', v_now, v_tx_id
        FROM subscription_version 
        WHERE version_id = v_vid;
    END LOOP;
END $$;

-- E4: Correction 1 date correction, 2 typo corrections.
SET session "app.sim_now" = '2025-03-15 11:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid1 BIGINT;
    v_vid2 BIGINT;
    v_vid BIGINT;
    v_sv_vid1 BIGINT;
    v_sv_vid2 BIGINT;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, 'admin', 'E4: Corrections to story date and plan typos')
    RETURNING tx_id INTO v_tx_id;

    -- E4(1): Admin notices the Mar 1 change was actually on Mar 3
    SELECT version_id INTO v_vid1 
    FROM plan_price_version 
    WHERE plan_id = 3 AND valid_to = '2025-03-01' AND tx_to = '9999-12-31 23:59:59.999999';

    SELECT version_id INTO v_vid2 
    FROM plan_price_version 
    WHERE plan_id = 3 AND valid_from = '2025-03-01' AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE plan_price_version 
    SET tx_to = v_now 
    WHERE version_id IN (v_vid1, v_vid2);

    -- Re-insert old price up to Mar 3
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, valid_to, tx_from, tx_id)
    SELECT plan_id, price_eur, valid_from, '2025-03-03', v_now, v_tx_id
    FROM plan_price_version
    WHERE version_id = v_vid1;
    
    -- Re-insert new price from Mar 3
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
    SELECT plan_id, price_eur, '2025-03-03', v_now, v_tx_id 
    FROM plan_price_version 
    WHERE version_id = v_vid2;

    -- E4(1b): Admin corrects Subscriber 5 upgrade date from Mar 1 to Mar 3
    SELECT version_id INTO v_sv_vid1 
    FROM subscription_version 
    WHERE subscriber_id = 5 AND valid_to = '2025-03-01' AND tx_to = '9999-12-31 23:59:59.999999';

    SELECT version_id INTO v_sv_vid2 
    FROM subscription_version 
    WHERE subscriber_id = 5 AND valid_from = '2025-03-01' AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id IN (v_sv_vid1, v_sv_vid2);

    -- Re-insert Subscriber 5 initial plan (Plan 1) up to Mar 3
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, '2025-03-03', v_now, v_tx_id
    FROM subscription_version
    WHERE version_id = v_sv_vid1;
    
    -- Re-insert Subscriber 5 upgraded plan (Plan 5) starting Mar 3
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, '2025-03-03', valid_to, v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_sv_vid2;

    -- Correction 2 & 3: Correcting prices for plans 4 & 5 (Family & Crew)
    FOR p_id IN 4..5 LOOP
        SELECT version_id INTO v_vid 
        FROM plan_price_version
        WHERE plan_id = p_id AND tx_to = '9999-12-31 23:59:59.999999';

        UPDATE plan_price_version 
        SET tx_to = v_now 
        WHERE version_id = v_vid;

        INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
        SELECT plan_id, price_eur - 0.50, valid_from, v_now, v_tx_id 
        FROM plan_price_version 
        WHERE version_id = v_vid;
    END LOOP;
END $$;

-- E5: Real-world end: Subscribers 10-14 cancel immediately (10 Apr)
SET session "app.sim_now" = '2025-04-10 12:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'system', 'E5: 5 Subscribers cancel immediately') RETURNING tx_id INTO v_tx_id;

    FOR i IN 10..14 LOOP
        SELECT version_id INTO v_vid 
        FROM subscription_version 
        WHERE subscriber_id = i AND tx_to = '9999-12-31 23:59:59.999999';

        UPDATE subscription_version 
        SET tx_to = v_now
        WHERE version_id = v_vid;
        
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        SELECT subscriber_id, plan_id, valid_from, '2025-04-10', v_now, v_tx_id 
        FROM subscription_version 
        WHERE version_id = v_vid;
    END LOOP;
END $$;

-- E6: Restart after a gap: Subscribers 1, 2 (cancelled Feb 1) and Sub 10 (cancelled Apr 10)
-- rejoin the SAME plan they left, creating a detectable gap
SET session "app.sim_now" = '2025-06-01 09:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'user', 'E6: 3 Subscribers (1, 2, 10) resubscribe after a gap') 
    RETURNING tx_id INTO v_tx_id;

    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id) 
    VALUES (1, 2, '2025-06-01', v_now, v_tx_id),
           (2, 3, '2025-06-01', v_now, v_tx_id),
           (10, 1, '2025-06-01', v_now, v_tx_id);
END $$;

-- E7: Role holder changes: 2 changes mid-period: Price changes for plans 1 and 2 on Aug 1
-- The 3rd E7 event happens in E3, when the price of plan 3 is changed to 17.99 on Mar 1,
-- then in E4 we correct the date of that change to Mar 3 => 'The story'
SET session "app.sim_now" = '2025-08-01 10:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'admin', 'E7: Price changes for plans 1 and 2') 
    RETURNING tx_id INTO v_tx_id;

    FOR p_id IN 1..2 LOOP
        SELECT version_id INTO v_vid 
        FROM plan_price_version 
        WHERE plan_id = p_id
          AND tx_to = '9999-12-31 23:59:59.999999'
          AND valid_to = '9999-12-31';

        UPDATE plan_price_version 
        SET tx_to = v_now 
        WHERE version_id = v_vid;
        
        INSERT INTO plan_price_version (plan_id, price_eur, valid_from, valid_to, tx_from, tx_id)
        SELECT plan_id, price_eur, valid_from, '2025-08-01', v_now, v_tx_id 
        FROM plan_price_version
        WHERE version_id = v_vid;

        INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
        SELECT plan_id, price_eur + 1.50, '2025-08-01', v_now, v_tx_id 
        FROM plan_price_version 
        WHERE version_id = v_vid;
    END LOOP;
END $$;

-- E8/1: Erroneous insert: Subscriber 15 with Plan 1 gets accidentally upgraded to Plan 3 on 1 Oct
SET session "app.sim_now" = '2025-10-01 10:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    -- MISTAKE: Subscriber 15 is accidentally upgraded
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'clerk', 'Mistake: Subscriber 15 upgraded by accident') 
    RETURNING tx_id INTO v_tx_id;

    SELECT version_id INTO v_vid 
    FROM subscription_version 
    WHERE subscriber_id = 15 AND tx_to = '9999-12-31 23:59:59.999999';
    
    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, '2025-10-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    SELECT subscriber_id, 3, '2025-10-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;
END $$;

-- E8/2: Retract the erroneous insert from E8/1 on 2 Oct
SET session "app.sim_now" = '2025-10-02 10:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, 'clerk', 'E8: Retract mistaken upgrade')
    RETURNING tx_id INTO v_tx_id;
    
    UPDATE subscription_version
    SET tx_to = v_now
    WHERE subscriber_id = 15 AND plan_id = 3 AND tx_to = '9999-12-31 23:59:59.999999';
    
    UPDATE subscription_version
    SET tx_to = v_now
    WHERE subscriber_id = 15 AND valid_to = '2025-10-01' AND tx_to = '9999-12-31 23:59:59.999999';
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, v_now, v_tx_id 
    FROM subscription_version 
    WHERE subscriber_id = 15 AND valid_to = '2025-10-01' AND tx_to = v_now;
END $$;

-- E9: 2 bundles, each performing 2 changes across 2 tables
SET session "app.sim_now" = '2025-12-01 10:00:00';
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    v_vid BIGINT;
BEGIN
    -- Bundle 1: Subscriber 30 upgrades to Plan 2 and Title 4 loses license in Region 1 (US)
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'admin', 'E9: Bundle operation 1') 
    RETURNING tx_id INTO v_tx_id;

    SELECT version_id INTO v_vid 
    FROM subscription_version 
    WHERE subscriber_id = 30 AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, '2025-12-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    SELECT subscriber_id, 2, '2025-12-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;

    -- Now proceeding with Title license revocation for Title 4 in Region 1
    SELECT version_id INTO v_vid 
    FROM title_licence_version 
    WHERE title_id = 4 AND region_id = 1 AND tx_to = '9999-12-31 23:59:59.999999';
    
    UPDATE title_licence_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO title_licence_version (title_id, region_id, valid_from, valid_to, tx_from, tx_id)
    SELECT title_id, region_id, valid_from, '2025-12-01', v_now, v_tx_id 
    FROM title_licence_version 
    WHERE version_id = v_vid;

    -- Bundle 2: Subscriber 31 upgrades to Plan 3 and Title 5 loses license in Region 1 (US)
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'admin', 'E9: Bundle operation 2') 
    RETURNING tx_id INTO v_tx_id;

    SELECT version_id INTO v_vid 
    FROM subscription_version
    WHERE subscriber_id = 31 AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, '2025-12-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;
    
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    SELECT subscriber_id, 3, '2025-12-01', v_now, v_tx_id 
    FROM subscription_version 
    WHERE version_id = v_vid;

    SELECT version_id INTO v_vid 
    FROM title_licence_version 
    WHERE title_id = 5 AND region_id = 1 AND tx_to = '9999-12-31 23:59:59.999999';

    UPDATE title_licence_version 
    SET tx_to = v_now 
    WHERE version_id = v_vid;
    
    INSERT INTO title_licence_version (title_id, region_id, valid_from, valid_to, tx_from, tx_id)
    SELECT title_id, region_id, valid_from, '2025-12-01', v_now, v_tx_id 
    FROM title_licence_version 
    WHERE version_id = v_vid;
END $$;
