\set ON_ERROR_STOP on
\set eg_version '''FF-12.1'''
    
BEGIN;
      
ALTER TABLE action.copy_block_hold ADD COLUMN block_stop TIMESTAMPTZ;

COMMIT;

