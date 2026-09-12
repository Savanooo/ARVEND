ALTER TABLE offers DROP CONSTRAINT offers_organization_id_offer_no_key;
ALTER TABLE offers ADD CONSTRAINT offers_offer_no_key UNIQUE (offer_no);
