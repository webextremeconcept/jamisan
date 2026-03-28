-- Migration 006: Seed niches, departments, brands, and products
-- Run AFTER Migration 005
-- Order: niches first → departments → brands → products (FK dependency chain)

-- Step 1: Seed niches
INSERT INTO niches (name, is_active) VALUES
  ('Beauty', true),
  ('Tech', true),
  ('Fashion', true),
  ('Auto', true)
ON CONFLICT DO NOTHING;

-- Step 2: Rename Gadgets → Tech, add Fashion and Auto
-- (Beauty=id 1 and Gadgets=id 2 already exist from Module 1 seed)
UPDATE departments SET name = 'Tech' WHERE name = 'Gadgets';
INSERT INTO departments (name) VALUES
  ('Fashion'),
  ('Auto')
ON CONFLICT DO NOTHING;

-- Step 3: Seed brands (requires department_id and niche_id)
INSERT INTO brands (name, department_id, niche_id, is_active) VALUES
  ('mimadealsng.com',   (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM niches WHERE name='Tech'),    true),
  ('itmegadeals.com',   (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM niches WHERE name='Tech'),    true),
  ('clearbyjane.com',   (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM niches WHERE name='Beauty'), true),
  ('jemsdiscount.com',  (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM niches WHERE name='Fashion'),true),
  ('jolsdiscount.com',  (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM niches WHERE name='Fashion'),true),
  ('autoboltz.com',     (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM niches WHERE name='Auto'),   true),
  ('clearlikeglass.com',(SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM niches WHERE name='Beauty'), true),
  ('clearbytemi.com',   (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM niches WHERE name='Beauty'), true),
  ('temiqueglow.com',   (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM niches WHERE name='Beauty'), true),
  ('clearbyzoe.com',    (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM niches WHERE name='Beauty'), true)
ON CONFLICT DO NOTHING;

-- Step 4: Seed products
INSERT INTO products (name, department_id, brand_id, type, category, price, status, is_active) VALUES
  ('Gaming Earbud',            (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       'Mixed',        0.00, 'Active', true),
  ('Bone Conductor Earbud',    (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       'Mixed',        0.00, 'Active', true),
  ('Industrial Earbud',        (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='itmegadeals.com'),    'Main',       'Mixed',        0.00, 'Active', true),
  ('Golden Smartwatch',        (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       'Mixed',        0.00, 'Active', true),
  ('2 in 1 Speaker',           (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       'Mixed',        0.00, 'Active', true),
  ('Neck Wrinkle Cream',       (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbyjane.com'),   'Main',       'Mixed',        0.00, 'Active', true),
  ('Scar and Stretch Mark',    (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbyjane.com'),   'Main',       'Mixed',        0.00, 'Active', true),
  ('Phone Holder',             (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Order_Bump', 'Accessory',    0.00, 'Active', true),
  ('7 in 1 Cleaner',           (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Upsell',     NULL,           0.00, 'Active', true),
  ('Curren Official',          (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Watches',      0.00, 'Active', true),
  ('Curren Sport',             (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       'Watches',      0.00, 'Active', true),
  ('Curren Ladies',            (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Watches',      0.00, 'Active', true),
  ('Gentleman Combination',    (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Mixed',        0.00, 'Active', true),
  ('Casual Combination',       (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jolsdiscount.com'),  'Main',       'Mixed',        0.00, 'Active', true),
  ('Supplementary',            (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Mixed',        0.00, 'Active', true),
  ('Clover Jewellery Set',     (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Mixed Ladies', 0.00, 'Active', true),
  ('Compass Jewellery Set',    (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       'Jewellery',    0.00, 'Active', true),
  ('Single Curren Watch',      (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jolsdiscount.com'),  'Main',       NULL,           0.00, 'Active', true),
  ('Office Watch',             (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jolsdiscount.com'),  'Main',       NULL,           0.00, 'Active', true),
  ('Driving Assistant Package',(SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       'Mixed',        0.00, 'Active', true),
  ('Car Emergency Toolkit',    (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       'Accessory',    0.00, 'Active', true),
  ('Car Dashboard Enhancer',   (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       NULL,           0.00, 'Active', true),
  ('Car Table',                (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       'Mixed',        0.00, 'Active', true),
  ('Car Caution Triangle',     (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       'Accessory',    0.00, 'Active', true),
  ('Car Wheel Spinner',        (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Order_Bump', NULL,           0.00, 'Active', true),
  ('Car Dent Puller',          (SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Order_Bump', 'Accessory',    0.00, 'Active', true),
  ('Brooch',                   (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Order_Bump', NULL,           0.00, 'Active', true),
  ('Belt',                     (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       NULL,           0.00, 'Active', true),
  ('Bracelet',                 (SELECT id FROM departments WHERE name='Fashion'), (SELECT id FROM brands WHERE name='jemsdiscount.com'),  'Main',       NULL,           0.00, 'Active', true),
  ('Smart Chargers',           (SELECT id FROM departments WHERE name='Tech'),    (SELECT id FROM brands WHERE name='mimadealsng.com'),    'Main',       NULL,           0.00, 'Active', true),
  ('Solar Helicopter Freshner',(SELECT id FROM departments WHERE name='Auto'),    (SELECT id FROM brands WHERE name='autoboltz.com'),     'Main',       NULL,           0.00, 'Active', true),
  ('Pimple Blaster Cream',     (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearlikeglass.com'),'Main',       NULL,           0.00, 'Active', true),
  ('Dark Spot Removal Cream',  (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbytemi.com'),   'Main',       NULL,           0.00, 'Active', true),
  ('Anti Aging Cream',         (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbyjane.com'),   'Main',       NULL,           0.00, 'Active', true),
  ('Tumeric Soap',             (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='temiqueglow.com'),   'Order_Bump', NULL,           0.00, 'Active', true),
  ('Temique Turmeric Soap',    (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbyzoe.com'),    'Main',       NULL,           0.00, 'Active', true),
  ('Temique Acne Gel',         (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearlikeglass.com'),'Main',       NULL,           0.00, 'Active', true),
  ('Temique Stretchmarks Cream',(SELECT id FROM departments WHERE name='Beauty'), (SELECT id FROM brands WHERE name='clearbyjane.com'),   'Main',       NULL,           0.00, 'Active', true),
  ('Temique Darkspot Serum',   (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='clearbytemi.com'),   'Main',       NULL,           0.00, 'Active', true),
  ('Temique Brush',            (SELECT id FROM departments WHERE name='Beauty'),  (SELECT id FROM brands WHERE name='temiqueglow.com'),   'Order_Bump', NULL,           0.00, 'Active', true)
ON CONFLICT DO NOTHING;

-- Step 5: Seed Miscellaneous fallback product (used when product_name doesn't match any known product)
INSERT INTO products (name, department_id, brand_id, type, price, status, is_active)
SELECT
  'Miscellaneous',
  (SELECT id FROM departments WHERE name='Tech' LIMIT 1),
  (SELECT id FROM brands WHERE name='mimadealsng.com' LIMIT 1),
  'Main', 0.00, 'Active', true
WHERE NOT EXISTS (SELECT 1 FROM products WHERE name = 'Miscellaneous');
