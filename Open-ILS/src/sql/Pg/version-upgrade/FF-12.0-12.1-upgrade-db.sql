\set ON_ERROR_STOP on
\set eg_version '''FF-12.1'''
    
BEGIN;
      
ALTER TABLE action.copy_block_hold ADD COLUMN block_stop TIMESTAMPTZ;

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype )
SELECT  'ff.ill.default_block_length',
        'holds',
        'Default number of days to globally disallow requests from targeting a specific item',
        'Valid values: 1, 3, 7, 14, 30, 365',
        'integer'
  WHERE NOT EXISTS (SELECT 1 FROM config.org_unit_setting_type WHERE name = 'ff.ill.default_block_length');


COMMIT;

