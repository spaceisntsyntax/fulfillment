/*
 * Copyright (C) 2004-2008  Georgia Public Library Service
 * Copyright (C) 2008  Equinox Software, Inc.
 * Mike Rylander <miker@esilibrary.com> 
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

DROP SCHEMA IF EXISTS biblio CASCADE;

BEGIN;
CREATE SCHEMA biblio;

CREATE SEQUENCE biblio.autogen_tcn_value_seq;
CREATE OR REPLACE FUNCTION biblio.next_autogen_tcn_value () RETURNS TEXT AS $$
	BEGIN RETURN 'AUTOGENERATED-' || nextval('biblio.autogen_tcn_value_seq'::TEXT); END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION biblio.check_marcxml_well_formed () RETURNS TRIGGER AS $func$
BEGIN

    IF xml_is_well_formed(NEW.marc) THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Attempted to % MARCXML that is not well formed', TG_OP;
    END IF;
    
END;
$func$ LANGUAGE PLPGSQL;

CREATE TABLE biblio.record_entry (
	id		BIGSERIAL	PRIMARY KEY,
	creator		INT		NOT NULL DEFAULT 1,
	editor		INT		NOT NULL DEFAULT 1,
	source		INT,
	quality		INT,
	create_date	TIMESTAMP WITH TIME ZONE	NOT NULL DEFAULT now(),
	edit_date	TIMESTAMP WITH TIME ZONE	NOT NULL DEFAULT now(),
	active		BOOL		NOT NULL DEFAULT TRUE,
	deleted		BOOL		NOT NULL DEFAULT FALSE,
	fingerprint	TEXT,
	tcn_source	TEXT		NOT NULL DEFAULT 'AUTOGEN',
	tcn_value	TEXT		NOT NULL DEFAULT biblio.next_autogen_tcn_value(),
	marc		TEXT		NOT NULL,
	last_xact_id	TEXT		NOT NULL,
    vis_attr_vector INT[],
    owner       INT,
    share_depth INT,
    merge_date  TIMESTAMP WITH TIME ZONE,
    merged_to   BIGINT REFERENCES biblio.record_entry(id),
    remote_id   TEXT
);
INSERT INTO biblio.record_entry VALUES (-1,1,1,1,-1,NOW(),NOW(),FALSE,FALSE,'','AUTOGEN','-1','<record xmlns="http://www.loc.gov/MARC21/slim"/>','FOO');

CREATE INDEX biblio_record_entry_creator_idx ON biblio.record_entry ( creator );
CREATE INDEX biblio_record_entry_create_date_idx ON biblio.record_entry ( create_date );
CREATE INDEX biblio_record_entry_editor_idx ON biblio.record_entry ( editor );
CREATE INDEX biblio_record_entry_edit_date_idx ON biblio.record_entry ( edit_date );
CREATE INDEX biblio_record_entry_fp_idx ON biblio.record_entry ( fingerprint );
CREATE INDEX biblio_record_entry_remote_id_owner_idx ON biblio.record_entry (remote_id, owner);
CREATE UNIQUE INDEX biblio_record_unique_tcn ON biblio.record_entry (tcn_value) WHERE deleted = FALSE OR deleted IS FALSE;
CREATE TRIGGER a_marcxml_is_well_formed BEFORE INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE biblio.check_marcxml_well_formed();
CREATE TRIGGER b_maintain_901 BEFORE INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE evergreen.maintain_901();
CREATE TRIGGER c_maintain_control_numbers BEFORE INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE evergreen.maintain_control_numbers();

CREATE TABLE biblio.record_note (
	id		BIGSERIAL	PRIMARY KEY,
	record		BIGINT		NOT NULL,
	value		TEXT		NOT NULL,
	creator		INT		NOT NULL DEFAULT 1,
	editor		INT		NOT NULL DEFAULT 1,
	pub		BOOL		NOT NULL DEFAULT FALSE,
	create_date	TIMESTAMP WITH TIME ZONE	NOT NULL DEFAULT now(),
	edit_date	TIMESTAMP WITH TIME ZONE	NOT NULL DEFAULT now()
);
CREATE INDEX biblio_record_note_record_idx ON biblio.record_note ( record );
CREATE INDEX biblio_record_note_creator_idx ON biblio.record_note ( creator );
CREATE INDEX biblio_record_note_editor_idx ON biblio.record_note ( editor );

CREATE TABLE biblio.peer_type (
    id      SERIAL  PRIMARY KEY,
    name        TEXT        NOT NULL UNIQUE -- i18n
);

CREATE TABLE biblio.peer_bib_copy_map (
    id      SERIAL  PRIMARY KEY,
    peer_type   INT     NOT NULL REFERENCES biblio.peer_type (id),
    peer_record BIGINT      NOT NULL REFERENCES biblio.record_entry (id),
    target_copy BIGINT      NOT NULL -- can't use fkey because of acp subtables
);
CREATE INDEX peer_bib_copy_map_record_idx ON biblio.peer_bib_copy_map (peer_record);
CREATE INDEX peer_bib_copy_map_copy_idx ON biblio.peer_bib_copy_map (target_copy);

CREATE TABLE biblio.monograph_part (
    id              SERIAL  PRIMARY KEY,
    record          BIGINT  NOT NULL REFERENCES biblio.record_entry (id),
    label           TEXT    NOT NULL,
    label_sortkey   TEXT    NOT NULL,
    deleted         BOOL    NOT NULL DEFAULT FALSE
);
CREATE UNIQUE INDEX record_label_unique_idx ON biblio.monograph_part (record, label) WHERE deleted = FALSE;

CREATE OR REPLACE FUNCTION biblio.normalize_biblio_monograph_part_sortkey () RETURNS TRIGGER AS $$
BEGIN
    NEW.label_sortkey := REGEXP_REPLACE(
        evergreen.lpad_number_substrings(
            naco_normalize(NEW.label),
            '0',
            10
        ),
        E'\\s+',
        '',
        'g'
    );
    RETURN NEW;
END;
$$ LANGUAGE PLPGSQL;

CREATE TRIGGER norm_sort_label BEFORE INSERT OR UPDATE ON biblio.monograph_part FOR EACH ROW EXECUTE PROCEDURE biblio.normalize_biblio_monograph_part_sortkey();

CREATE OR REPLACE FUNCTION biblio.fast_import (p_owner INT, p_marc TEXT) RETURNS BOOL AS $func$
DECLARE
    is_del          BOOL;
    rid_value       TEXT;
    existing_bib    biblio.record_entry%ROWTYPE;
BEGIN

    SELECT oils_xpath_string( REPLACE(BTRIM(value,'"'),E'\\"','"'), p_marc ) INTO rid_value
        FROM actor.org_unit_ancestor_setting( 'ff.remote.bib_refresh.lai_id_field', p_owner ) LIMIT 1;

    IF rid_value IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT SUBSTR( oils_xpath_string( '//*[local-name()="leader"]', p_marc ), 6, 1) = 'd' INTO is_del;

    SELECT * INTO existing_bib FROM biblio.record_entry WHERE remote_id = rid_value AND owner = p_owner;

    IF existing_bib.id IS NULL AND NOT is_del THEN
        -- RAISE NOTICE 'INSERTing for %', rid_value;
        INSERT INTO biblio.record_entry (marc, owner, remote_id, last_xact_id)
            VALUES (p_marc, p_owner, rid_value, EXTRACT(EPOCH FROM now()));
    ELSE
        IF NOT is_del THEN
            -- RAISE NOTICE 'UPDATEing for %', existing_bib.id;
            UPDATE  biblio.record_entry
              SET   marc = p_marc,
                    last_xact_id = EXTRACT(EPOCH FROM now()),
                    edit_date = now()
              WHERE id = existing_bib.id;
        ELSE
            DELETE FROM biblio.record_entry WHERE id = existing_bib.id;
        END IF;
    END IF;

    IF FOUND THEN
        RETURN TRUE;
    ELSE
        RETURN FALSE;
    END IF;

END;
$func$ LANGUAGE PLPGSQL;

CREATE TABLE biblio.bulk_loading_log (
    id              SERIAL
    ,filename       TEXT
    ,batch          TEXT
    ,hash           TEXT
    ,owning_lib     INTEGER
    ,asset_count    INTEGER
    ,event_date     TIMESTAMP DEFAULT NOW()
    ,event          TEXT
);

COMMIT;
