ALTER TABLE organizations DROP COLUMN onboarding_step;
ALTER TABLE organizations DROP COLUMN onboarding_completed_at;
ALTER TABLE organizations DROP COLUMN onboarding_completed;
ALTER TABLE organizations DROP COLUMN trial_ends_at;
ALTER TABLE organizations DROP COLUMN status;

ALTER TABLE users DROP COLUMN must_change_password;

ALTER TABLE users DROP CONSTRAINT users_super_admin_has_no_org;

ALTER TABLE users DROP CONSTRAINT users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
    CHECK (role IN ('admin', 'kullanici'));

ALTER TABLE users ALTER COLUMN organization_id SET NOT NULL;
