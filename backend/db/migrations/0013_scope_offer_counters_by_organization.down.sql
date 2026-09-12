ALTER TABLE offer_counters DROP CONSTRAINT offer_counters_pkey;
ALTER TABLE offer_counters ADD PRIMARY KEY (year);
ALTER TABLE offer_counters DROP COLUMN organization_id;
