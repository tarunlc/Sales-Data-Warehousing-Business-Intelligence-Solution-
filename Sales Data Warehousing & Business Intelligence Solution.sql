-- 0) DROP & RECREATE DATABASE
DROP DATABASE IF EXISTS retail_analytics;
CREATE DATABASE retail_analytics;
USE retail_analytics;

-- 1) RAW TRANSACTIONS
CREATE TABLE IF NOT EXISTS raw_transactions (
    invoice_no   VARCHAR(20),
    stock_code   VARCHAR(20),
    description  TEXT,
    quantity     INT,
    invoice_date DATETIME,
    unit_price   DECIMAL(10,2),
    customer_id  VARCHAR(10),
    country      VARCHAR(50)
);

-- 2) SAMPLE DATA
INSERT INTO raw_transactions
    (invoice_no, stock_code, description, quantity, invoice_date, unit_price, customer_id, country)
VALUES
('536365','85123A','WHITE HANGING HEART T-LIGHT HOLDER',6,'2010-12-01 08:26:00',2.55,'17850','United Kingdom'),
('536365','71053', 'WHITE METAL LANTERN',              6,'2010-12-01 08:26:00',3.39,'17850','United Kingdom'),
('536365','84406B','CREAM CUPID HEARTS COAT HANGER',  8,'2010-12-01 08:26:00',2.75,'17850','United Kingdom'),
('536366','22633', 'HAND WARMER UNION JACK',          6,'2010-12-01 08:28:00',1.85,'17850','United Kingdom'),
('536367','84379', 'SMALL POPCORN HOLDER',           32,'2010-12-01 08:34:00',1.69,'13047','United Kingdom'),
('536367','22386', 'JUMBO BAG ALPHABET',              6,'2010-12-01 08:34:00',1.95,'13047','United Kingdom'),
('536368','84879', 'ASSORTED COLOUR BIRD ORNAMENT',  32,'2010-12-01 08:34:00',1.69,'13047','United Kingdom'),
('536369','22960', 'JAM MAKING SET WITH JARS',       12,'2010-12-01 08:35:00',4.95,'13047','United Kingdom'),
('536370','22913', 'NATURAL SLATE HEART CHALKBOARD', 12,'2010-12-01 08:45:00',4.95,'12583','France'),
('536371','22914', 'SMALL WOODEN HEART DECORATION',  12,'2010-12-01 08:45:00',4.95,'12583','France');

-- 3) CLEANED TRANSACTIONS
CREATE TABLE IF NOT EXISTS cleaned_transactions AS
SELECT 
    invoice_no,
    stock_code,
    COALESCE(description,'Unknown Product') AS description,
    quantity,
    invoice_date,
    unit_price,
    COALESCE(customer_id,'UNKNOWN')      AS customer_id,
    COALESCE(country,'Unknown')          AS country,
    quantity * unit_price               AS line_total
FROM raw_transactions
WHERE quantity > 0
  AND unit_price > 0
  AND invoice_date IS NOT NULL;

-- 4) DATE DIMENSION
CREATE TABLE IF NOT EXISTS dim_date (
    date_key      INT        PRIMARY KEY,
    full_date     DATE,
    year          INT,
    quarter       INT,
    month         INT,
    month_name    VARCHAR(20),
    day           INT,
    day_name      VARCHAR(20),
    week_of_year  INT,
    is_weekend    BOOLEAN
);

INSERT IGNORE INTO dim_date
SELECT
  DATE_FORMAT(dt, '%Y%m%d')                   AS date_key,
  dt                                          AS full_date,
  YEAR(dt)                                    AS year,
  QUARTER(dt)                                 AS quarter,
  MONTH(dt)                                   AS month,
  MONTHNAME(dt)                               AS month_name,
  DAY(dt)                                     AS day,
  DAYNAME(dt)                                 AS day_name,
  WEEK(dt,1)                                  AS week_of_year,
  CASE WHEN DAYOFWEEK(dt) IN (1,7) THEN TRUE ELSE FALSE END AS is_weekend
FROM (
  SELECT DISTINCT DATE(invoice_date) AS dt
  FROM cleaned_transactions
) AS dates;

-- 5) PRODUCT DIMENSION
CREATE TABLE IF NOT EXISTS dim_products (
    product_key  INT AUTO_INCREMENT PRIMARY KEY,
    stock_code   VARCHAR(20),
    product_name TEXT,
    category     VARCHAR(50),
    subcategory  VARCHAR(50)
);

INSERT INTO dim_products (stock_code, product_name, category, subcategory)
SELECT DISTINCT
    stock_code,
    description AS product_name,
    CASE
      WHEN UPPER(description) LIKE '%HEART%' OR UPPER(description) LIKE '%LOVE%'   THEN 'Decorative'
      WHEN UPPER(description) LIKE '%HOLDER%' OR UPPER(description) LIKE '%LANTERN%' THEN 'Home & Garden'
      WHEN UPPER(description) LIKE '%BAG%' OR UPPER(description) LIKE '%HANGER%'     THEN 'Storage & Organization'
      WHEN UPPER(description) LIKE '%SET%' OR UPPER(description) LIKE '%KIT%'        THEN 'Sets & Kits'
      ELSE 'General Merchandise'
    END AS category,
    CASE
      WHEN UPPER(description) LIKE '%WHITE%'              THEN 'White Items'
      WHEN UPPER(description) LIKE '%METAL%'              THEN 'Metal Products'
      WHEN UPPER(description) LIKE '%WOODEN%' OR UPPER(description) LIKE '%WOOD%' THEN 'Wood Products'
      ELSE 'Other'
    END AS subcategory
FROM cleaned_transactions;

-- 6) CUSTOMER DIMENSION
CREATE TABLE IF NOT EXISTS dim_customers (
    customer_key       INT AUTO_INCREMENT PRIMARY KEY,
    customer_id        VARCHAR(10),
    country            VARCHAR(50),
    customer_segment   VARCHAR(20),
    first_purchase_date DATE,
    total_orders       INT,
    total_spent        DECIMAL(12,2)
);

INSERT INTO dim_customers (customer_id, country, customer_segment, first_purchase_date, total_orders, total_spent)
SELECT
  customer_id,
  country,
  CASE
    WHEN SUM(quantity*unit_price) >= 1000 AND COUNT(DISTINCT invoice_no) >= 10 THEN 'VIP'
    WHEN SUM(quantity*unit_price) >=  500 AND COUNT(DISTINCT invoice_no) >=  5 THEN 'High Value'
    WHEN SUM(quantity*unit_price) >=  100 AND COUNT(DISTINCT invoice_no) >=  3 THEN 'Regular'
    ELSE 'New/Low Value'
  END AS customer_segment,
  MIN(DATE(invoice_date))                       AS first_purchase_date,
  COUNT(DISTINCT invoice_no)                    AS total_orders,
  SUM(quantity*unit_price)                      AS total_spent
FROM cleaned_transactions
WHERE customer_id <> 'UNKNOWN'
GROUP BY customer_id, country;

-- 7) SALES FACT
CREATE TABLE IF NOT EXISTS sales_fact (
    sales_key       INT AUTO_INCREMENT PRIMARY KEY,
    date_key        INT,
    product_key     INT,
    customer_key    INT,
    invoice_no      VARCHAR(20),
    quantity        INT,
    unit_price      DECIMAL(10,2),
    line_total      DECIMAL(12,2),
    discount_amount DECIMAL(10,2) DEFAULT 0,
    net_amount      DECIMAL(12,2),
    FOREIGN KEY (date_key)     REFERENCES dim_date(date_key),
    FOREIGN KEY (product_key)  REFERENCES dim_products(product_key),
    FOREIGN KEY (customer_key) REFERENCES dim_customers(customer_key)
);

INSERT INTO sales_fact (date_key, product_key, customer_key, invoice_no, quantity, unit_price, line_total, net_amount)
SELECT
  DATE_FORMAT(ct.invoice_date, '%Y%m%d') AS date_key,
  dp.product_key,
  dc.customer_key,
  ct.invoice_no,
  ct.quantity,
  ct.unit_price,
  ct.line_total,
  ct.line_total AS net_amount
FROM cleaned_transactions ct
JOIN dim_products dp ON ct.stock_code   = dp.stock_code
JOIN dim_customers dc ON ct.customer_id = dc.customer_id;

-- 8) INDEXES
CREATE INDEX idx_sales_date     ON sales_fact(date_key);
CREATE INDEX idx_sales_product  ON sales_fact(product_key);
CREATE INDEX idx_sales_customer ON sales_fact(customer_key);
CREATE INDEX idx_products_cat   ON dim_products(category);
CREATE INDEX idx_customers_seg  ON dim_customers(customer_segment);

-- 9) DASHBOARD SUMMARY VIEW
CREATE OR REPLACE VIEW dashboard_summary AS
SELECT 'Total Revenue'      AS metric, CONCAT('$', FORMAT(SUM(net_amount),2)) AS value FROM sales_fact
UNION ALL
SELECT 'Total Orders',      FORMAT(COUNT(DISTINCT invoice_no),0)            FROM sales_fact
UNION ALL
SELECT 'Total Customers',   FORMAT(COUNT(DISTINCT customer_key),0)          FROM sales_fact
UNION ALL
SELECT 'Average Order Value', CONCAT('$', FORMAT(AVG(net_amount),2))        FROM sales_fact;

-- 10) FINAL VERIFICATION
SELECT 'raw_transactions'       AS table_name, COUNT(*) FROM raw_transactions
UNION ALL
SELECT 'cleaned_transactions', COUNT(*) FROM cleaned_transactions
UNION ALL
SELECT 'dim_date',              COUNT(*) FROM dim_date
UNION ALL
SELECT 'dim_products',          COUNT(*) FROM dim_products
UNION ALL
SELECT 'dim_customers',         COUNT(*) FROM dim_customers
UNION ALL
SELECT 'sales_fact',            COUNT(*) FROM sales_fact;
