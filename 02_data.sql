-- E1: System goes live on January 1, 2025.
SET session "app.sim_now" = '2025-01-01 14:00:00';

-- E1: Initial load in 1 transaction
DO $$
DECLARE
    v_tx_id BIGINT;
    v_now TIMESTAMP(6) WITH TIME ZONE := current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
BEGIN
    INSERT INTO tx_registry (tx_time, author, reason) 
    VALUES (v_now, 'system', 'E1: System goes live with initial load') 
    RETURNING tx_id INTO v_tx_id;

    -- Insert 5 Plans (Role holders)
    INSERT INTO plan (name, max_screens) VALUES
        ('Basic', 1),
        ('Standard', 2),
        ('Premium', 4),
        ('Family', 6),
        ('Crew', 10);

    -- Insert Plan Prices
    INSERT INTO plan_price_version (plan_id, price_eur, valid_from, tx_from, tx_id)
    SELECT plan_id, 
        CASE plan_id 
            WHEN 1 THEN 7.99 
            WHEN 2 THEN 10.99 
            WHEN 3 THEN 14.99 
            WHEN 4 THEN 17.99 
            WHEN 5 THEN 24.99 
        END,
        '2025-01-01', v_now, v_tx_id
    FROM plan;

    -- Insert 6 Titles (Central objects)
    INSERT INTO title (name, release_year) VALUES
        ('The Matrix', 1999),
        ('Dexter', 2006),
        ('Interstellar', 2014),
        ('The Godfather', 1972),
        ('Breaking Bad', 2008),
        ('Game of Thrones', 2011);

    -- Insert Regions
    INSERT INTO region (name) 
    VALUES ('United States'), ('United Kingdom'), ('Romania'), ('Germany'), ('France'), ('Poland');

    -- Insert Title Licences
    INSERT INTO title_licence_version (title_id, region_id, valid_from, tx_from, tx_id)
    SELECT t.title_id, r.region_id, '2025-01-01', v_now, v_tx_id
    FROM title t CROSS JOIN region r;

    -- Insert 50 Subscribers
    FOR i IN 1..50 LOOP
        INSERT INTO subscriber (email, join_date) 
        VALUES ('subscriber' || i || '@example.com', '2025-01-01');
    END LOOP;

    -- Insert 50 Subscriptions (Relationship facts)
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    SELECT subscriber_id, (subscriber_id % 5) + 1, '2025-01-01', v_now, v_tx_id
    FROM subscriber;
END $$;
