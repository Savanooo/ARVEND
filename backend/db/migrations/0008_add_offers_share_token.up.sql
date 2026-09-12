ALTER TABLE offers ADD COLUMN share_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE;
