-- sql/migrations/010_officer_options.sql · each character's officer options (My options, CP.Options).
-- JSON of only the options that differ from the default; NULL = every option at its default.
ALTER TABLE cp_officers ADD COLUMN options JSON NULL;
