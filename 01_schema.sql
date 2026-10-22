DROP TABLE IF EXISTS subscription_version CASCADE;
DROP TABLE IF EXISTS plan_price_version CASCADE;
DROP TABLE IF EXISTS title_licence_version CASCADE;

DROP TABLE IF EXISTS subscriber CASCADE;
DROP TABLE IF EXISTS plan CASCADE;
DROP TABLE IF EXISTS title CASCADE;
DROP TABLE IF EXISTS region CASCADE;
DROP TABLE IF EXISTS tx_registry CASCADE;


-- Transaction Registry
CREATE TABLE tx_registry (
    tx_id BIGSERIAL PRIMARY KEY,
    tx_time TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    author VARCHAR(100) NOT NULL,
    reason VARCHAR(255) NOT NULL
);

-- Anchors
CREATE TABLE subscriber (
    subscriber_id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    join_date DATE NOT NULL
);

CREATE TABLE plan (
    plan_id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    max_screens INT NOT NULL
);

CREATE TABLE title (
    title_id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    release_year INT NOT NULL
);

CREATE TABLE region (
    region_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE
);


-- Bitemporal Version Tables

-- Plan Price Version (Role that changes)
CREATE TABLE plan_price_version (
    version_id BIGSERIAL PRIMARY KEY,
    plan_id INT NOT NULL,
    price_eur DECIMAL(10, 2) NOT NULL,
    
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    tx_from TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    tx_to TIMESTAMP(6) WITH TIME ZONE NOT NULL DEFAULT '9999-12-31 23:59:59.999999',
    tx_id BIGINT NOT NULL,

    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    FOREIGN KEY (tx_id) REFERENCES tx_registry(tx_id),
    
    CHECK (valid_from < valid_to),
    CHECK (tx_from < tx_to)
);

-- Title Licence Version (Relationship)
CREATE TABLE title_licence_version (
    version_id BIGSERIAL PRIMARY KEY,
    title_id INT NOT NULL,
    region_id INT NOT NULL,
    
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    tx_from TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    tx_to TIMESTAMP(6) WITH TIME ZONE NOT NULL DEFAULT '9999-12-31 23:59:59.999999',
    tx_id BIGINT NOT NULL,

    FOREIGN KEY (title_id) REFERENCES title(title_id),
    FOREIGN KEY (region_id) REFERENCES region(region_id),
    FOREIGN KEY (tx_id) REFERENCES tx_registry(tx_id),
    
    CHECK (valid_from < valid_to),
    CHECK (tx_from < tx_to)
);

-- Subscription Version (Relationship)
CREATE TABLE subscription_version (
    version_id BIGSERIAL PRIMARY KEY,
    subscriber_id INT NOT NULL,
    plan_id INT NOT NULL,
    
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    tx_from TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    tx_to TIMESTAMP(6) WITH TIME ZONE NOT NULL DEFAULT '9999-12-31 23:59:59.999999',
    tx_id BIGINT NOT NULL,

    FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id),
    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    FOREIGN KEY (tx_id) REFERENCES tx_registry(tx_id),
    
    CHECK (valid_from < valid_to),
    CHECK (tx_from < tx_to)
);

-- As-Of Index
CREATE INDEX ix_subscription_asof ON subscription_version (subscriber_id, tx_to, valid_from);
