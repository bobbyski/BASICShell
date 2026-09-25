-- A schema written for a database, not for BASIC.
--
-- Names, types and constraints are spelled the way a DBA would spell them;
-- nothing here was bent toward the importer.

CREATE TABLE IF NOT EXISTS customers (
    customer_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    "Full Name"    VARCHAR(120) NOT NULL,
    email_address  TEXT UNIQUE,
    balance_cents  BIGINT DEFAULT 0,
    is_vip         TINYINT(1) NOT NULL DEFAULT 0,
    discount_rate  DOUBLE PRECISION,
    lifetime_value DECIMAL(12,2),
    signed_up_on   DATE,
    -- a default whose text says PRIMARY, which is not a constraint
    notes          TEXT DEFAULT 'primary contact'
);

CREATE TABLE orders (
    order_id    INT NOT NULL,
    customer_id INT NOT NULL REFERENCES customers (customer_id),
    placed_at   TIMESTAMP,
    total       NUMERIC(10, 2),
    PRIMARY KEY (order_id),
    CONSTRAINT uq_orders_customer UNIQUE (customer_id),
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);

CREATE INDEX ix_orders_placed ON orders (placed_at);

/* Not a table, and not the importer's business. */
INSERT INTO customers ("Full Name") VALUES ('Ada Lovelace');
GRANT SELECT ON customers TO reporting;
