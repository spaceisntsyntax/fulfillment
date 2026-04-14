\set ON_ERROR_STOP on
\set eg_version '''FF-12.0'''

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1360', :eg_version); -- bshum / Dyrcona / JBoyer

-- replace functions from 300.schema.staged_search.sql

CREATE OR REPLACE FUNCTION asset.all_visible_flags () RETURNS TEXT AS $f$
    SELECT  '(' || STRING_AGG(search.calculate_visibility_attribute(1 << x, 'copy_flags')::TEXT,'&') || ')'
      FROM  GENERATE_SERIES(0,0) AS x; -- increment as new flags are added.
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.visible_orgs (otype TEXT) RETURNS TEXT AS $f$
    SELECT  '(' || STRING_AGG(search.calculate_visibility_attribute(id, $1)::TEXT,'|') || ')'
      FROM  actor.org_unit
      WHERE opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.invisible_orgs (otype TEXT) RETURNS TEXT AS $f$
    SELECT  '!(' || STRING_AGG(search.calculate_visibility_attribute(id, $1)::TEXT,'|') || ')'
      FROM  actor.org_unit
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.bib_source_default () RETURNS TEXT AS $f$
    SELECT  '(' || STRING_AGG(search.calculate_visibility_attribute(id, 'bib_source')::TEXT,'|') || ')'
      FROM  config.bib_source
      WHERE transcendant;
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION asset.location_group_default () RETURNS TEXT AS $f$
    SELECT '!()'::TEXT; -- For now, as there's no way to cause a location group to hide all copies.
/*
    SELECT  '!(' || STRING_AGG(search.calculate_visibility_attribute(id, 'location_group')::TEXT,'|') || ')'
      FROM  asset.copy_location_group
      WHERE NOT opac_visible;
*/
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION asset.location_default () RETURNS TEXT AS $f$
    SELECT  '!(' || STRING_AGG(search.calculate_visibility_attribute(id, 'location')::TEXT,'|') || ')'
      FROM  asset.copy_location
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.status_default () RETURNS TEXT AS $f$
    SELECT  '!(' || STRING_AGG(search.calculate_visibility_attribute(id, 'status')::TEXT,'|') || ')'
      FROM  config.copy_status
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

-- replace unapi.mmr from 990.schema.unapi.sql

CREATE OR REPLACE FUNCTION unapi.mmr (
    obj_id BIGINT,
    format TEXT,
    ename TEXT,
    includes TEXT[],
    org TEXT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    pref_lib INT DEFAULT NULL
)
RETURNS XML AS $F$
DECLARE
    mmrec   metabib.metarecord%ROWTYPE;
    leadrec biblio.record_entry%ROWTYPE;
    subrec biblio.record_entry%ROWTYPE;
    layout  unapi.bre_output_layout%ROWTYPE;
    xfrm    config.xml_transform%ROWTYPE;
    ouid    INT;
    xml_buf TEXT; -- growing XML document
    tmp_xml TEXT; -- single-use XML string
    xml_frag TEXT; -- single-use XML fragment
    top_el  TEXT;
    output  XML;
    hxml    XML;
    axml    XML;
    subxml  XML; -- subordinate records elements
    sub_xpath TEXT; 
    parts   TEXT[]; 
BEGIN

    -- xpath for extracting bre.marc values from subordinate records 
    -- so they may be appended to the MARC of the master record prior
    -- to XSLT processing.
    -- subjects, isbn, issn, upc -- anything else?
    sub_xpath := 
      '//*[starts-with(@tag, "6") or @tag="020" or @tag="022" or @tag="024"]';

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;

    IF ouid IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT INTO mmrec * FROM metabib.metarecord WHERE id = obj_id;
    IF NOT FOUND THEN
        RETURN NULL::XML;
    END IF;

    -- TODO: aggregate holdings from constituent records
    IF format = 'holdings_xml' THEN -- the special case
        output := unapi.mmr_holdings_xml(
            obj_id, ouid, org, depth,
            array_remove(includes,'holdings_xml'),
            slimit, soffset, include_xmlns, pref_lib);
        RETURN output;
    END IF;

    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO xfrm FROM config.xml_transform WHERE name = layout.transform;

    SELECT INTO leadrec * FROM biblio.record_entry WHERE id = mmrec.master_record;

    -- Grab distinct MVF for all records if requested
    IF ('mra' = ANY (includes)) THEN 
        axml := unapi.mmr_mra(obj_id,NULL,NULL,NULL,org,depth,NULL,NULL,TRUE,pref_lib);
    ELSE
        axml := NULL::XML;
    END IF;

    xml_buf = leadrec.marc;

    hxml := NULL::XML;
    IF ('holdings_xml' = ANY (includes)) THEN
        hxml := unapi.mmr_holdings_xml(
                    obj_id, ouid, org, depth,
                    array_remove(includes,'holdings_xml'),
                    slimit, soffset, include_xmlns, pref_lib);
    END IF;

    subxml := NULL::XML;
    parts := '{}'::TEXT[];
    FOR subrec IN SELECT bre.* FROM biblio.record_entry bre
         JOIN metabib.metarecord_source_map mmsm ON (mmsm.source = bre.id)
         JOIN metabib.metarecord mmr ON (mmr.id = mmsm.metarecord)
         WHERE mmr.id = obj_id AND NOT bre.deleted
         ORDER BY CASE WHEN bre.id = mmr.master_record THEN 0 ELSE bre.id END
         LIMIT COALESCE((slimit->'bre')::INT, 5) LOOP

        IF subrec.id = leadrec.id THEN CONTINUE; END IF;
        -- Append choice data from the the non-lead records to the 
        -- the lead record document

        parts := parts || xpath(sub_xpath, subrec.marc::XML)::TEXT[];
    END LOOP;

    SELECT STRING_AGG( DISTINCT p , '' )::XML INTO subxml FROM UNNEST(parts) p;

    -- append data from the subordinate records to the 
    -- main record document before applying the XSLT

    IF subxml IS NOT NULL THEN 
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</record>(.*?)$', subxml || '</record>' || E'\\1');
    END IF;

    IF format = 'marcxml' THEN
         -- If we're not using the prefixed namespace in 
         -- this record, then remove all declarations of it
        IF xml_buf !~ E'<marc:' THEN
           xml_buf := REGEXP_REPLACE(xml_buf, 
            ' xmlns:marc="http://www.loc.gov/MARC21/slim"', '', 'g');
        END IF; 
    ELSE
        xml_buf := oils_xslt_process(xml_buf, xfrm.xslt)::XML;
    END IF;

    -- update top_el to reflect the change in xml_buf, which may
    -- now be a different type of document (e.g. record -> mods)
    top_el := REGEXP_REPLACE(xml_buf, E'^.*?<((?:\\S+:)?' || 
        layout.holdings_element || ').*$', E'\\1');

    IF axml IS NOT NULL THEN 
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</' || top_el || '>(.*?)$', axml || '</' || top_el || E'>\\1');
    END IF;

    IF hxml IS NOT NULL THEN
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</' || top_el || '>(.*?)$', hxml || '</' || top_el || E'>\\1');
    END IF;

    IF ('mmr.unapi' = ANY (includes)) THEN 
        output := REGEXP_REPLACE(
            xml_buf,
            '</' || top_el || '>(.*?)',
            XMLELEMENT(
                name abbr,
                XMLATTRIBUTES(
                    'http://www.w3.org/1999/xhtml' AS xmlns,
                    'unapi-id' AS class,
                    'tag:open-ils.org:U2@mmr/' || obj_id || '/' || org AS title
                )
            )::TEXT || '</' || top_el || E'>\\1'
        );
    ELSE
        output := xml_buf;
    END IF;

    -- remove ignorable whitesace
    output := REGEXP_REPLACE(output::TEXT,E'>\\s+<','><','gs')::XML;
    RETURN output;
END;
$F$ LANGUAGE PLPGSQL STABLE;

CREATE OR REPLACE FUNCTION actor.usr_merge( src_usr INT, dest_usr INT, del_addrs BOOLEAN, del_cards BOOLEAN, deactivate_cards BOOLEAN ) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	bucket_row RECORD;
	picklist_row RECORD;
	queue_row RECORD;
	folder_row RECORD;
BEGIN

    -- Bail if src_usr equals dest_usr because the result of merging a
    -- user with itself is not what you want.
    IF src_usr = dest_usr THEN
        RETURN;
    END IF;

    -- do some initial cleanup 
    UPDATE actor.usr SET card = NULL WHERE id = src_usr;
    UPDATE actor.usr SET mailing_address = NULL WHERE id = src_usr;
    UPDATE actor.usr SET billing_address = NULL WHERE id = src_usr;

    -- actor.*
    IF del_cards THEN
        DELETE FROM actor.card where usr = src_usr;
    ELSE
        IF deactivate_cards THEN
            UPDATE actor.card SET active = 'f' WHERE usr = src_usr;
        END IF;
        UPDATE actor.card SET usr = dest_usr WHERE usr = src_usr;
    END IF;


    IF del_addrs THEN
        DELETE FROM actor.usr_address WHERE usr = src_usr;
    ELSE
        UPDATE actor.usr_address SET usr = dest_usr WHERE usr = src_usr;
    END IF;

    UPDATE actor.usr_message SET usr = dest_usr WHERE usr = src_usr;
    -- dupes are technically OK in actor.usr_standing_penalty, should manually delete them...
    UPDATE actor.usr_standing_penalty SET usr = dest_usr WHERE usr = src_usr;
    PERFORM actor.usr_merge_rows('actor.usr_org_unit_opt_in', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('actor.usr_setting', 'usr', src_usr, dest_usr);

    -- permission.*
    PERFORM actor.usr_merge_rows('permission.usr_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_object_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_grp_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_work_ou_map', 'usr', src_usr, dest_usr);


    -- container.*
	
	-- For each *_bucket table: transfer every bucket belonging to src_usr
	-- into the custody of dest_usr.
	--
	-- In order to avoid colliding with an existing bucket owned by
	-- the destination user, append the source user's id (in parenthesese)
	-- to the name.  If you still get a collision, add successive
	-- spaces to the name and keep trying until you succeed.
	--
	FOR bucket_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE container.user_bucket_item SET target_user = dest_usr WHERE target_user = src_usr;

    -- vandelay.*
	-- transfer queues the same way we transfer buckets (see above)
	FOR queue_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = queue_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- money.*
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'collector', src_usr, dest_usr);
    UPDATE money.billable_xact SET usr = dest_usr WHERE usr = src_usr;
    UPDATE money.billing SET voider = dest_usr WHERE voider = src_usr;
    UPDATE money.bnm_payment SET accepting_usr = dest_usr WHERE accepting_usr = src_usr;

    -- action.*
    UPDATE action.circulation SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
    UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
    UPDATE action.usr_circ_history SET usr = dest_usr WHERE usr = src_usr;

    UPDATE action.hold_request SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
    UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
    UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;

    UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET patron = dest_usr WHERE patron = src_usr;
    UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.survey_response SET usr = dest_usr WHERE usr = src_usr;

    -- acq.*
    UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.fund_transfer SET transfer_user = dest_usr WHERE transfer_user = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;

	-- transfer picklists the same way we transfer buckets (see above)
	FOR picklist_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = picklist_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
    UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.provider_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.provider_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_usr_attr_definition SET usr = dest_usr WHERE usr = src_usr;

    -- asset.*
    UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;

    -- serial.*
    UPDATE serial.record_entry SET creator = dest_usr WHERE creator = src_usr;
    UPDATE serial.record_entry SET editor = dest_usr WHERE editor = src_usr;

    -- reporter.*
    -- It's not uncommon to define the reporter schema in a replica 
    -- DB only, so don't assume these tables exist in the write DB.
    BEGIN
    	UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;

    -- propagate preferred name values from the source user to the
    -- destination user, but only when values are not being replaced.
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr)
    UPDATE actor.usr SET 
        pref_prefix = 
            COALESCE(pref_prefix, (SELECT pref_prefix FROM susr)),
        pref_first_given_name = 
            COALESCE(pref_first_given_name, (SELECT pref_first_given_name FROM susr)),
        pref_second_given_name = 
            COALESCE(pref_second_given_name, (SELECT pref_second_given_name FROM susr)),
        pref_family_name = 
            COALESCE(pref_family_name, (SELECT pref_family_name FROM susr)),
        pref_suffix = 
            COALESCE(pref_suffix, (SELECT pref_suffix FROM susr))
    WHERE id = dest_usr;

    -- Copy and deduplicate name keywords
    -- String -> array -> rows -> DISTINCT -> array -> string
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr),
         dusr AS (SELECT * FROM actor.usr WHERE id = dest_usr)
    UPDATE actor.usr SET name_keywords = (
        WITH keywords AS (
            SELECT DISTINCT UNNEST(
                REGEXP_SPLIT_TO_ARRAY(
                    COALESCE((SELECT name_keywords FROM susr), '') || ' ' ||
                    COALESCE((SELECT name_keywords FROM dusr), ''),  E'\\s+'
                )
            ) AS parts
        ) SELECT STRING_AGG(kw.parts, ' ') FROM keywords kw
    ) WHERE id = dest_usr;

    -- Finally, delete the source user
    PERFORM actor.usr_delete(src_usr,dest_usr);

END;
$$ LANGUAGE plpgsql;

COMMIT;

BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1361', :eg_version);

INSERT INTO config.global_flag (name, value, enabled, label)
VALUES (
    'opac.max_concurrent_search.query',
    '20',
    TRUE,
    oils_i18n_gettext(
        'opac.max_concurrent_search.query',
        'Limit the number of global concurrent matching search queries',
        'cgf', 'label'
    )
);

INSERT INTO config.global_flag (name, value, enabled, label)
VALUES (
    'opac.max_concurrent_search.ip',
    '0',
    TRUE,
    oils_i18n_gettext(
        'opac.max_concurrent_search.ip',
        'Limit the number of global concurrent searches per client IP address',
        'cgf', 'label'
    )
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1362', :eg_version);

CREATE INDEX hold_request_hopeless_date_idx ON action.hold_request (hopeless_date);

COMMIT;

ANALYZE action.hold_request;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1363', :eg_version);

ALTER TABLE action.hold_request_cancel_cause
  ADD COLUMN manual BOOL NOT NULL DEFAULT FALSE;

UPDATE action.hold_request_cancel_cause SET manual = TRUE
  WHERE id IN (
    2, -- Hold Shelf expiration
    3, -- Patron via phone
    4, -- Patron in person
    5  -- Staff forced
  );

INSERT INTO action.hold_request_cancel_cause (id, label, manual)
  VALUES (9, oils_i18n_gettext(9, 'Patron via email', 'ahrcc', 'label'), TRUE);

INSERT INTO action.hold_request_cancel_cause (id, label, manual)
  VALUES (10, oils_i18n_gettext(10, 'Patron via SMS', 'ahrcc', 'label'), TRUE);

COMMIT;
BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1364', :eg_version);

-- 950.data.seed-values.sql

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 642, 'UPDATE_COPY_BARCODE', oils_i18n_gettext(642,
    'Update the barcode for an item.', 'ppl', 'description'))
;

-- give this perm to perm groups that already have UPDATE_COPY
WITH perms_to_add AS
    (SELECT id FROM
    permission.perm_list
    WHERE code IN ('UPDATE_COPY_BARCODE'))
INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
    SELECT grp, perms_to_add.id as perm, depth, grantable
        FROM perms_to_add,
        permission.grp_perm_map

        --- Don't add the permissions if they have already been assigned
        WHERE grp NOT IN
            (SELECT DISTINCT grp FROM permission.grp_perm_map
            INNER JOIN perms_to_add ON perm=perms_to_add.id)

        --- we're going to match the depth of their existing perm
        AND perm = (
            SELECT id
                FROM permission.perm_list
                WHERE code = 'UPDATE_COPY'
        );

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1365', :eg_version);

CREATE OR REPLACE FUNCTION search.highlight_display_fields_impl(
    rid         BIGINT,
    tsq         TEXT,
    field_list  INT[] DEFAULT '{}'::INT[],
    css_class   TEXT DEFAULT 'oils_SH',
    hl_all      BOOL DEFAULT TRUE,
    minwords    INT DEFAULT 5,
    maxwords    INT DEFAULT 25,
    shortwords  INT DEFAULT 0,
    maxfrags    INT DEFAULT 0,
    delimiter   TEXT DEFAULT ' ... '
) RETURNS SETOF search.highlight_result AS $f$
DECLARE
    opts            TEXT := '';
    v_css_class     TEXT := css_class;
    v_delimiter     TEXT := delimiter;
    v_field_list    INT[] := field_list;
    hl_query        TEXT;
BEGIN
    IF v_delimiter LIKE $$%'%$$ OR v_delimiter LIKE '%"%' THEN --"
        v_delimiter := ' ... ';
    END IF;

    IF NOT hl_all THEN
        opts := opts || 'MinWords=' || minwords;
        opts := opts || ', MaxWords=' || maxwords;
        opts := opts || ', ShortWords=' || shortwords;
        opts := opts || ', MaxFragments=' || maxfrags;
        opts := opts || ', FragmentDelimiter="' || delimiter || '"';
    ELSE
        opts := opts || 'HighlightAll=TRUE';
    END IF;

    IF v_css_class LIKE $$%'%$$ OR v_css_class LIKE '%"%' THEN -- "
        v_css_class := 'oils_SH';
    END IF;

    opts := opts || $$, StopSel=</mark>, StartSel="<mark class='$$ || v_css_class; -- "

    IF v_field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO v_field_list FROM config.metabib_field WHERE display_field;
    END IF;

    hl_query := $$
        SELECT  de.id,
                de.source,
                de.field,
                evergreen.escape_for_html(de.value) AS value,
                ts_headline(
                    ts_config::REGCONFIG,
                    evergreen.escape_for_html(de.value),
                    $$ || quote_literal(tsq) || $$,
                    $1 || ' ' || mf.field_class || ' ' || mf.name || $xx$'>"$xx$ -- "'
                ) AS highlight
          FROM  metabib.display_entry de
                JOIN config.metabib_field mf ON (mf.id = de.field)
                JOIN search.best_tsconfig t ON (t.id = de.field)
          WHERE de.source = $2
                AND field = ANY ($3)
          ORDER BY de.id;$$;

    RETURN QUERY EXECUTE hl_query USING opts, rid, v_field_list;
END;
$f$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1366', :eg_version);

ALTER TABLE config.metabib_class
    ADD COLUMN IF NOT EXISTS variant_authority_suggestion   BOOL NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS symspell_transfer_case         BOOL NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS symspell_skip_correct          BOOL NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS symspell_suggestion_verbosity  INT NOT NULL DEFAULT 2,
    ADD COLUMN IF NOT EXISTS max_phrase_edit_distance       INT NOT NULL DEFAULT 2,
    ADD COLUMN IF NOT EXISTS suggestion_word_option_count   INT NOT NULL DEFAULT 5,
    ADD COLUMN IF NOT EXISTS max_suggestions                INT NOT NULL DEFAULT -1,
    ADD COLUMN IF NOT EXISTS low_result_threshold           INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS min_suggestion_use_threshold   INT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS soundex_weight                 INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS pg_trgm_weight                 INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS keyboard_distance_weight       INT NOT NULL DEFAULT 0;


/* -- may not need these 2 functions
CREATE OR REPLACE FUNCTION search.symspell_parse_positive_words ( phrase TEXT )
RETURNS SETOF TEXT AS $F$
    SELECT  UNNEST
      FROM  (SELECT UNNEST(x), ROW_NUMBER() OVER ()
              FROM  regexp_matches($1, '(?<!-)\+?([[:alnum:]]+''*[[:alnum:]]*)', 'g') x
            ) y
      WHERE UNNEST IS NOT NULL
      ORDER BY row_number
$F$ LANGUAGE SQL STRICT IMMUTABLE;

CREATE OR REPLACE FUNCTION search.symspell_parse_positive_phrases ( phrase TEXT )
RETURNS SETOF TEXT AS $F$
    SELECT  BTRIM(BTRIM(UNNEST),'"')
      FROM  (SELECT UNNEST(x), ROW_NUMBER() OVER ()
              FROM  regexp_matches($1, '(?:^|\s+)(?:(-?"[^"]+")|(-?\+?[[:alnum:]]+''*?[[:alnum:]]*?))', 'g') x
            ) y
      WHERE UNNEST IS NOT NULL AND UNNEST NOT LIKE '-%'
      ORDER BY row_number
$F$ LANGUAGE SQL STRICT IMMUTABLE;
*/

CREATE OR REPLACE FUNCTION search.symspell_parse_words ( phrase TEXT )
RETURNS SETOF TEXT AS $F$
    SELECT  UNNEST
      FROM  (SELECT UNNEST(x), ROW_NUMBER() OVER ()
              FROM  regexp_matches($1, '(?:^|\s+)((?:-|\+)?[[:alnum:]]+''*[[:alnum:]]*)', 'g') x
            ) y
      WHERE UNNEST IS NOT NULL
      ORDER BY row_number
$F$ LANGUAGE SQL STRICT IMMUTABLE;

CREATE OR REPLACE FUNCTION search.distribute_phrase_sign (input TEXT) RETURNS TEXT AS $f$
DECLARE
    phrase_sign TEXT;
    output      TEXT;
BEGIN
    output := input;

    IF output ~ '^(?:-|\+)' THEN
        phrase_sign := SUBSTRING(input FROM 1 FOR 1);
        output := SUBSTRING(output FROM 2);
    END IF;

    IF output LIKE '"%"' THEN
        IF phrase_sign IS NULL THEN
            phrase_sign := '+';
        END IF;
        output := BTRIM(output,'"');
    END IF;

    IF phrase_sign IS NOT NULL THEN
        RETURN REGEXP_REPLACE(output,'(^|\s+)(?=[[:alnum:]])','\1'||phrase_sign,'g');
    END IF;

    RETURN output;
END;
$f$ LANGUAGE PLPGSQL STRICT IMMUTABLE;

CREATE OR REPLACE FUNCTION search.query_parse_phrases ( phrase TEXT )
RETURNS SETOF TEXT AS $F$
    SELECT  search.distribute_phrase_sign(UNNEST)
      FROM  (SELECT UNNEST(x), ROW_NUMBER() OVER ()
              FROM  regexp_matches($1, '(?:^|\s+)(?:((?:-|\+)?"[^"]+")|((?:-|\+)?[[:alnum:]]+''*[[:alnum:]]*))', 'g') x
            ) y
      WHERE UNNEST IS NOT NULL
      ORDER BY row_number
$F$ LANGUAGE SQL STRICT IMMUTABLE;

CREATE TYPE search.query_parse_position AS (
    word                TEXT,
    word_pos            INT,
    phrase_in_input_pos INT,
    word_in_phrase_pos  INT,
    negated             BOOL,
    exact               BOOL
);

CREATE OR REPLACE FUNCTION search.query_parse_positions ( raw_input TEXT )
RETURNS SETOF search.query_parse_position AS $F$
DECLARE
    curr_phrase TEXT;
    curr_word   TEXT;
    phrase_pos  INT := 0;
    word_pos    INT := 0;
    pos         INT := 0;
    neg         BOOL;
    ex          BOOL;
BEGIN
    FOR curr_phrase IN SELECT x FROM search.query_parse_phrases(raw_input) x LOOP
        word_pos := 0;
        FOR curr_word IN SELECT x FROM search.symspell_parse_words(curr_phrase) x LOOP
            neg := FALSE;
            ex := FALSE;
            IF curr_word ~ '^(?:-|\+)' THEN
                ex := TRUE;
                IF curr_word LIKE '-%' THEN
                    neg := TRUE;
                END IF;
                curr_word := SUBSTRING(curr_word FROM 2);
            END IF;
            RETURN QUERY SELECT curr_word, pos, phrase_pos, word_pos, neg, ex;
            word_pos := word_pos + 1;
            pos := pos + 1;
        END LOOP;
        phrase_pos := phrase_pos + 1;
    END LOOP;
    RETURN;
END;
$F$ LANGUAGE PLPGSQL STRICT IMMUTABLE;

/*
select  suggestion as sugg,
        suggestion_count as scount,
        input,
        norm_input,
        prefix_key_count as ncount,
        lev_distance,
        soundex_sim,
        pg_trgm_sim,
        qwerty_kb_match
  from  search.symspell_suggest(
            'Cedenzas (2) for Mosart''s Piano concerto',
            'title',
            '{}',
            2,2,false,5
        )
  where lev_distance is not null
  order by lev_distance,
           suggestion_count desc,
           soundex_sim desc,
           pg_trgm_sim desc,
           qwerty_kb_match desc
;

select * from search.symspell_suggest('piano concerto -jaz','subject','{}',2,2,false,4) order by lev_distance, soundex_sim desc, pg_trgm_sim desc, qwerty_kb_match desc;

*/
CREATE OR REPLACE FUNCTION search.symspell_suggest (
    raw_input       TEXT,
    search_class    TEXT,
    search_fields   TEXT[] DEFAULT '{}',
    max_ed          INT DEFAULT NULL,      -- per word, on average, between norm input and suggestion
    verbosity       INT DEFAULT NULL,      -- 0=Best only; 1=
    skip_correct    BOOL DEFAULT NULL,  -- only suggest replacement words for misspellings?
    max_word_opts   INT DEFAULT NULL,   -- 0 means all combinations, probably want to restrict?
    count_threshold INT DEFAULT NULL    -- min count of records using the terms
) RETURNS SETOF search.symspell_lookup_output AS $F$
DECLARE
    sugg_set         search.symspell_lookup_output[];
    parsed_query_set search.query_parse_position[];
    entry            RECORD;
    auth_entry       RECORD;
    norm_count       RECORD;
    current_sugg     RECORD;
    auth_sugg        RECORD;
    norm_test        TEXT;
    norm_input       TEXT;
    norm_sugg        TEXT;
    query_part       TEXT := '';
    output           search.symspell_lookup_output;
    c_skip_correct                  BOOL;
    c_variant_authority_suggestion  BOOL;
    c_symspell_transfer_case        BOOL;
    c_authority_class_restrict      BOOL;
    c_min_suggestion_use_threshold  INT;
    c_soundex_weight                INT;
    c_pg_trgm_weight                INT;
    c_keyboard_distance_weight      INT;
    c_suggestion_word_option_count  INT;
    c_symspell_suggestion_verbosity INT;
    c_max_phrase_edit_distance      INT;
BEGIN

    -- Gather settings
    SELECT  cmc.min_suggestion_use_threshold,
            cmc.soundex_weight,
            cmc.pg_trgm_weight,
            cmc.keyboard_distance_weight,
            cmc.suggestion_word_option_count,
            cmc.symspell_suggestion_verbosity,
            cmc.symspell_skip_correct,
            cmc.symspell_transfer_case,
            cmc.max_phrase_edit_distance,
            cmc.variant_authority_suggestion,
            cmc.restrict
      INTO  c_min_suggestion_use_threshold,
            c_soundex_weight,
            c_pg_trgm_weight,
            c_keyboard_distance_weight,
            c_suggestion_word_option_count,
            c_symspell_suggestion_verbosity,
            c_skip_correct,
            c_symspell_transfer_case,
            c_max_phrase_edit_distance,
            c_variant_authority_suggestion,
            c_authority_class_restrict
      FROM  config.metabib_class cmc
      WHERE cmc.name = search_class;


    -- Set up variables to use at run time based on params and settings
    c_min_suggestion_use_threshold := COALESCE(count_threshold,c_min_suggestion_use_threshold);
    c_max_phrase_edit_distance := COALESCE(max_ed,c_max_phrase_edit_distance);
    c_symspell_suggestion_verbosity := COALESCE(verbosity,c_symspell_suggestion_verbosity);
    c_suggestion_word_option_count := COALESCE(max_word_opts,c_suggestion_word_option_count);
    c_skip_correct := COALESCE(skip_correct,c_skip_correct);

    SELECT  ARRAY_AGG(
                x ORDER BY  x.word_pos,
                            x.lev_distance,
                            (x.soundex_sim * c_soundex_weight)
                                + (x.pg_trgm_sim * c_pg_trgm_weight)
                                + (x.qwerty_kb_match * c_keyboard_distance_weight) DESC,
                            x.suggestion_count DESC
            ) INTO sugg_set
      FROM  search.symspell_lookup(
                raw_input,
                search_class,
                c_symspell_suggestion_verbosity,
                c_symspell_transfer_case,
                c_min_suggestion_use_threshold,
                c_soundex_weight,
                c_pg_trgm_weight,
                c_keyboard_distance_weight
            ) x
      WHERE x.lev_distance <= c_max_phrase_edit_distance;

    SELECT ARRAY_AGG(x) INTO parsed_query_set FROM search.query_parse_positions(raw_input) x;

    IF search_fields IS NOT NULL AND CARDINALITY(search_fields) > 0 THEN
        SELECT STRING_AGG(id::TEXT,',') INTO query_part FROM config.metabib_field WHERE name = ANY (search_fields);
        IF CHARACTER_LENGTH(query_part) > 0 THEN query_part := 'AND field IN ('||query_part||')'; END IF;
    END IF;

    SELECT STRING_AGG(word,' ') INTO norm_input FROM search.query_parse_positions(evergreen.lowercase(raw_input)) WHERE NOT negated;
    EXECUTE 'SELECT  COUNT(DISTINCT source) AS recs
               FROM  metabib.' || search_class || '_field_entry
               WHERE index_vector @@ plainto_tsquery($$simple$$,$1)' || query_part
            INTO norm_count USING norm_input;

    SELECT STRING_AGG(word,' ') INTO norm_test FROM UNNEST(parsed_query_set);
    FOR current_sugg IN
        SELECT  *
          FROM  search.symspell_generate_combined_suggestions(
                    sugg_set,
                    parsed_query_set,
                    c_skip_correct,
                    c_suggestion_word_option_count
                ) x
    LOOP
        EXECUTE 'SELECT  COUNT(DISTINCT source) AS recs
                   FROM  metabib.' || search_class || '_field_entry
                   WHERE index_vector @@ to_tsquery($$simple$$,$1)' || query_part
                INTO entry USING current_sugg.test;
        SELECT STRING_AGG(word,' ') INTO norm_sugg FROM search.query_parse_positions(current_sugg.suggestion);
        IF entry.recs >= c_min_suggestion_use_threshold AND (norm_count.recs = 0 OR norm_sugg <> norm_input) THEN

            output.input := raw_input;
            output.norm_input := norm_input;
            output.suggestion := current_sugg.suggestion;
            output.suggestion_count := entry.recs;
            output.prefix_key := NULL;
            output.prefix_key_count := norm_count.recs;

            output.lev_distance := NULLIF(evergreen.levenshtein_damerau_edistance(norm_test, norm_sugg, c_max_phrase_edit_distance * CARDINALITY(parsed_query_set)), -1);
            output.qwerty_kb_match := evergreen.qwerty_keyboard_distance_match(norm_test, norm_sugg);
            output.pg_trgm_sim := similarity(norm_input, norm_sugg);
            output.soundex_sim := difference(norm_input, norm_sugg) / 4.0;

            RETURN NEXT output;
        END IF;

        IF c_variant_authority_suggestion THEN
            FOR auth_sugg IN
                SELECT  DISTINCT m.value AS prefix_key,
                        m.sort_value AS suggestion,
                        v.value as raw_input,
                        v.sort_value as norm_input
                  FROM  authority.simple_heading v
                        JOIN authority.control_set_authority_field csaf ON (csaf.id = v.atag)
                        JOIN authority.heading_field f ON (f.id = csaf.heading_field)
                        JOIN authority.simple_heading m ON (m.record = v.record AND csaf.main_entry = m.atag)
                        JOIN authority.control_set_bib_field csbf ON (csbf.authority_field = csaf.main_entry)
                        JOIN authority.control_set_bib_field_metabib_field_map csbfmfm ON (csbf.id = csbfmfm.bib_field)
                        JOIN config.metabib_field cmf ON (
                                csbfmfm.metabib_field = cmf.id
                                AND (c_authority_class_restrict IS FALSE OR cmf.field_class = search_class)
                                AND (search_fields = '{}'::TEXT[] OR cmf.name = ANY (search_fields))
                        )
                  WHERE v.sort_value = norm_sugg
            LOOP
                EXECUTE 'SELECT  COUNT(DISTINCT source) AS recs
                           FROM  metabib.' || search_class || '_field_entry
                           WHERE index_vector @@ plainto_tsquery($$simple$$,$1)' || query_part
                        INTO auth_entry USING auth_sugg.suggestion;
                IF auth_entry.recs >= c_min_suggestion_use_threshold AND (norm_count.recs = 0 OR auth_sugg.suggestion <> norm_input) THEN
                    output.input := auth_sugg.raw_input;
                    output.norm_input := auth_sugg.norm_input;
                    output.suggestion := auth_sugg.suggestion;
                    output.prefix_key := auth_sugg.prefix_key;
                    output.suggestion_count := auth_entry.recs * -1; -- negative value here 

                    output.lev_distance := 0;
                    output.qwerty_kb_match := 0;
                    output.pg_trgm_sim := 0;
                    output.soundex_sim := 0;

                    RETURN NEXT output;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    RETURN;
END;
$F$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION search.symspell_generate_combined_suggestions(
    word_data search.symspell_lookup_output[],
    pos_data search.query_parse_position[],
    skip_correct BOOL DEFAULT TRUE,
    max_words INT DEFAULT 0
) RETURNS TABLE (suggestion TEXT, test TEXT) AS $f$
    my $word_data = shift;
    my $pos_data = shift;
    my $skip_correct = shift;
    my $max_per_word = shift;
    return undef unless (@$word_data and @$pos_data);

    my $last_word_pos = $$word_data[-1]{word_pos};
    my $pos_to_word_map = [ map { [] } 0 .. $last_word_pos ];
    my $parsed_query_data = { map { ($$_{word_pos} => $_) } @$pos_data };

    for my $row (@$word_data) {
        my $wp = +$$row{word_pos};
        next if (
            $skip_correct eq 't' and $$row{lev_distance} > 0
            and @{$$pos_to_word_map[$wp]}
            and $$pos_to_word_map[$wp][0]{lev_distance} == 0
        );
        push @{$$pos_to_word_map[$$row{word_pos}]}, $row;
    }

    gen_step($max_per_word, $pos_to_word_map, $parsed_query_data, $last_word_pos);
    return undef;

    # -----------------------------
    sub gen_step {
        my $max_words = shift;
        my $data = shift;
        my $pos_data = shift;
        my $last_pos = shift;
        my $prefix = shift || '';
        my $test_prefix = shift || '';
        my $current_pos = shift || 0;

        my $word_count = 0;
        for my $sugg ( @{$$data[$current_pos]} ) {
            my $was_inside_phrase = 0;
            my $now_inside_phrase = 0;

            my $word = $$sugg{suggestion};
            $word_count++;

            my $prev_phrase = $$pos_data{$current_pos - 1}{phrase_in_input_pos};
            my $curr_phrase = $$pos_data{$current_pos}{phrase_in_input_pos};
            my $next_phrase = $$pos_data{$current_pos + 1}{phrase_in_input_pos};

            $now_inside_phrase++ if (defined($next_phrase) and $curr_phrase == $next_phrase);
            $was_inside_phrase++ if (defined($prev_phrase) and $curr_phrase == $prev_phrase);

            my $string = $prefix;
            $string .= ' ' if $string;

            if (!$was_inside_phrase) { # might be starting a phrase?
                $string .= '-' if ($$pos_data{$current_pos}{negated} eq 't');
                if ($now_inside_phrase) { # we are! add the double-quote
                    $string .= '"';
                }
                $string .= $word;
            } else { # definitely were in a phrase
                $string .= $word;
                if (!$now_inside_phrase) { # we are not any longer, add the double-quote
                    $string .= '"';
                }
            }

            my $test_string = $test_prefix;
            if ($current_pos > 0) { # have something already, need joiner
                $test_string .= $curr_phrase == $prev_phrase ? ' <-> ' : ' & ';
            }
            $test_string .= '!' if ($$pos_data{$current_pos}{negated} eq 't');
            $test_string .= $word;

            if ($current_pos == $last_pos) {
                return_next {suggestion => $string, test => $test_string};
            } else {
                gen_step($max_words, $data, $pos_data, $last_pos, $string, $test_string, $current_pos + 1);
            }
            
            last if ($max_words and $word_count >= $max_words);
        }
    }
$f$ LANGUAGE PLPERLU IMMUTABLE;

-- Changing parameters, so we have to drop the old one first
DROP FUNCTION search.symspell_lookup;
CREATE FUNCTION search.symspell_lookup (
    raw_input       TEXT,
    search_class    TEXT,
    verbosity       INT DEFAULT NULL,
    xfer_case       BOOL DEFAULT NULL,
    count_threshold INT DEFAULT NULL,
    soundex_weight  INT DEFAULT NULL,
    pg_trgm_weight  INT DEFAULT NULL,
    kbdist_weight   INT DEFAULT NULL
) RETURNS SETOF search.symspell_lookup_output AS $F$
DECLARE
    prefix_length INT;
    maxED         INT;
    word_list   TEXT[];
    edit_list   TEXT[] := '{}';
    seen_list   TEXT[] := '{}';
    output      search.symspell_lookup_output;
    output_list search.symspell_lookup_output[];
    entry       RECORD;
    entry_key   TEXT;
    prefix_key  TEXT;
    sugg        TEXT;
    input       TEXT;
    word        TEXT;
    w_pos       INT := -1;
    smallest_ed INT := -1;
    global_ed   INT;
    c_symspell_suggestion_verbosity INT;
    c_min_suggestion_use_threshold  INT;
    c_soundex_weight                INT;
    c_pg_trgm_weight                INT;
    c_keyboard_distance_weight      INT;
    c_symspell_transfer_case        BOOL;
BEGIN

    SELECT  cmc.min_suggestion_use_threshold,
            cmc.soundex_weight,
            cmc.pg_trgm_weight,
            cmc.keyboard_distance_weight,
            cmc.symspell_transfer_case,
            cmc.symspell_suggestion_verbosity
      INTO  c_min_suggestion_use_threshold,
            c_soundex_weight,
            c_pg_trgm_weight,
            c_keyboard_distance_weight,
            c_symspell_transfer_case,
            c_symspell_suggestion_verbosity
      FROM  config.metabib_class cmc
      WHERE cmc.name = search_class;

    c_min_suggestion_use_threshold := COALESCE(count_threshold,c_min_suggestion_use_threshold);
    c_symspell_transfer_case := COALESCE(xfer_case,c_symspell_transfer_case);
    c_symspell_suggestion_verbosity := COALESCE(verbosity,c_symspell_suggestion_verbosity);
    c_soundex_weight := COALESCE(soundex_weight,c_soundex_weight);
    c_pg_trgm_weight := COALESCE(pg_trgm_weight,c_pg_trgm_weight);
    c_keyboard_distance_weight := COALESCE(kbdist_weight,c_keyboard_distance_weight);

    SELECT value::INT INTO prefix_length FROM config.internal_flag WHERE name = 'symspell.prefix_length' AND enabled;
    prefix_length := COALESCE(prefix_length, 6);

    SELECT value::INT INTO maxED FROM config.internal_flag WHERE name = 'symspell.max_edit_distance' AND enabled;
    maxED := COALESCE(maxED, 3);

    -- XXX This should get some more thought ... maybe search_normalize?
    word_list := ARRAY_AGG(x.word) FROM search.query_parse_positions(raw_input) x;

    -- Common case exact match test for preformance
    IF c_symspell_suggestion_verbosity = 0 AND CARDINALITY(word_list) = 1 AND CHARACTER_LENGTH(word_list[1]) <= prefix_length THEN
        EXECUTE
          'SELECT  '||search_class||'_suggestions AS suggestions,
                   '||search_class||'_count AS count,
                   prefix_key
             FROM  search.symspell_dictionary
             WHERE prefix_key = $1
                   AND '||search_class||'_count >= $2 
                   AND '||search_class||'_suggestions @> ARRAY[$1]' 
          INTO entry USING evergreen.lowercase(word_list[1]), c_min_suggestion_use_threshold;
        IF entry.prefix_key IS NOT NULL THEN
            output.lev_distance := 0; -- definitionally
            output.prefix_key := entry.prefix_key;
            output.prefix_key_count := entry.count;
            output.suggestion_count := entry.count;
            output.input := word_list[1];
            IF c_symspell_transfer_case THEN
                output.suggestion := search.symspell_transfer_casing(output.input, entry.prefix_key);
            ELSE
                output.suggestion := entry.prefix_key;
            END IF;
            output.norm_input := entry.prefix_key;
            output.qwerty_kb_match := 1;
            output.pg_trgm_sim := 1;
            output.soundex_sim := 1;
            RETURN NEXT output;
            RETURN;
        END IF;
    END IF;

    <<word_loop>>
    FOREACH word IN ARRAY word_list LOOP
        w_pos := w_pos + 1;
        input := evergreen.lowercase(word);

        IF CHARACTER_LENGTH(input) > prefix_length THEN
            prefix_key := SUBSTRING(input FROM 1 FOR prefix_length);
            edit_list := ARRAY[input,prefix_key] || search.symspell_generate_edits(prefix_key, 1, maxED);
        ELSE
            edit_list := input || search.symspell_generate_edits(input, 1, maxED);
        END IF;

        SELECT ARRAY_AGG(x ORDER BY CHARACTER_LENGTH(x) DESC) INTO edit_list FROM UNNEST(edit_list) x;

        output_list := '{}';
        seen_list := '{}';
        global_ed := NULL;

        <<entry_key_loop>>
        FOREACH entry_key IN ARRAY edit_list LOOP
            smallest_ed := -1;
            IF global_ed IS NOT NULL THEN
                smallest_ed := global_ed;
            END IF;
            FOR entry IN EXECUTE
                'SELECT  '||search_class||'_suggestions AS suggestions,
                         '||search_class||'_count AS count,
                         prefix_key
                   FROM  search.symspell_dictionary
                   WHERE prefix_key = $1
                         AND '||search_class||'_suggestions IS NOT NULL' 
                USING entry_key
            LOOP
                FOREACH sugg IN ARRAY entry.suggestions LOOP
                    IF NOT seen_list @> ARRAY[sugg] THEN
                        seen_list := seen_list || sugg;
                        IF input = sugg THEN -- exact match, no need to spend time on a call
                            output.lev_distance := 0;
                            output.suggestion_count = entry.count;
                        ELSIF ABS(CHARACTER_LENGTH(input) - CHARACTER_LENGTH(sugg)) > maxED THEN
                            -- They are definitionally too different to consider, just move on.
                            CONTINUE;
                        ELSE
                            --output.lev_distance := levenshtein_less_equal(
                            output.lev_distance := evergreen.levenshtein_damerau_edistance(
                                input,
                                sugg,
                                maxED
                            );
                            IF output.lev_distance < 0 THEN
                                -- The Perl module returns -1 for "more distant than max".
                                output.lev_distance := maxED + 1;
                                -- This short-circuit's the count test below for speed, bypassing
                                -- a couple useless tests.
                                output.suggestion_count := -1;
                            ELSE
                                EXECUTE 'SELECT '||search_class||'_count FROM search.symspell_dictionary WHERE prefix_key = $1'
                                    INTO output.suggestion_count USING sugg;
                            END IF;
                        END IF;

                        -- The caller passes a minimum suggestion count threshold (or uses
                        -- the default of 0) and if the suggestion has that many or less uses
                        -- then we move on to the next suggestion, since this one is too rare.
                        CONTINUE WHEN output.suggestion_count < c_min_suggestion_use_threshold;

                        -- Track the smallest edit distance among suggestions from this prefix key.
                        IF smallest_ed = -1 OR output.lev_distance < smallest_ed THEN
                            smallest_ed := output.lev_distance;
                        END IF;

                        -- Track the smallest edit distance for all prefix keys for this word.
                        IF global_ed IS NULL OR smallest_ed < global_ed THEN
                            global_ed = smallest_ed;
                        END IF;

                        -- Only proceed if the edit distance is <= the max for the dictionary.
                        IF output.lev_distance <= maxED THEN
                            IF output.lev_distance > global_ed AND c_symspell_suggestion_verbosity <= 1 THEN
                                -- Lev distance is our main similarity measure. While
                                -- trgm or soundex similarity could be the main filter,
                                -- Lev is both language agnostic and faster.
                                --
                                -- Here we will skip suggestions that have a longer edit distance
                                -- than the shortest we've already found. This is simply an
                                -- optimization that allows us to avoid further processing
                                -- of this entry. It would be filtered out later.

                                CONTINUE;
                            END IF;

                            -- If we have an exact match on the suggestion key we can also avoid
                            -- some function calls.
                            IF output.lev_distance = 0 THEN
                                output.qwerty_kb_match := 1;
                                output.pg_trgm_sim := 1;
                                output.soundex_sim := 1;
                            ELSE
                                output.qwerty_kb_match := evergreen.qwerty_keyboard_distance_match(input, sugg);
                                output.pg_trgm_sim := similarity(input, sugg);
                                output.soundex_sim := difference(input, sugg) / 4.0;
                            END IF;

                            -- Fill in some fields
                            IF c_symspell_transfer_case THEN
                                output.suggestion := search.symspell_transfer_casing(word, sugg);
                            ELSE
                                output.suggestion := sugg;
                            END IF;
                            output.prefix_key := entry.prefix_key;
                            output.prefix_key_count := entry.count;
                            output.input := word;
                            output.norm_input := input;
                            output.word_pos := w_pos;

                            -- We can't "cache" a set of generated records directly, so
                            -- here we build up an array of search.symspell_lookup_output
                            -- records that we can revivicate later as a table using UNNEST().
                            output_list := output_list || output;

                            EXIT entry_key_loop WHEN smallest_ed = 0 AND c_symspell_suggestion_verbosity = 0; -- exact match early exit
                            CONTINUE entry_key_loop WHEN smallest_ed = 0 AND c_symspell_suggestion_verbosity = 1; -- exact match early jump to the next key
                        END IF; -- maxED test
                    END IF; -- suggestion not seen test
                END LOOP; -- loop over suggestions
            END LOOP; -- loop over entries
        END LOOP; -- loop over entry_keys

        -- Now we're done examining this word
        IF c_symspell_suggestion_verbosity = 0 THEN
            -- Return the "best" suggestion from the smallest edit
            -- distance group.  We define best based on the weighting
            -- of the non-lev similarity measures and use the suggestion
            -- use count to break ties.
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC
                        LIMIT 1;
        ELSIF c_symspell_suggestion_verbosity = 1 THEN
            -- Return all suggestions from the smallest
            -- edit distance group.
            RETURN QUERY
                SELECT * FROM UNNEST(output_list) WHERE lev_distance = smallest_ed
                    ORDER BY (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 2 THEN
            -- Return everything we find, along with relevant stats
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 3 THEN
            -- Return everything we find from the two smallest edit distance groups
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    WHERE lev_distance IN (SELECT DISTINCT lev_distance FROM UNNEST(output_list) ORDER BY 1 LIMIT 2)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 4 THEN
            -- Return everything we find from the two smallest edit distance groups that are NOT 0 distance
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    WHERE lev_distance IN (SELECT DISTINCT lev_distance FROM UNNEST(output_list) WHERE lev_distance > 0 ORDER BY 1 LIMIT 2)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        END IF;
    END LOOP; -- loop over words
END;
$F$ LANGUAGE PLPGSQL;

COMMIT;

-- Find the "broadest" value in use, and update the defaults for all classes
DO $do$
DECLARE
    val TEXT;
BEGIN
    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'opac.did_you_mean.low_result_threshold';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET low_result_threshold = val::INT;
    END IF;

    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'opac.did_you_mean.max_suggestions';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET max_suggestions = val::INT;
    END IF;

    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'search.symspell.min_suggestion_use_threshold';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET min_suggestion_use_threshold = val::INT;
    END IF;

    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'search.symspell.soundex.weight';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET soundex_weight = val::INT;
    END IF;

    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'search.symspell.pg_trgm.weight';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET pg_trgm_weight = val::INT;
    END IF;

    SELECT  FIRST(s.value ORDER BY t.depth) INTO val
      FROM  actor.org_unit_setting s
            JOIN actor.org_unit u ON (u.id = s.org_unit)
            JOIN actor.org_unit_type t ON (u.ou_type = t.id)
      WHERE s.name = 'search.symspell.keyboard_distance.weight';

    IF FOUND AND val IS NOT NULL THEN
        UPDATE config.metabib_class SET keyboard_distance_weight = val::INT;
    END IF;
END;
$do$;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1367', :eg_version);

-- Bring authorized headings into the symspell dictionary. Side
-- loader should be used for Real Sites.  See below the COMMIT.
/*
SELECT  search.symspell_build_and_merge_entries(h.value, m.field_class, NULL)
  FROM  authority.simple_heading h
        JOIN authority.control_set_auth_field_metabib_field_map_refs a ON (a.authority_field = h.atag)
        JOIN config.metabib_field m ON (a.metabib_field=m.id);
*/

-- ensure that this function is in place; it hitherto had not been
-- present in baseline

CREATE OR REPLACE FUNCTION search.symspell_build_and_merge_entries (
    full_input      TEXT,
    source_class    TEXT,
    old_input       TEXT DEFAULT NULL,
    include_phrases BOOL DEFAULT FALSE
) RETURNS SETOF search.symspell_dictionary AS $F$
DECLARE
    new_entry       RECORD;
    conflict_entry  RECORD;
BEGIN

    IF full_input = old_input THEN -- neither NULL, and are the same
        RETURN;
    END IF;

    FOR new_entry IN EXECUTE $q$
        SELECT  count,
                prefix_key,
                s AS suggestions
          FROM  (SELECT prefix_key,
                        ARRAY_AGG(DISTINCT $q$ || source_class || $q$_suggestions[1]) s,
                        SUM($q$ || source_class || $q$_count) count
                  FROM  search.symspell_build_entries($1, $2, $3, $4)
                  GROUP BY 1) x
        $q$ USING full_input, source_class, old_input, include_phrases
    LOOP
        EXECUTE $q$
            SELECT  prefix_key,
                    $q$ || source_class || $q$_suggestions suggestions,
                    $q$ || source_class || $q$_count count
              FROM  search.symspell_dictionary
              WHERE prefix_key = $1 $q$
            INTO conflict_entry
            USING new_entry.prefix_key;

        IF new_entry.count <> 0 THEN -- Real word, and count changed
            IF conflict_entry.prefix_key IS NOT NULL THEN -- we'll be updating
                IF conflict_entry.count > 0 THEN -- it's a real word
                    RETURN QUERY EXECUTE $q$
                        UPDATE  search.symspell_dictionary
                           SET  $q$ || source_class || $q$_count = $2
                          WHERE prefix_key = $1
                          RETURNING * $q$
                        USING new_entry.prefix_key, GREATEST(0, new_entry.count + conflict_entry.count);
                ELSE -- it was a prefix key or delete-emptied word before
                    IF conflict_entry.suggestions @> new_entry.suggestions THEN -- already have all suggestions here...
                        RETURN QUERY EXECUTE $q$
                            UPDATE  search.symspell_dictionary
                               SET  $q$ || source_class || $q$_count = $2
                              WHERE prefix_key = $1
                              RETURNING * $q$
                            USING new_entry.prefix_key, GREATEST(0, new_entry.count);
                    ELSE -- new suggestion!
                        RETURN QUERY EXECUTE $q$
                            UPDATE  search.symspell_dictionary
                               SET  $q$ || source_class || $q$_count = $2,
                                    $q$ || source_class || $q$_suggestions = $3
                              WHERE prefix_key = $1
                              RETURNING * $q$
                            USING new_entry.prefix_key, GREATEST(0, new_entry.count), evergreen.text_array_merge_unique(conflict_entry.suggestions,new_entry.suggestions);
                    END IF;
                END IF;
            ELSE
                -- We keep the on-conflict clause just in case...
                RETURN QUERY EXECUTE $q$
                    INSERT INTO search.symspell_dictionary AS d (
                        $q$ || source_class || $q$_count,
                        prefix_key,
                        $q$ || source_class || $q$_suggestions
                    ) VALUES ( $1, $2, $3 ) ON CONFLICT (prefix_key) DO
                        UPDATE SET  $q$ || source_class || $q$_count = d.$q$ || source_class || $q$_count + EXCLUDED.$q$ || source_class || $q$_count,
                                    $q$ || source_class || $q$_suggestions = evergreen.text_array_merge_unique(d.$q$ || source_class || $q$_suggestions, EXCLUDED.$q$ || source_class || $q$_suggestions)
                        RETURNING * $q$
                    USING new_entry.count, new_entry.prefix_key, new_entry.suggestions;
            END IF;
        ELSE -- key only, or no change
            IF conflict_entry.prefix_key IS NOT NULL THEN -- we'll be updating
                IF NOT conflict_entry.suggestions @> new_entry.suggestions THEN -- There are new suggestions
                    RETURN QUERY EXECUTE $q$
                        UPDATE  search.symspell_dictionary
                           SET  $q$ || source_class || $q$_suggestions = $2
                          WHERE prefix_key = $1
                          RETURNING * $q$
                        USING new_entry.prefix_key, evergreen.text_array_merge_unique(conflict_entry.suggestions,new_entry.suggestions);
                END IF;
            ELSE
                RETURN QUERY EXECUTE $q$
                    INSERT INTO search.symspell_dictionary AS d (
                        $q$ || source_class || $q$_count,
                        prefix_key,
                        $q$ || source_class || $q$_suggestions
                    ) VALUES ( $1, $2, $3 ) ON CONFLICT (prefix_key) DO -- key exists, suggestions may be added due to this entry
                        UPDATE SET  $q$ || source_class || $q$_suggestions = evergreen.text_array_merge_unique(d.$q$ || source_class || $q$_suggestions, EXCLUDED.$q$ || source_class || $q$_suggestions)
                    RETURNING * $q$
                    USING new_entry.count, new_entry.prefix_key, new_entry.suggestions;
            END IF;
        END IF;
    END LOOP;
END;
$F$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION search.symspell_maintain_entries () RETURNS TRIGGER AS $f$
DECLARE
    search_class    TEXT;
    new_value       TEXT := NULL;
    old_value       TEXT := NULL;
BEGIN

    IF TG_TABLE_SCHEMA = 'authority' THEN
        SELECT  m.field_class INTO search_class
          FROM  authority.control_set_auth_field_metabib_field_map_refs a
                JOIN config.metabib_field m ON (a.metabib_field=m.id)
          WHERE a.authority_field = NEW.atag;

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
    ELSE
        search_class := COALESCE(TG_ARGV[0], SPLIT_PART(TG_TABLE_NAME,'_',1));
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_value := NEW.value;
    END IF;

    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        old_value := OLD.value;
    END IF;

    PERFORM * FROM search.symspell_build_and_merge_entries(new_value, search_class, old_value);

    RETURN NULL; -- always fired AFTER
END;
$f$ LANGUAGE PLPGSQL;

CREATE TRIGGER maintain_symspell_entries_tgr
    AFTER INSERT OR UPDATE OR DELETE ON authority.simple_heading
    FOR EACH ROW EXECUTE PROCEDURE search.symspell_maintain_entries();

COMMIT;

\qecho ''
\qecho 'If the Evergreen database has authority records, a reingest of'
\qecho 'the search suggestion dictionary is recommended.'
\qecho ''
\qecho 'The following should be run at the end of the upgrade before any'
\qecho 'reingest occurs.  Because new triggers are installed already,'
\qecho 'updates to indexed strings will cause zero-count dictionary entries'
\qecho 'to be recorded which will require updating every row again (or'
\qecho 'starting from scratch) so best to do this before other batch'
\qecho 'changes.  A later reingest that does not significantly change'
\qecho 'indexed strings will /not/ cause table bloat here, and will be'
\qecho 'as fast as normal.  A copy of the SQL in a ready-to-use, non-escaped'
\qecho 'form is available inside a comment at the end of this upgrade sub-'
\qecho 'script so you do not need to copy this comment from the psql ouptut.'
\qecho ''
\qecho '\\a'
\qecho '\\t'
\qecho ''
\qecho '\\o title'
\qecho 'select value from metabib.title_field_entry;'
\qecho 'select  h.value'
\qecho '  from  authority.simple_heading h'
\qecho '        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)'
\qecho '        join config.metabib_field m on (a.metabib_field=m.id and m.field_class=\'title\');'
\qecho '\\o author'
\qecho 'select value from metabib.author_field_entry;'
\qecho 'select  h.value'
\qecho '  from  authority.simple_heading h'
\qecho '        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)'
\qecho '        join config.metabib_field m on (a.metabib_field=m.id and m.field_class=\'author\');'
\qecho '\\o subject'
\qecho 'select value from metabib.subject_field_entry;'
\qecho 'select  h.value'
\qecho '  from  authority.simple_heading h'
\qecho '        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)'
\qecho '        join config.metabib_field m on (a.metabib_field=m.id and m.field_class=\'subject\');'
\qecho '\\o series'
\qecho 'select value from metabib.series_field_entry;'
\qecho '\\o identifier'
\qecho 'select value from metabib.identifier_field_entry;'
\qecho '\\o keyword'
\qecho 'select value from metabib.keyword_field_entry;'
\qecho ''
\qecho '\\o'
\qecho '\\a'
\qecho '\\t'
\qecho ''
\qecho '// Then, at the command line:'
\qecho ''
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl title > title.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl author > author.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl subject > subject.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl series > series.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl identifier > identifier.sql'
\qecho '$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl keyword > keyword.sql'
\qecho ''
\qecho '// And, back in psql'
\qecho ''
\qecho 'ALTER TABLE search.symspell_dictionary SET UNLOGGED;'
\qecho 'TRUNCATE search.symspell_dictionary;'
\qecho ''
\qecho '\\i identifier.sql'
\qecho '\\i author.sql'
\qecho '\\i title.sql'
\qecho '\\i subject.sql'
\qecho '\\i series.sql'
\qecho '\\i keyword.sql'
\qecho ''
\qecho 'CLUSTER search.symspell_dictionary USING symspell_dictionary_pkey;'
\qecho 'REINDEX TABLE search.symspell_dictionary;'
\qecho 'ALTER TABLE search.symspell_dictionary SET LOGGED;'
\qecho 'VACUUM ANALYZE search.symspell_dictionary;'
\qecho ''
\qecho 'DROP TABLE search.symspell_dictionary_partial_title;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_author;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_subject;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_series;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_identifier;'
\qecho 'DROP TABLE search.symspell_dictionary_partial_keyword;'

/*
\a
\t

\o title
select value from metabib.title_field_entry;
select  h.value
  from  authority.simple_heading h
        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)
        join config.metabib_field m on (a.metabib_field=m.id and m.field_class='title');
\o author
select value from metabib.author_field_entry;
select  h.value
  from  authority.simple_heading h
        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)
        join config.metabib_field m on (a.metabib_field=m.id and m.field_class='author');
\o subject
select value from metabib.subject_field_entry;
select  h.value
  from  authority.simple_heading h
        join authority.control_set_auth_field_metabib_field_map_refs a on (a.authority_field = h.atag)
        join config.metabib_field m on (a.metabib_field=m.id and m.field_class='subject');
\o series
select value from metabib.series_field_entry;
\o identifier
select value from metabib.identifier_field_entry;
\o keyword
select value from metabib.keyword_field_entry;

\o
\a
\t

// Then, at the command line:

$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl title > title.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl author > author.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl subject > subject.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl series > series.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl identifier > identifier.sql
$ ~/EG-src-path/Open-ILS/src/support-scripts/symspell-sideload.pl keyword > keyword.sql

// And, back in psql

ALTER TABLE search.symspell_dictionary SET UNLOGGED;
TRUNCATE search.symspell_dictionary;

\i identifier.sql
\i author.sql
\i title.sql
\i subject.sql
\i series.sql
\i keyword.sql

CLUSTER search.symspell_dictionary USING symspell_dictionary_pkey;
REINDEX TABLE search.symspell_dictionary;
ALTER TABLE search.symspell_dictionary SET LOGGED;
VACUUM ANALYZE search.symspell_dictionary;

DROP TABLE search.symspell_dictionary_partial_title;
DROP TABLE search.symspell_dictionary_partial_author;
DROP TABLE search.symspell_dictionary_partial_subject;
DROP TABLE search.symspell_dictionary_partial_series;
DROP TABLE search.symspell_dictionary_partial_identifier;
DROP TABLE search.symspell_dictionary_partial_keyword;
*/
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1368', :eg_version);

CREATE OR REPLACE FUNCTION search.symspell_maintain_entries () RETURNS TRIGGER AS $f$
DECLARE
    search_class    TEXT;
    new_value       TEXT := NULL;
    old_value       TEXT := NULL;
BEGIN

    IF TG_TABLE_SCHEMA = 'authority' THEN
        SELECT  m.field_class INTO search_class
          FROM  authority.control_set_auth_field_metabib_field_map_refs a
                JOIN config.metabib_field m ON (a.metabib_field=m.id)
          WHERE a.authority_field = NEW.atag;

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
    ELSE
        search_class := COALESCE(TG_ARGV[0], SPLIT_PART(TG_TABLE_NAME,'_',1));
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_value := NEW.value;
    END IF;

    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        old_value := OLD.value;
    END IF;

    IF new_value = old_value THEN
        -- same, move along
    ELSE
        INSERT INTO search.symspell_dictionary_updates
            SELECT  txid_current(), *
              FROM  search.symspell_build_entries(
                        new_value,
                        search_class,
                        old_value
                    );
    END IF;

    -- PERFORM * FROM search.symspell_build_and_merge_entries(new_value, search_class, old_value);

    RETURN NULL; -- always fired AFTER
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.indexing_ingest_or_delete () RETURNS TRIGGER AS $func$
DECLARE
    ashs    authority.simple_heading%ROWTYPE;
    mbe_row metabib.browse_entry%ROWTYPE;
    mbe_id  BIGINT;
    ash_id  BIGINT;
BEGIN

    IF NEW.deleted IS TRUE THEN -- If this authority is deleted
        DELETE FROM authority.bib_linking WHERE authority = NEW.id; -- Avoid updating fields in bibs that are no longer visible
        DELETE FROM authority.full_rec WHERE record = NEW.id; -- Avoid validating fields against deleted authority records
        DELETE FROM authority.simple_heading WHERE record = NEW.id;
          -- Should remove matching $0 from controlled fields at the same time?

        -- XXX What do we about the actual linking subfields present in
        -- authority records that target this one when this happens?
        DELETE FROM authority.authority_linking
            WHERE source = NEW.id OR target = NEW.id;

        RETURN NEW; -- and we're done
    END IF;

    IF TG_OP = 'UPDATE' THEN -- re-ingest?
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.reingest.force_on_same_marc' AND enabled;

        IF NOT FOUND AND OLD.marc = NEW.marc THEN -- don't do anything if the MARC didn't change
            RETURN NEW;
        END IF;

        -- Unless there's a setting stopping us, propagate these updates to any linked bib records when the heading changes
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_auto_update' AND enabled;

        IF NOT FOUND AND NEW.heading <> OLD.heading THEN
            PERFORM authority.propagate_changes(NEW.id);
        END IF;
	
        DELETE FROM authority.simple_heading WHERE record = NEW.id;
        DELETE FROM authority.authority_linking WHERE source = NEW.id;
    END IF;

    INSERT INTO authority.authority_linking (source, target, field)
        SELECT source, target, field FROM authority.calculate_authority_linking(
            NEW.id, NEW.control_set, NEW.marc::XML
        );

    FOR ashs IN SELECT * FROM authority.simple_heading_set(NEW.marc) LOOP

        INSERT INTO authority.simple_heading (record,atag,value,sort_value,thesaurus)
            VALUES (ashs.record, ashs.atag, ashs.value, ashs.sort_value, ashs.thesaurus);
            ash_id := CURRVAL('authority.simple_heading_id_seq'::REGCLASS);

        SELECT INTO mbe_row * FROM metabib.browse_entry
            WHERE value = ashs.value AND sort_value = ashs.sort_value;

        IF FOUND THEN
            mbe_id := mbe_row.id;
        ELSE
            INSERT INTO metabib.browse_entry
                ( value, sort_value ) VALUES
                ( ashs.value, ashs.sort_value );

            mbe_id := CURRVAL('metabib.browse_entry_id_seq'::REGCLASS);
        END IF;

        INSERT INTO metabib.browse_entry_simple_heading_map (entry,simple_heading) VALUES (mbe_id,ash_id);

    END LOOP;

    -- Flatten and insert the afr data
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_full_rec' AND enabled;
    IF NOT FOUND THEN
        PERFORM authority.reingest_authority_full_rec(NEW.id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_rec_descriptor' AND enabled;
        IF NOT FOUND THEN
            PERFORM authority.reingest_authority_rec_descriptor(NEW.id);
        END IF;
    END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
    IF NOT FOUND THEN
        PERFORM search.symspell_dictionary_reify();
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1369', :eg_version);

INSERT INTO config.global_flag (name, enabled, label) VALUES (
    'ingest.queued.max_threads',  TRUE,
    oils_i18n_gettext(
        'ingest.queued.max_threads',
        'Queued Ingest: Maximum number of database workers allowed for queued ingest processes',
        'cgf',
        'label'
    )),(
    'ingest.queued.abort_on_error',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.abort_on_error',
        'Queued Ingest: Abort transaction on ingest error rather than simply logging an error',
        'cgf',
        'label'
    )),(
    'ingest.queued.authority.propagate',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.authority.propagate',
        'Queued Ingest: Queue all bib record updates on authority change propagation, even if bib queuing is not generally enabled',
        'cgf',
        'label'
    )),(
    'ingest.queued.all',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.all',
        'Queued Ingest: Use Queued Ingest for all bib and authority record ingest',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.all',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.biblio.all',
        'Queued Ingest: Use Queued Ingest for all bib record ingest',
        'cgf',
        'label'
    )),(
    'ingest.queued.authority.all',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.authority.all',
        'Queued Ingest: Use Queued Ingest for all authority record ingest',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.insert.marc_edit_inline',  TRUE,
    oils_i18n_gettext(
        'ingest.queued.biblio.insert.marc_edit_inline',
        'Queued Ingest: Do NOT use Queued Ingest when creating a new bib, or undeleting a bib, via the MARC editor',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.insert',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.biblio.insert',
        'Queued Ingest: Use Queued Ingest for bib record ingest on insert and undelete',
        'cgf',
        'label'
    )),(
    'ingest.queued.authority.insert',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.authority.insert',
        'Queued Ingest: Use Queued Ingest for authority record ingest on insert and undelete',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.update.marc_edit_inline',  TRUE,
    oils_i18n_gettext(
        'ingest.queued.biblio.update.marc_edit_inline',
        'Queued Ingest: Do NOT Use Queued Ingest when editing bib records via the MARC Editor',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.update',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.biblio.update',
        'Queued Ingest: Use Queued Ingest for bib record ingest on update',
        'cgf',
        'label'
    )),(
    'ingest.queued.authority.update',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.authority.update',
        'Queued Ingest: Use Queued Ingest for authority record ingest on update',
        'cgf',
        'label'
    )),(
    'ingest.queued.biblio.delete',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.biblio.delete',
        'Queued Ingest: Use Queued Ingest for bib record ingest on delete',
        'cgf',
        'label'
    )),(
    'ingest.queued.authority.delete',  FALSE,
    oils_i18n_gettext(
        'ingest.queued.authority.delete',
        'Queued Ingest: Use Queued Ingest for authority record ingest on delete',
        'cgf',
        'label'
    )
);

UPDATE config.global_flag SET value = '20' WHERE name = 'ingest.queued.max_threads';

CREATE OR REPLACE FUNCTION search.symspell_maintain_entries () RETURNS TRIGGER AS $f$
DECLARE
    search_class    TEXT;
    new_value       TEXT := NULL;
    old_value       TEXT := NULL;
    _atag           INTEGER;
BEGIN

    IF TG_TABLE_SCHEMA = 'authority' THEN
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            _atag = NEW.atag;
        ELSE
            _atag = OLD.atag;
        END IF;

        SELECT  m.field_class INTO search_class
          FROM  authority.control_set_auth_field_metabib_field_map_refs a
                JOIN config.metabib_field m ON (a.metabib_field=m.id)
          WHERE a.authority_field = _atag;

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
    ELSE
        search_class := COALESCE(TG_ARGV[0], SPLIT_PART(TG_TABLE_NAME,'_',1));
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_value := NEW.value;
    END IF;

    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        old_value := OLD.value;
    END IF;

    IF new_value = old_value THEN
        -- same, move along
    ELSE
        INSERT INTO search.symspell_dictionary_updates
            SELECT  txid_current(), *
              FROM  search.symspell_build_entries(
                        new_value,
                        search_class,
                        old_value
                    );
    END IF;

    -- PERFORM * FROM search.symspell_build_and_merge_entries(new_value, search_class, old_value);

    RETURN NULL; -- always fired AFTER
END;
$f$ LANGUAGE PLPGSQL;

CREATE TABLE action.ingest_queue (
    id          SERIAL      PRIMARY KEY,
    created     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    run_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    who         INT         REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    start_time  TIMESTAMPTZ,
    end_time    TIMESTAMPTZ,
    threads     INT,
    why         TEXT
);

CREATE TABLE action.ingest_queue_entry (
    id          BIGSERIAL   PRIMARY KEY,
    record      BIGINT      NOT NULL, -- points to a record id of the appropriate record_type
    record_type TEXT        NOT NULL,
    action      TEXT        NOT NULL,
    run_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    state_data  TEXT        NOT NULL DEFAULT '',
    queue       INT         REFERENCES action.ingest_queue (id) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    override_by BIGINT      REFERENCES action.ingest_queue_entry (id) ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    ingest_time TIMESTAMPTZ,
    fail_time   TIMESTAMPTZ
);
CREATE UNIQUE INDEX record_pending_once ON action.ingest_queue_entry (record_type,record,state_data) WHERE ingest_time IS NULL AND override_by IS NULL;
CREATE INDEX entry_override_by_idx ON action.ingest_queue_entry (override_by) WHERE override_by IS NOT NULL;

CREATE OR REPLACE FUNCTION action.enqueue_ingest_entry (
    record_id       BIGINT,
    rtype           TEXT DEFAULT 'biblio',
    when_to_run     TIMESTAMPTZ DEFAULT NOW(),
    queue_id        INT  DEFAULT NULL,
    ingest_action   TEXT DEFAULT 'update', -- will be the most common?
    old_state_data  TEXT DEFAULT ''
) RETURNS BOOL AS $F$
DECLARE
    new_entry       action.ingest_queue_entry%ROWTYPE;
    prev_del_entry  action.ingest_queue_entry%ROWTYPE;
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN

    IF ingest_action = 'delete' THEN
        -- first see if there is an outstanding entry
        SELECT  * INTO prev_del_entry
          FROM  action.ingest_queue_entry
          WHERE qe.record = record_id
                AND qe.state_date = old_state_data
                AND qe.record_type = rtype
                AND qe.ingest_time IS NULL
                AND qe.override_by IS NULL;
    END IF;

    WITH existing_queue_entry_cte AS (
        SELECT  queue_id AS queue,
                rtype AS record_type,
                record_id AS record,
                qe.id AS override_by,
                ingest_action AS action,
                q.run_at AS run_at,
                old_state_data AS state_data
          FROM  action.ingest_queue_entry qe
                JOIN action.ingest_queue q ON (qe.queue = q.id)
          WHERE qe.record = record_id
                AND q.end_time IS NULL
                AND qe.record_type = rtype
                AND qe.state_data = old_state_data
                AND qe.ingest_time IS NULL
                AND qe.fail_time IS NULL
                AND qe.override_by IS NULL
    ), existing_nonqueue_entry_cte AS (
        SELECT  queue_id AS queue,
                rtype AS record_type,
                record_id AS record,
                qe.id AS override_by,
                ingest_action AS action,
                qe.run_at AS run_at,
                old_state_data AS state_data
          FROM  action.ingest_queue_entry qe
          WHERE qe.record = record_id
                AND qe.queue IS NULL
                AND qe.record_type = rtype
                AND qe.state_data = old_state_data
                AND qe.ingest_time IS NULL
                AND qe.fail_time IS NULL
                AND qe.override_by IS NULL
    ), new_entry_cte AS (
        SELECT * FROM existing_queue_entry_cte
          UNION ALL
        SELECT * FROM existing_nonqueue_entry_cte
          UNION ALL
        SELECT queue_id, rtype, record_id, NULL, ingest_action, COALESCE(when_to_run,NOW()), old_state_data
    ), insert_entry_cte AS (
        INSERT INTO action.ingest_queue_entry
            (queue, record_type, record, override_by, action, run_at, state_data)
          SELECT queue, record_type, record, override_by, action, run_at, state_data FROM new_entry_cte
            ORDER BY 4 NULLS LAST, 6
            LIMIT 1
        RETURNING *
    ) SELECT * INTO new_entry FROM insert_entry_cte;

    IF prev_del_entry.id IS NOT NULL THEN -- later delete overrides earlier unapplied entry
        UPDATE  action.ingest_queue_entry
          SET   override_by = new_entry.id
          WHERE id = prev_del_entry.id;

        UPDATE  action.ingest_queue_entry
          SET   override_by = NULL
          WHERE id = new_entry.id;

    ELSIF new_entry.override_by IS NOT NULL THEN
        RETURN TRUE; -- already handled, don't notify
    END IF;

    NOTIFY queued_ingest;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$F$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION action.process_ingest_queue_entry (qeid BIGINT) RETURNS BOOL AS $func$
DECLARE
    ingest_success  BOOL := NULL;
    qe              action.ingest_queue_entry%ROWTYPE;
    aid             authority.record_entry.id%TYPE;
BEGIN

    SELECT * INTO qe FROM action.ingest_queue_entry WHERE id = qeid;
    IF qe.ingest_time IS NOT NULL OR qe.override_by IS NOT NULL THEN
        RETURN TRUE; -- Already done
    END IF;

    IF qe.action = 'delete' THEN
        IF qe.record_type = 'biblio' THEN
            SELECT metabib.indexing_delete(r.*, qe.state_data) INTO ingest_success FROM biblio.record_entry r WHERE r.id = qe.record;
        ELSIF qe.record_type = 'authority' THEN
            SELECT authority.indexing_delete(r.*, qe.state_data) INTO ingest_success FROM authority.record_entry r WHERE r.id = qe.record;
        END IF;
    ELSE
        IF qe.record_type = 'biblio' THEN
            IF qe.action = 'propagate' THEN
                SELECT authority.apply_propagate_changes(qe.state_data::BIGINT, qe.record) INTO aid;
                SELECT aid = qe.state_data::BIGINT INTO ingest_success;
            ELSE
                SELECT metabib.indexing_update(r.*, qe.action = 'insert', qe.state_data) INTO ingest_success FROM biblio.record_entry r WHERE r.id = qe.record;
            END IF;
        ELSIF qe.record_type = 'authority' THEN
            SELECT authority.indexing_update(r.*, qe.action = 'insert', qe.state_data) INTO ingest_success FROM authority.record_entry r WHERE r.id = qe.record;
        END IF;
    END IF;

    IF NOT ingest_success THEN
        UPDATE action.ingest_queue_entry SET fail_time = NOW() WHERE id = qe.id;
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.queued.abort_on_error' AND enabled;
        IF FOUND THEN
            RAISE EXCEPTION 'Ingest action of % on %.record_entry % for queue entry % failed', qe.action, qe.record_type, qe.record, qe.id;
        ELSE
            RAISE WARNING 'Ingest action of % on %.record_entry % for queue entry % failed', qe.action, qe.record_type, qe.record, qe.id;
        END IF;
    ELSE
        UPDATE action.ingest_queue_entry SET ingest_time = NOW() WHERE id = qe.id;
    END IF;

    RETURN ingest_success;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION action.complete_duplicated_entries () RETURNS TRIGGER AS $F$
BEGIN
    IF NEW.ingest_time IS NOT NULL THEN
        UPDATE action.ingest_queue_entry SET ingest_time = NEW.ingest_time WHERE override_by = NEW.id;
    END IF;

    RETURN NULL;
END;
$F$ LANGUAGE PLPGSQL;

CREATE TRIGGER complete_duplicated_entries_trigger
    AFTER UPDATE ON action.ingest_queue_entry
    FOR EACH ROW WHEN (NEW.override_by IS NULL)
    EXECUTE PROCEDURE action.complete_duplicated_entries();

CREATE OR REPLACE FUNCTION action.set_ingest_queue(INT) RETURNS VOID AS $$
    $_SHARED{"ingest_queue_id"} = $_[0];
$$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION action.get_ingest_queue() RETURNS INT AS $$
    return $_SHARED{"ingest_queue_id"};
$$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION action.clear_ingest_queue() RETURNS VOID AS $$
    delete($_SHARED{"ingest_queue_id"});
$$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION action.set_queued_ingest_force(TEXT) RETURNS VOID AS $$
    $_SHARED{"ingest_queue_force"} = $_[0];
$$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION action.get_queued_ingest_force() RETURNS TEXT AS $$
    return $_SHARED{"ingest_queue_force"};
$$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION action.clear_queued_ingest_force() RETURNS VOID AS $$
    delete($_SHARED{"ingest_queue_force"});
$$ LANGUAGE plperlu;

------------------ ingest functions ------------------

CREATE OR REPLACE FUNCTION metabib.indexing_delete (bib biblio.record_entry, extra TEXT DEFAULT NULL) RETURNS BOOL AS $func$
DECLARE
    tmp_bool BOOL;
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.metarecord_mapping.preserve_on_delete' AND enabled;
    tmp_bool := FOUND;

    PERFORM metabib.remap_metarecord_for_bib(bib.id, bib.fingerprint, TRUE, tmp_bool);

    IF NOT tmp_bool THEN
        -- One needs to keep these around to support searches
        -- with the #deleted modifier, so one should turn on the named
        -- internal flag for that functionality.
        DELETE FROM metabib.record_attr_vector_list WHERE source = bib.id;
    END IF;

    DELETE FROM authority.bib_linking abl WHERE abl.bib = bib.id; -- Avoid updating fields in bibs that are no longer visible
    DELETE FROM biblio.peer_bib_copy_map WHERE peer_record = bib.id; -- Separate any multi-homed items
    DELETE FROM metabib.browse_entry_def_map WHERE source = bib.id; -- Don't auto-suggest deleted bibs

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION metabib.indexing_update (bib biblio.record_entry, insert_only BOOL DEFAULT FALSE, extra TEXT DEFAULT NULL) RETURNS BOOL AS $func$
DECLARE
    skip_facet   BOOL   := FALSE;
    skip_display BOOL   := FALSE;
    skip_browse  BOOL   := FALSE;
    skip_search  BOOL   := FALSE;
    skip_auth    BOOL   := FALSE;
    skip_full    BOOL   := FALSE;
    skip_attrs   BOOL   := FALSE;
    skip_luri    BOOL   := FALSE;
    skip_mrmap   BOOL   := FALSE;
    only_attrs   TEXT[] := NULL;
    only_fields  INT[]  := '{}'::INT[];
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN

    -- Record authority linking
    SELECT extra LIKE '%skip_authority%' INTO skip_auth;
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_linking' AND enabled;
    IF NOT FOUND AND NOT skip_auth THEN
        PERFORM biblio.map_authority_linking( bib.id, bib.marc );
    END IF;

    -- Flatten and insert the mfr data
    SELECT extra LIKE '%skip_full_rec%' INTO skip_full;
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_metabib_full_rec' AND enabled;
    IF NOT FOUND AND NOT skip_full THEN
        PERFORM metabib.reingest_metabib_full_rec(bib.id);
    END IF;

    -- Now we pull out attribute data, which is dependent on the mfr for all but XPath-based fields
    SELECT extra LIKE '%skip_attrs%' INTO skip_attrs;
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_metabib_rec_descriptor' AND enabled;
    IF NOT FOUND AND NOT skip_attrs THEN
        IF extra ~ 'attr\(\s*(\w[ ,\w]*?)\s*\)' THEN
            SELECT REGEXP_SPLIT_TO_ARRAY(
                (REGEXP_MATCHES(extra, 'attr\(\s*(\w[ ,\w]*?)\s*\)'))[1],
                '\s*,\s*'
            ) INTO only_attrs;
        END IF;

        PERFORM metabib.reingest_record_attributes(bib.id, only_attrs, bib.marc, insert_only);
    END IF;

    -- Gather and insert the field entry data
    SELECT extra LIKE '%skip_facet%' INTO skip_facet;
    SELECT extra LIKE '%skip_display%' INTO skip_display;
    SELECT extra LIKE '%skip_browse%' INTO skip_browse;
    SELECT extra LIKE '%skip_search%' INTO skip_search;

    IF extra ~ 'field_list\(\s*(\d[ ,\d]+)\s*\)' THEN
        SELECT REGEXP_SPLIT_TO_ARRAY(
            (REGEXP_MATCHES(extra, 'field_list\(\s*(\d[ ,\d]+)\s*\)'))[1],
            '\s*,\s*'
        )::INT[] INTO only_fields;
    END IF;

    IF NOT skip_facet OR NOT skip_display OR NOT skip_browse OR NOT skip_search THEN
        PERFORM metabib.reingest_metabib_field_entries(bib.id, skip_facet, skip_display, skip_browse, skip_search, only_fields);
    END IF;

    -- Located URI magic
    SELECT extra LIKE '%skip_luri%' INTO skip_luri;
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_located_uri' AND enabled;
    IF NOT FOUND AND NOT skip_luri THEN PERFORM biblio.extract_located_uris( bib.id, bib.marc, bib.editor ); END IF;

    -- (re)map metarecord-bib linking
    SELECT extra LIKE '%skip_mrmap%' INTO skip_mrmap;
    IF insert_only THEN -- if not deleted and performing an insert, check for the flag
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.metarecord_mapping.skip_on_insert' AND enabled;
        IF NOT FOUND AND NOT skip_mrmap THEN
            PERFORM metabib.remap_metarecord_for_bib( bib.id, bib.fingerprint );
        END IF;
    ELSE -- we're doing an update, and we're not deleted, remap
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.metarecord_mapping.skip_on_update' AND enabled;
        IF NOT FOUND AND NOT skip_mrmap THEN
            PERFORM metabib.remap_metarecord_for_bib( bib.id, bib.fingerprint );
        END IF;
    END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.indexing_delete (auth authority.record_entry, extra TEXT DEFAULT NULL) RETURNS BOOL AS $func$
DECLARE
    tmp_bool BOOL;
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN
    DELETE FROM authority.bib_linking WHERE authority = NEW.id; -- Avoid updating fields in bibs that are no longer visible
    DELETE FROM authority.full_rec WHERE record = NEW.id; -- Avoid validating fields against deleted authority records
    DELETE FROM authority.simple_heading WHERE record = NEW.id;
      -- Should remove matching $0 from controlled fields at the same time?

    -- XXX What do we about the actual linking subfields present in
    -- authority records that target this one when this happens?
    DELETE FROM authority.authority_linking WHERE source = NEW.id OR target = NEW.id;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$func$ LANGUAGE PLPGSQL;


CREATE OR REPLACE FUNCTION authority.indexing_update (auth authority.record_entry, insert_only BOOL DEFAULT FALSE, old_heading TEXT DEFAULT NULL) RETURNS BOOL AS $func$
DECLARE
    ashs    authority.simple_heading%ROWTYPE;
    mbe_row metabib.browse_entry%ROWTYPE;
    mbe_id  BIGINT;
    ash_id  BIGINT;
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN

    -- Unless there's a setting stopping us, propagate these updates to any linked bib records when the heading changes
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_auto_update' AND enabled;

    IF NOT FOUND AND auth.heading <> old_heading THEN
        PERFORM authority.propagate_changes(auth.id);
    END IF;

    IF NOT insert_only THEN
        DELETE FROM authority.authority_linking WHERE source = auth.id;
        DELETE FROM authority.simple_heading WHERE record = auth.id;
    END IF;

    INSERT INTO authority.authority_linking (source, target, field)
        SELECT source, target, field FROM authority.calculate_authority_linking(
            auth.id, auth.control_set, auth.marc::XML
        );

    FOR ashs IN SELECT * FROM authority.simple_heading_set(auth.marc) LOOP

        INSERT INTO authority.simple_heading (record,atag,value,sort_value,thesaurus)
            VALUES (ashs.record, ashs.atag, ashs.value, ashs.sort_value, ashs.thesaurus);
            ash_id := CURRVAL('authority.simple_heading_id_seq'::REGCLASS);

        SELECT INTO mbe_row * FROM metabib.browse_entry
            WHERE value = ashs.value AND sort_value = ashs.sort_value;

        IF FOUND THEN
            mbe_id := mbe_row.id;
        ELSE
            INSERT INTO metabib.browse_entry
                ( value, sort_value ) VALUES
                ( ashs.value, ashs.sort_value );

            mbe_id := CURRVAL('metabib.browse_entry_id_seq'::REGCLASS);
        END IF;

        INSERT INTO metabib.browse_entry_simple_heading_map (entry,simple_heading) VALUES (mbe_id,ash_id);

    END LOOP;

    -- Flatten and insert the afr data
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_full_rec' AND enabled;
    IF NOT FOUND THEN
        PERFORM authority.reingest_authority_full_rec(auth.id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_rec_descriptor' AND enabled;
        IF NOT FOUND THEN
            PERFORM authority.reingest_authority_rec_descriptor(auth.id);
        END IF;
    END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
    IF NOT FOUND THEN
        PERFORM search.symspell_dictionary_reify();
    END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION evergreen.indexing_ingest_or_delete () RETURNS TRIGGER AS $func$
DECLARE
    old_state_data      TEXT := '';
    new_action          TEXT;
    queuing_force       TEXT;
    queuing_flag_name   TEXT;
    queuing_flag        BOOL := FALSE;
    queuing_success     BOOL := FALSE;
    ingest_success      BOOL := FALSE;
    ingest_queue        INT;
BEGIN

    -- Identify the ingest action type
    IF TG_OP = 'UPDATE' THEN

        -- Gather type-specific data for later use
        IF TG_TABLE_SCHEMA = 'authority' THEN
            old_state_data = OLD.heading;
        END IF;

        IF NOT OLD.deleted THEN -- maybe reingest?
            IF NEW.deleted THEN
                new_action = 'delete'; -- nope, delete
            ELSE
                new_action = 'update'; -- yes, update
            END IF;
        ELSIF NOT NEW.deleted THEN
            new_action = 'insert'; -- revivify, AKA insert
        ELSE
            RETURN NEW; -- was and is still deleted, don't ingest
        END IF;
    ELSIF TG_OP = 'INSERT' THEN
        new_action = 'insert'; -- brand new
    ELSE
        RETURN OLD; -- really deleting the record
    END IF;

    queuing_flag_name := 'ingest.queued.'||TG_TABLE_SCHEMA||'.'||new_action;
    -- See if we should be queuing anything
    SELECT  enabled INTO queuing_flag
      FROM  config.internal_flag
      WHERE name IN ('ingest.queued.all','ingest.queued.'||TG_TABLE_SCHEMA||'.all', queuing_flag_name)
            AND enabled
      LIMIT 1;

    SELECT action.get_queued_ingest_force() INTO queuing_force;
    IF queuing_flag IS NULL AND queuing_force = queuing_flag_name THEN
        queuing_flag := TRUE;
    END IF;

    -- you (or part of authority propagation) can forcibly disable specific queuing actions
    IF queuing_force = queuing_flag_name||'.disabled' THEN
        queuing_flag := FALSE;
    END IF;

    -- And if we should be queuing ...
    IF queuing_flag THEN
        ingest_queue := action.get_ingest_queue();

        -- ... but this is NOT a named or forced queue request (marc editor update, say, or vandelay overlay)...
        IF queuing_force IS NULL AND ingest_queue IS NULL AND new_action = 'update' THEN -- re-ingest?

            PERFORM * FROM config.internal_flag WHERE name = 'ingest.reingest.force_on_same_marc' AND enabled;

            --  ... then don't do anything if ingest.reingest.force_on_same_marc is not enabled and the MARC hasn't changed
            IF NOT FOUND AND OLD.marc = NEW.marc THEN
                RETURN NEW;
            END IF;
        END IF;

        -- Otherwise, attempt to enqueue
        SELECT action.enqueue_ingest_entry( NEW.id, TG_TABLE_SCHEMA, NOW(), ingest_queue, new_action, old_state_data) INTO queuing_success;
    END IF;

    -- If queuing was not requested, or failed for some reason, do it live.
    IF NOT queuing_success THEN
        IF queuing_flag THEN
            RAISE WARNING 'Enqueuing of %.record_entry % for ingest failed, attempting direct ingest', TG_TABLE_SCHEMA, NEW.id;
        END IF;

        IF new_action = 'delete' THEN
            IF TG_TABLE_SCHEMA = 'biblio' THEN
                SELECT metabib.indexing_delete(NEW.*, old_state_data) INTO ingest_success;
            ELSIF TG_TABLE_SCHEMA = 'authority' THEN
                SELECT authority.indexing_delete(NEW.*, old_state_data) INTO ingest_success;
            END IF;
        ELSE
            IF TG_TABLE_SCHEMA = 'biblio' THEN
                SELECT metabib.indexing_update(NEW.*, new_action = 'insert', old_state_data) INTO ingest_success;
            ELSIF TG_TABLE_SCHEMA = 'authority' THEN
                SELECT authority.indexing_update(NEW.*, new_action = 'insert', old_state_data) INTO ingest_success;
            END IF;
        END IF;
        
        IF NOT ingest_success THEN
            PERFORM * FROM config.internal_flag WHERE name = 'ingest.queued.abort_on_error' AND enabled;
            IF FOUND THEN
                RAISE EXCEPTION 'Ingest of %.record_entry % failed', TG_TABLE_SCHEMA, NEW.id;
            ELSE
                RAISE WARNING 'Ingest of %.record_entry % failed', TG_TABLE_SCHEMA, NEW.id;
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE PLPGSQL;

DROP TRIGGER aaa_indexing_ingest_or_delete ON biblio.record_entry;
DROP TRIGGER aaa_auth_ingest_or_delete ON authority.record_entry;

CREATE TRIGGER aaa_indexing_ingest_or_delete AFTER INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE evergreen.indexing_ingest_or_delete ();
CREATE TRIGGER aaa_auth_ingest_or_delete AFTER INSERT OR UPDATE ON authority.record_entry FOR EACH ROW EXECUTE PROCEDURE evergreen.indexing_ingest_or_delete ();

CREATE OR REPLACE FUNCTION metabib.reingest_record_attributes (rid BIGINT, pattr_list TEXT[] DEFAULT NULL, prmarc TEXT DEFAULT NULL, rdeleted BOOL DEFAULT TRUE) RETURNS VOID AS $func$
DECLARE
    transformed_xml TEXT;
    rmarc           TEXT := prmarc;
    tmp_val         TEXT;
    prev_xfrm       TEXT;
    normalizer      RECORD;
    xfrm            config.xml_transform%ROWTYPE;
    attr_vector     INT[] := '{}'::INT[];
    attr_vector_tmp INT[];
    attr_list       TEXT[] := pattr_list;
    attr_value      TEXT[];
    norm_attr_value TEXT[];
    tmp_xml         TEXT;
    tmp_array       TEXT[];
    attr_def        config.record_attr_definition%ROWTYPE;
    ccvm_row        config.coded_value_map%ROWTYPE;
    jump_past       BOOL;
BEGIN

    IF attr_list IS NULL OR rdeleted THEN -- need to do the full dance on INSERT or undelete
        SELECT ARRAY_AGG(name) INTO attr_list FROM config.record_attr_definition
        WHERE (
            tag IS NOT NULL OR
            fixed_field IS NOT NULL OR
            xpath IS NOT NULL OR
            phys_char_sf IS NOT NULL OR
            composite
        ) AND (
            filter OR sorter
        );
    END IF;

    IF rmarc IS NULL THEN
        SELECT marc INTO rmarc FROM biblio.record_entry WHERE id = rid;
    END IF;

    FOR attr_def IN SELECT * FROM config.record_attr_definition WHERE NOT composite AND name = ANY( attr_list ) ORDER BY format LOOP

        jump_past := FALSE; -- This gets set when we are non-multi and have found something
        attr_value := '{}'::TEXT[];
        norm_attr_value := '{}'::TEXT[];
        attr_vector_tmp := '{}'::INT[];

        SELECT * INTO ccvm_row FROM config.coded_value_map c WHERE c.ctype = attr_def.name LIMIT 1;

        IF attr_def.tag IS NOT NULL THEN -- tag (and optional subfield list) selection
            SELECT  ARRAY_AGG(value) INTO attr_value
              FROM  (SELECT * FROM metabib.full_rec ORDER BY tag, subfield) AS x
              WHERE record = rid
                    AND tag LIKE attr_def.tag
                    AND CASE
                        WHEN attr_def.sf_list IS NOT NULL
                            THEN POSITION(subfield IN attr_def.sf_list) > 0
                        ELSE TRUE
                    END
              GROUP BY tag
              ORDER BY tag;

            IF NOT attr_def.multi THEN
                attr_value := ARRAY[ARRAY_TO_STRING(attr_value, COALESCE(attr_def.joiner,' '))];
                jump_past := TRUE;
            END IF;
        END IF;

        IF NOT jump_past AND attr_def.fixed_field IS NOT NULL THEN -- a named fixed field, see config.marc21_ff_pos_map.fixed_field
            attr_value := attr_value || vandelay.marc21_extract_fixed_field_list(rmarc, attr_def.fixed_field);

            IF NOT attr_def.multi THEN
                attr_value := ARRAY[attr_value[1]];
                jump_past := TRUE;
            END IF;
        END IF;

        IF NOT jump_past AND attr_def.xpath IS NOT NULL THEN -- and xpath expression

            SELECT INTO xfrm * FROM config.xml_transform WHERE name = attr_def.format;

            -- See if we can skip the XSLT ... it's expensive
            IF prev_xfrm IS NULL OR prev_xfrm <> xfrm.name THEN
                -- Can't skip the transform
                IF xfrm.xslt <> '---' THEN
                    transformed_xml := oils_xslt_process(rmarc,xfrm.xslt);
                ELSE
                    transformed_xml := rmarc;
                END IF;

                prev_xfrm := xfrm.name;
            END IF;

            IF xfrm.name IS NULL THEN
                -- just grab the marcxml (empty) transform
                SELECT INTO xfrm * FROM config.xml_transform WHERE xslt = '---' LIMIT 1;
                prev_xfrm := xfrm.name;
            END IF;

            FOR tmp_xml IN SELECT UNNEST(oils_xpath(attr_def.xpath, transformed_xml, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]])) LOOP
                tmp_val := oils_xpath_string(
                                '//*',
                                tmp_xml,
                                COALESCE(attr_def.joiner,' '),
                                ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]]
                            );
                IF tmp_val IS NOT NULL AND BTRIM(tmp_val) <> '' THEN
                    attr_value := attr_value || tmp_val;
                    EXIT WHEN NOT attr_def.multi;
                END IF;
            END LOOP;
        END IF;

        IF NOT jump_past AND attr_def.phys_char_sf IS NOT NULL THEN -- a named Physical Characteristic, see config.marc21_physical_characteristic_*_map
            SELECT  ARRAY_AGG(m.value) INTO tmp_array
              FROM  vandelay.marc21_physical_characteristics(rmarc) v
                    LEFT JOIN config.marc21_physical_characteristic_value_map m ON (m.id = v.value)
              WHERE v.subfield = attr_def.phys_char_sf AND (m.value IS NOT NULL AND BTRIM(m.value) <> '')
                    AND ( ccvm_row.id IS NULL OR ( ccvm_row.id IS NOT NULL AND v.id IS NOT NULL) );

            attr_value := attr_value || tmp_array;

            IF NOT attr_def.multi THEN
                attr_value := ARRAY[attr_value[1]];
            END IF;

        END IF;

                -- apply index normalizers to attr_value
        FOR tmp_val IN SELECT value FROM UNNEST(attr_value) x(value) LOOP
            FOR normalizer IN
                SELECT  n.func AS func,
                        n.param_count AS param_count,
                        m.params AS params
                  FROM  config.index_normalizer n
                        JOIN config.record_attr_index_norm_map m ON (m.norm = n.id)
                  WHERE attr = attr_def.name
                  ORDER BY m.pos LOOP
                    EXECUTE 'SELECT ' || normalizer.func || '(' ||
                    COALESCE( quote_literal( tmp_val ), 'NULL' ) ||
                        CASE
                            WHEN normalizer.param_count > 0
                                THEN ',' || REPLACE(REPLACE(BTRIM(normalizer.params,'[]'),E'\'',E'\\\''),E'"',E'\'')
                                ELSE ''
                            END ||
                    ')' INTO tmp_val;

            END LOOP;
            IF tmp_val IS NOT NULL AND tmp_val <> '' THEN
                -- note that a string that contains only blanks
                -- is a valid value for some attributes
                norm_attr_value := norm_attr_value || tmp_val;
            END IF;
        END LOOP;

        IF attr_def.filter THEN
            -- Create unknown uncontrolled values and find the IDs of the values
            IF ccvm_row.id IS NULL THEN
                FOR tmp_val IN SELECT value FROM UNNEST(norm_attr_value) x(value) LOOP
                    IF tmp_val IS NOT NULL AND BTRIM(tmp_val) <> '' THEN
                        BEGIN -- use subtransaction to isolate unique constraint violations
                            INSERT INTO metabib.uncontrolled_record_attr_value ( attr, value ) VALUES ( attr_def.name, tmp_val );
                        EXCEPTION WHEN unique_violation THEN END;
                    END IF;
                END LOOP;

                SELECT ARRAY_AGG(id) INTO attr_vector_tmp FROM metabib.uncontrolled_record_attr_value WHERE attr = attr_def.name AND value = ANY( norm_attr_value );
            ELSE
                SELECT ARRAY_AGG(id) INTO attr_vector_tmp FROM config.coded_value_map WHERE ctype = attr_def.name AND code = ANY( norm_attr_value );
            END IF;

            -- Add the new value to the vector
            attr_vector := attr_vector || attr_vector_tmp;
        END IF;

        IF attr_def.sorter THEN
            DELETE FROM metabib.record_sorter WHERE source = rid AND attr = attr_def.name;
            IF norm_attr_value[1] IS NOT NULL THEN
                INSERT INTO metabib.record_sorter (source, attr, value) VALUES (rid, attr_def.name, norm_attr_value[1]);
            END IF;
        END IF;

    END LOOP;

/* We may need to rewrite the vlist to contain
   the intersection of new values for requested
   attrs and old values for ignored attrs. To
   do this, we take the old attr vlist and
   subtract any values that are valid for the
   requested attrs, and then add back the new
   set of attr values. */

    IF ARRAY_LENGTH(pattr_list, 1) > 0 THEN
        SELECT vlist INTO attr_vector_tmp FROM metabib.record_attr_vector_list WHERE source = rid;
        SELECT attr_vector_tmp - ARRAY_AGG(id::INT) INTO attr_vector_tmp FROM metabib.full_attr_id_map WHERE attr = ANY (pattr_list);
        attr_vector := attr_vector || attr_vector_tmp;
    END IF;

    -- On to composite attributes, now that the record attrs have been pulled.  Processed in name order, so later composite
    -- attributes can depend on earlier ones.
    PERFORM metabib.compile_composite_attr_cache_init();
    FOR attr_def IN SELECT * FROM config.record_attr_definition WHERE composite AND name = ANY( attr_list ) ORDER BY name LOOP

        FOR ccvm_row IN SELECT * FROM config.coded_value_map c WHERE c.ctype = attr_def.name ORDER BY value LOOP

            tmp_val := metabib.compile_composite_attr( ccvm_row.id );
            CONTINUE WHEN tmp_val IS NULL OR tmp_val = ''; -- nothing to do

            IF attr_def.filter THEN
                IF attr_vector @@ tmp_val::query_int THEN
                    attr_vector = attr_vector + intset(ccvm_row.id);
                    EXIT WHEN NOT attr_def.multi;
                END IF;
            END IF;

            IF attr_def.sorter THEN
                IF attr_vector @@ tmp_val THEN
                    DELETE FROM metabib.record_sorter WHERE source = rid AND attr = attr_def.name;
                    INSERT INTO metabib.record_sorter (source, attr, value) VALUES (rid, attr_def.name, ccvm_row.code);
                END IF;
            END IF;

        END LOOP;

    END LOOP;

    IF ARRAY_LENGTH(attr_vector, 1) > 0 THEN
        INSERT INTO metabib.record_attr_vector_list (source, vlist) VALUES (rid, attr_vector)
            ON CONFLICT (source) DO UPDATE SET vlist = EXCLUDED.vlist;
    END IF;

END;

$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.propagate_changes
    (aid BIGINT, bid BIGINT) RETURNS BIGINT AS $func$
DECLARE
    queuing_success BOOL := FALSE;
BEGIN

    PERFORM 1 FROM config.global_flag
        WHERE name IN ('ingest.queued.all','ingest.queued.authority.propagate')
            AND enabled;

    IF FOUND THEN
        -- XXX enqueue special 'propagate' bib action
        SELECT action.enqueue_ingest_entry( bid, 'biblio', NOW(), NULL, 'propagate', aid::TEXT) INTO queuing_success;

        IF queuing_success THEN
            RETURN aid;
        END IF;
    END IF;

    PERFORM authority.apply_propagate_changes(aid, bid);
    RETURN aid;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.apply_propagate_changes
    (aid BIGINT, bid BIGINT) RETURNS BIGINT AS $func$
DECLARE
    bib_forced  BOOL := FALSE;
    bib_rec     biblio.record_entry%ROWTYPE;
    new_marc    TEXT;
BEGIN

    SELECT INTO bib_rec * FROM biblio.record_entry WHERE id = bid;

    new_marc := vandelay.merge_record_xml(
        bib_rec.marc, authority.generate_overlay_template(aid));

    IF new_marc = bib_rec.marc THEN
        -- Authority record change had no impact on this bib record.
        -- Nothing left to do.
        RETURN aid;
    END IF;

    PERFORM 1 FROM config.global_flag
        WHERE name = 'ingest.disable_authority_auto_update_bib_meta'
            AND enabled;

    IF NOT FOUND THEN
        -- update the bib record editor and edit_date
        bib_rec.editor := (
            SELECT editor FROM authority.record_entry WHERE id = aid);
        bib_rec.edit_date = NOW();
    END IF;

    PERFORM action.set_queued_ingest_force('ingest.queued.biblio.update.disabled');

    UPDATE biblio.record_entry SET
        marc = new_marc,
        editor = bib_rec.editor,
        edit_date = bib_rec.edit_date
    WHERE id = bid;

    PERFORM action.clear_queued_ingest_force();

    RETURN aid;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries(
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE,
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE,
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id || $$ AND field = ANY($1)$$ USING field_list;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id AND def = ANY(field_list);
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

	-- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN
            -- A caveat about this SELECT: this should take care of replacing
            -- old mbe rows when data changes, but not if normalization (by
            -- which I mean specifically the output of
            -- evergreen.oils_tsearch2()) changes.  It may or may not be
            -- expensive to add a comparison of index_vector to index_vector
            -- to the WHERE clause below.

            CONTINUE WHEN ind_data.sort_value IS NULL;

            value_prepped := metabib.browse_normalize(ind_data.value, ind_data.field);
            IF ind_data.browse_nocase THEN -- for "nocase" browse definions, look for a preexisting row that matches case-insensitively on value and use that
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE evergreen.lowercase(value) = evergreen.lowercase(value_prepped) AND sort_value = ind_data.sort_value
                    ORDER BY sort_value, value LIMIT 1; -- gotta pick something, I guess
            END IF;

            IF mbe_row.id IS NOT NULL THEN -- asked to check for, and found, a "nocase" version to use
                mbe_id := mbe_row.id;
            ELSE -- otherwise, an UPSERT-protected variant
                INSERT INTO metabib.browse_entry
                    ( value, sort_value ) VALUES
                    ( value_prepped, ind_data.sort_value )
                  ON CONFLICT (sort_value, value) DO UPDATE SET sort_value = EXCLUDED.sort_value -- must update a row to return an existing id
                  RETURNING id INTO mbe_id;
            END IF;

            INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
                VALUES (mbe_id, ind_data.field, ind_data.source, ind_data.authority);
        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
        IF NOT FOUND THEN
            PERFORM search.symspell_dictionary_reify();
        END IF;
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;

-- get rid of old version
DROP FUNCTION authority.indexing_ingest_or_delete;

COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1370', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES
    (
        'eg.orgselect.admin.stat_cat.owner', 'gui', 'integer',
        oils_i18n_gettext(
            'eg.orgselect.admin.stat_cat.owner',
            'Default org unit for stat cat and stat cat entry editors',
            'cwst', 'label'
        )
    ), (
        'eg.orgfamilyselect.admin.item_stat_cat.main_org_selector', 'gui', 'integer',
        oils_i18n_gettext(
            'eg.orgfamilyselect.admin.item_stat_cat.main_org_selector',
            'Default org unit for the main org select in the item stat cat and stat cat entry admin interfaces.',
            'cwst', 'label'
        )
    ), (
        'eg.orgfamilyselect.admin.patron_stat_cat.main_org_selector', 'gui', 'integer',
        oils_i18n_gettext(
            'eg.orgfamilyselect.admin.patron_stat_cat.main_org_selector',
            'Default org unit for the main org select in the patron stat cat and stat cat entry admin interfaces.',
            'cwst', 'label'
        )
    );

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1371', :eg_version);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES

    ( 'credit.processor.smartpay.enabled', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.enabled',
        'Enable SmartPAY payments',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.enabled',
        'Enable SmartPAY payments',
        'coust', 'description'),
    'bool', null)

,( 'credit.processor.smartpay.location_id', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.location_id',
        'SmartPAY location ID',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.location_id',
        'SmartPAY location ID")',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.customer_id', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.customer_id',
        'SmartPAY customer ID',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.customer_id',
        'SmartPAY customer ID',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.login', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.login',
        'SmartPAY login name',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.login',
        'SmartPAY login name',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.password', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.password',
        'SmartPAY password',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.password',
        'SmartPAY password',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.api_key', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.api_key',
        'SmartPAY API key',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.api_key',
        'SmartPAY API key',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.server', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.server',
        'SmartPAY server name',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.server',
        'SmartPAY server name',
        'coust', 'description'),
    'string', null)

,( 'credit.processor.smartpay.port', 'credit',
    oils_i18n_gettext('credit.processor.smartpay.port',
        'SmartPAY server port',
        'coust', 'label'),
    oils_i18n_gettext('credit.processor.smartpay.port',
        'SmartPAY server port',
        'coust', 'description'),
    'string', null)
;

UPDATE config.org_unit_setting_type
SET description = oils_i18n_gettext('credit.processor.default',
        'This might be "AuthorizeNet", "PayPal", "PayflowPro", "SmartPAY", or "Stripe".',
        'coust', 'description')
WHERE name = 'credit.processor.default' AND description = 'This might be "AuthorizeNet", "PayPal", "PayflowPro", or "Stripe".'; -- don't clobber local edits or i18n

UPDATE config.org_unit_setting_type
    SET view_perm = (SELECT id FROM permission.perm_list
        WHERE code = 'VIEW_CREDIT_CARD_PROCESSING' LIMIT 1)
    WHERE name LIKE 'credit.processor.smartpay.%' AND view_perm IS NULL;

UPDATE config.org_unit_setting_type
    SET update_perm = (SELECT id FROM permission.perm_list
        WHERE code = 'ADMIN_CREDIT_CARD_PROCESSING' LIMIT 1)
    WHERE name LIKE 'credit.processor.smartpay.%' AND update_perm IS NULL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1372', :eg_version);

INSERT INTO permission.perm_list (id, code, description) VALUES
 ( 643, 'VIEW_HOLD_PULL_LIST', oils_i18n_gettext(643,
    'View hold pull list', 'ppl', 'description'));

-- by default, assign VIEW_HOLD_PULL_LIST to everyone who has VIEW_HOLDS
INSERT INTO permission.grp_perm_map (perm, grp, depth, grantable)
    SELECT 643, grp, depth, grantable
    FROM permission.grp_perm_map
    WHERE perm = 9;

INSERT INTO permission.usr_perm_map (perm, usr, depth, grantable)
    SELECT 643, usr, depth, grantable
    FROM permission.usr_perm_map
    WHERE perm = 9;

COMMIT;

BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1373', :eg_version);

-- 950.data.seed-values.sql

INSERT INTO config.global_flag (name, value, enabled, label)
VALUES (
    'circ.holds.api_require_monographic_part_when_present',
    NULL,
    FALSE,
    oils_i18n_gettext(
        'circ.holds.api_require_monographic_part_when_present',
        'Holds: Require Monographic Part When Present for hold check.',
        'cgf', 'label'
    )
);

INSERT INTO config.org_unit_setting_type (name, label, grp, description, datatype)
VALUES (
    'circ.holds.ui_require_monographic_part_when_present',
    oils_i18n_gettext('circ.holds.ui_require_monographic_part_when_present',
        'Require Monographic Part when Present',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.holds.ui_require_monographic_part_when_present',
        'Normally the selection of a monographic part during hold placement is optional if there is at least one copy on the bib without a monographic part.  A true value for this setting will require part selection even under this condition.',
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1374', :eg_version);

INSERT INTO config.org_unit_setting_type (name, label, grp, description, datatype, fm_class) VALUES
(   'circ.custom_penalty_override.PATRON_EXCEEDS_FINES',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_FINES',
        'Custom PATRON_EXCEEDS_FINES penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_FINES',
        'Specifies a non-default standing penalty to apply to patrons that exceed the max-fine threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_EXCEEDS_OVERDUE_COUNT',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_OVERDUE_COUNT',
        'Custom PATRON_EXCEEDS_OVERDUE_COUNT penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_OVERDUE_COUNT',
        'Specifies a non-default standing penalty to apply to patrons that exceed the overdue count threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_EXCEEDS_CHECKOUT_COUNT',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_CHECKOUT_COUNT',
        'Custom PATRON_EXCEEDS_CHECKOUT_COUNT penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_CHECKOUT_COUNT',
        'Specifies a non-default standing penalty to apply to patrons that exceed the checkout count threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_EXCEEDS_COLLECTIONS_WARNING',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_COLLECTIONS_WARNING',
        'Custom PATRON_EXCEEDS_COLLECTIONS_WARNING penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_COLLECTIONS_WARNING',
        'Specifies a non-default standing penalty to apply to patrons that exceed the collections fine warning threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_EXCEEDS_LOST_COUNT',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_LOST_COUNT',
        'Custom PATRON_EXCEEDS_LOST_COUNT penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_LOST_COUNT',
        'Specifies a non-default standing penalty to apply to patrons that exceed the lost item count threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_EXCEEDS_LONGOVERDUE_COUNT',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_LONGOVERDUE_COUNT',
        'Custom PATRON_EXCEEDS_LONGOVERDUE_COUNT penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_EXCEEDS_LONGOVERDUE_COUNT',
        'Specifies a non-default standing penalty to apply to patrons that exceed the long-overdue item count threshold for their group.',
        'coust', 'description'),
    'link', 'csp'),
(   'circ.custom_penalty_override.PATRON_IN_COLLECTIONS',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_IN_COLLECTIONS',
        'Custom PATRON_IN_COLLECTIONS penalty',
        'coust', 'label'),
    'circ',
    oils_i18n_gettext('circ.custom_penalty_override.PATRON_IN_COLLECTIONS',
        'Specifies a non-default standing penalty that may have been applied to patrons that have been placed into collections and that should be automatically removed if they have paid down their balance below the threshold for their group. Use of this feature will likely require configuration and coordination with an external collection agency.',
        'coust', 'description'),
    'link', 'csp')
;

CREATE OR REPLACE FUNCTION actor.calculate_system_penalties( match_user INT, context_org INT ) RETURNS SETOF actor.usr_standing_penalty AS $func$
DECLARE
    user_object         actor.usr%ROWTYPE;
    new_sp_row          actor.usr_standing_penalty%ROWTYPE;
    existing_sp_row     actor.usr_standing_penalty%ROWTYPE;
    collections_fines   permission.grp_penalty_threshold%ROWTYPE;
    max_fines           permission.grp_penalty_threshold%ROWTYPE;
    max_overdue         permission.grp_penalty_threshold%ROWTYPE;
    max_items_out       permission.grp_penalty_threshold%ROWTYPE;
    max_lost            permission.grp_penalty_threshold%ROWTYPE;
    max_longoverdue     permission.grp_penalty_threshold%ROWTYPE;
    penalty_id          INT;
    tmp_grp             INT;
    items_overdue       INT;
    items_out           INT;
    items_lost          INT;
    items_longoverdue   INT;
    context_org_list    INT[];
    current_fines        NUMERIC(8,2) := 0.0;
    tmp_fines            NUMERIC(8,2);
    tmp_groc            RECORD;
    tmp_circ            RECORD;
    tmp_org             actor.org_unit%ROWTYPE;
    tmp_penalty         config.standing_penalty%ROWTYPE;
    tmp_depth           INTEGER;
BEGIN
    SELECT INTO user_object * FROM actor.usr WHERE id = match_user;

    -- Max fines
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_FINES', context_org);
    IF NOT FOUND THEN penalty_id := 1; END IF;

    -- Fail if the user has a high fine balance
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN
        -- The IN clause in all of the RETURN QUERY calls is used to surface now-stale non-custom penalties
        -- so that the calling code can clear them at the boundary where custom penalties are configured.
        -- Otherwise we would see orphaned "stock" system penalties that would never go away on their own.
        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_fines.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty IN (1, penalty_id);

        SELECT INTO context_org_list ARRAY_AGG(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND xact_finish IS NULL ) l USING (id);

        IF current_fines >= max_fines.threshold THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_fines.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for max overdue
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_OVERDUE_COUNT', context_org);
    IF NOT FOUND THEN penalty_id := 2; END IF;

    -- Fail if the user has too many overdue items
    LOOP
        tmp_grp := user_object.profile;
        LOOP

            SELECT * INTO max_overdue FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_overdue.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_overdue.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_overdue.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_overdue.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty IN (2, penalty_id);

        SELECT  INTO items_overdue COUNT(*)
          FROM  action.circulation circ
                JOIN  actor.org_unit_full_path( max_overdue.org_unit ) fp ON (circ.circ_lib = fp.id)
          WHERE circ.usr = match_user
            AND circ.checkin_time IS NULL
            AND circ.due_date < NOW()
            AND (circ.stop_fines = 'MAXFINES' OR circ.stop_fines IS NULL);

        IF items_overdue >= max_overdue.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_overdue.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for max out
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_CHECKOUT_COUNT', context_org);
    IF NOT FOUND THEN penalty_id := 3; END IF;

    -- Fail if the user has too many checked out items
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_items_out FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_items_out.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_items_out.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;


    -- Fail if the user has too many items checked out
    IF max_items_out.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_items_out.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty IN (3, penalty_id);

        SELECT  INTO items_out COUNT(*)
          FROM  action.circulation circ
                JOIN  actor.org_unit_full_path( max_items_out.org_unit ) fp ON (circ.circ_lib = fp.id)
          WHERE circ.usr = match_user
                AND circ.checkin_time IS NULL
                AND (circ.stop_fines IN (
                    SELECT 'MAXFINES'::TEXT
                    UNION ALL
                    SELECT 'LONGOVERDUE'::TEXT
                    UNION ALL
                    SELECT 'LOST'::TEXT
                    WHERE 'true' ILIKE
                    (
                        SELECT CASE
                            WHEN (SELECT value FROM actor.org_unit_ancestor_setting('circ.tally_lost', circ.circ_lib)) ILIKE 'true' THEN 'true'
                            ELSE 'false'
                        END
                    )
                    UNION ALL
                    SELECT 'CLAIMSRETURNED'::TEXT
                    WHERE 'false' ILIKE
                    (
                        SELECT CASE
                            WHEN (SELECT value FROM actor.org_unit_ancestor_setting('circ.do_not_tally_claims_returned', circ.circ_lib)) ILIKE 'true' THEN 'true'
                            ELSE 'false'
                        END
                    )
                    ) OR circ.stop_fines IS NULL)
                AND xact_finish IS NULL;

           IF items_out >= max_items_out.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_items_out.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
           END IF;
    END IF;

    -- Start over for max lost
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_LOST_COUNT', context_org);
    IF NOT FOUND THEN penalty_id := 5; END IF;

    -- Fail if the user has too many lost items
    LOOP
        tmp_grp := user_object.profile;
        LOOP

            SELECT * INTO max_lost FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_lost.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_lost.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_lost.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
            FROM  actor.usr_standing_penalty
            WHERE usr = match_user
                AND org_unit = max_lost.org_unit
                AND (stop_date IS NULL or stop_date > NOW())
                AND standing_penalty IN (5, penalty_id);

        SELECT  INTO items_lost COUNT(*)
        FROM  action.circulation circ
            JOIN  actor.org_unit_full_path( max_lost.org_unit ) fp ON (circ.circ_lib = fp.id)
        WHERE circ.usr = match_user
            AND circ.checkin_time IS NULL
            AND (circ.stop_fines = 'LOST')
            AND xact_finish IS NULL;

        IF items_lost >= max_lost.threshold::INT AND 0 < max_lost.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_lost.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for max longoverdue
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_LONGOVERDUE_COUNT', context_org);
    IF NOT FOUND THEN penalty_id := 35; END IF;

    -- Fail if the user has too many longoverdue items
    LOOP
        tmp_grp := user_object.profile;
        LOOP

            SELECT * INTO max_longoverdue 
                FROM permission.grp_penalty_threshold 
                WHERE grp = tmp_grp AND 
                    penalty = penalty_id AND 
                    org_unit = tmp_org.id;

            IF max_longoverdue.threshold IS NULL THEN
                SELECT parent INTO tmp_grp 
                    FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_longoverdue.threshold IS NOT NULL 
                OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT INTO tmp_org * FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_longoverdue.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
            FROM  actor.usr_standing_penalty
            WHERE usr = match_user
                AND org_unit = max_longoverdue.org_unit
                AND (stop_date IS NULL or stop_date > NOW())
                AND standing_penalty IN (35, penalty_id);

        SELECT INTO items_longoverdue COUNT(*)
        FROM action.circulation circ
            JOIN actor.org_unit_full_path( max_longoverdue.org_unit ) fp 
                ON (circ.circ_lib = fp.id)
        WHERE circ.usr = match_user
            AND circ.checkin_time IS NULL
            AND (circ.stop_fines = 'LONGOVERDUE')
            AND xact_finish IS NULL;

        IF items_longoverdue >= max_longoverdue.threshold::INT 
                AND 0 < max_longoverdue.threshold::INT THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_longoverdue.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;


    -- Start over for collections warning
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_COLLECTIONS_WARNING', context_org);
    IF NOT FOUND THEN penalty_id := 4; END IF;

    -- Fail if the user has a collections-level fine balance
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN

        RETURN QUERY
            SELECT  *
              FROM  actor.usr_standing_penalty
              WHERE usr = match_user
                    AND org_unit = max_fines.org_unit
                    AND (stop_date IS NULL or stop_date > NOW())
                    AND standing_penalty IN (4, penalty_id);

        SELECT INTO context_org_list ARRAY_AGG(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND r.xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND g.xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND circ.xact_finish IS NULL ) l USING (id);

        IF current_fines >= max_fines.threshold THEN
            new_sp_row.usr := match_user;
            new_sp_row.org_unit := max_fines.org_unit;
            new_sp_row.standing_penalty := penalty_id;
            RETURN NEXT new_sp_row;
        END IF;
    END IF;

    -- Start over for in collections
    SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_IN_COLLECTIONS', context_org);
    IF NOT FOUND THEN penalty_id := 30; END IF;

    -- Remove the in-collections penalty if the user has paid down enough
    -- This penalty is different, because this code is not responsible for creating 
    -- new in-collections penalties, only for removing them
    LOOP
        tmp_grp := user_object.profile;
        LOOP
            SELECT * INTO max_fines FROM permission.grp_penalty_threshold WHERE grp = tmp_grp AND penalty = penalty_id AND org_unit = tmp_org.id;

            IF max_fines.threshold IS NULL THEN
                SELECT parent INTO tmp_grp FROM permission.grp_tree WHERE id = tmp_grp;
            ELSE
                EXIT;
            END IF;

            IF tmp_grp IS NULL THEN
                EXIT;
            END IF;
        END LOOP;

        IF max_fines.threshold IS NOT NULL OR tmp_org.parent_ou IS NULL THEN
            EXIT;
        END IF;

        SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;

    END LOOP;

    IF max_fines.threshold IS NOT NULL THEN

        SELECT INTO context_org_list ARRAY_AGG(id) FROM actor.org_unit_full_path( max_fines.org_unit );

        -- first, see if the user had paid down to the threshold
        SELECT  SUM(f.balance_owed) INTO current_fines
          FROM  money.materialized_billable_xact_summary f
                JOIN (
                    SELECT  r.id
                      FROM  booking.reservation r
                      WHERE r.usr = match_user
                            AND r.pickup_lib IN (SELECT * FROM unnest(context_org_list))
                            AND r.xact_finish IS NULL
                                UNION ALL
                    SELECT  g.id
                      FROM  money.grocery g
                      WHERE g.usr = match_user
                            AND g.billing_location IN (SELECT * FROM unnest(context_org_list))
                            AND g.xact_finish IS NULL
                                UNION ALL
                    SELECT  circ.id
                      FROM  action.circulation circ
                      WHERE circ.usr = match_user
                            AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                            AND circ.xact_finish IS NULL ) l USING (id);

        IF current_fines IS NULL OR current_fines <= max_fines.threshold THEN
            -- patron has paid down enough

            SELECT INTO tmp_penalty * FROM config.standing_penalty WHERE id = penalty_id;

            IF tmp_penalty.org_depth IS NOT NULL THEN

                -- since this code is not responsible for applying the penalty, it can't 
                -- guarantee the current context org will match the org at which the penalty 
                --- was applied.  search up the org tree until we hit the configured penalty depth
                SELECT INTO tmp_org * FROM actor.org_unit WHERE id = context_org;
                SELECT INTO tmp_depth depth FROM actor.org_unit_type WHERE id = tmp_org.ou_type;

                WHILE tmp_depth >= tmp_penalty.org_depth LOOP

                    RETURN QUERY
                        SELECT  *
                          FROM  actor.usr_standing_penalty
                          WHERE usr = match_user
                                AND org_unit = tmp_org.id
                                AND (stop_date IS NULL or stop_date > NOW())
                                AND standing_penalty IN (30, penalty_id);

                    IF tmp_org.parent_ou IS NULL THEN
                        EXIT;
                    END IF;

                    SELECT * INTO tmp_org FROM actor.org_unit WHERE id = tmp_org.parent_ou;
                    SELECT INTO tmp_depth depth FROM actor.org_unit_type WHERE id = tmp_org.ou_type;
                END LOOP;

            ELSE

                -- no penalty depth is defined, look for exact matches

                RETURN QUERY
                    SELECT  *
                      FROM  actor.usr_standing_penalty
                      WHERE usr = match_user
                            AND org_unit = max_fines.org_unit
                            AND (stop_date IS NULL or stop_date > NOW())
                            AND standing_penalty IN (30, penalty_id);
            END IF;
    
        END IF;

    END IF;

    RETURN;
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION action.item_user_circ_test( circ_ou INT, match_item BIGINT, match_user INT, renewal BOOL ) RETURNS SETOF action.circ_matrix_test_result AS $func$
DECLARE
    user_object             actor.usr%ROWTYPE;
    standing_penalty        config.standing_penalty%ROWTYPE;
    item_object             asset.copy%ROWTYPE;
    item_status_object      config.copy_status%ROWTYPE;
    item_location_object    asset.copy_location%ROWTYPE;
    result                  action.circ_matrix_test_result;
    circ_test               action.found_circ_matrix_matchpoint;
    circ_matchpoint         config.circ_matrix_matchpoint%ROWTYPE;
    circ_limit_set          config.circ_limit_set%ROWTYPE;
    hold_ratio              action.hold_stats%ROWTYPE;
    penalty_type            TEXT;
    penalty_id              INT;
    items_out               INT;
    context_org_list        INT[];
    permit_renew            TEXT;
    done                    BOOL := FALSE;
    item_prox               INT;
    home_prox               INT;
BEGIN
    -- Assume success unless we hit a failure condition
    result.success := TRUE;

    -- Need user info to look up matchpoints
    SELECT INTO user_object * FROM actor.usr WHERE id = match_user AND NOT deleted;

    -- (Insta)Fail if we couldn't find the user
    IF user_object.id IS NULL THEN
        result.fail_part := 'no_user';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    -- Need item info to look up matchpoints
    SELECT INTO item_object * FROM asset.copy WHERE id = match_item AND NOT deleted;

    -- (Insta)Fail if we couldn't find the item
    IF item_object.id IS NULL THEN
        result.fail_part := 'no_item';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    SELECT INTO circ_test * FROM action.find_circ_matrix_matchpoint(circ_ou, item_object, user_object, renewal);

    circ_matchpoint             := circ_test.matchpoint;
    result.matchpoint           := circ_matchpoint.id;
    result.circulate            := circ_matchpoint.circulate;
    result.duration_rule        := circ_matchpoint.duration_rule;
    result.recurring_fine_rule  := circ_matchpoint.recurring_fine_rule;
    result.max_fine_rule        := circ_matchpoint.max_fine_rule;
    result.hard_due_date        := circ_matchpoint.hard_due_date;
    result.renewals             := circ_matchpoint.renewals;
    result.grace_period         := circ_matchpoint.grace_period;
    result.buildrows            := circ_test.buildrows;

    -- (Insta)Fail if we couldn't find a matchpoint
    IF circ_test.success = false THEN
        result.fail_part := 'no_matchpoint';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    -- All failures before this point are non-recoverable
    -- Below this point are possibly overridable failures

    -- Fail if the user is barred
    IF user_object.barred IS TRUE THEN
        result.fail_part := 'actor.usr.barred';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate
    IF item_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item isn't in a circulateable status on a non-renewal
    IF NOT renewal AND item_object.status <> 8 AND item_object.status NOT IN (
        (SELECT id FROM config.copy_status WHERE is_available) ) THEN
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    -- Alternately, fail if the item isn't checked out on a renewal
    ELSIF renewal AND item_object.status <> 1 THEN
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate because of the shelving location
    SELECT INTO item_location_object * FROM asset.copy_location WHERE id = item_object.location;
    IF item_location_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy_location.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Use Circ OU for penalties and such
    SELECT INTO context_org_list ARRAY_AGG(id) FROM actor.org_unit_full_path( circ_ou );

    -- Proximity of user's home_ou to circ_ou to see if penalties should be ignored.
    SELECT INTO home_prox prox FROM actor.org_unit_proximity WHERE from_org = user_object.home_ou AND to_org = circ_ou;

    -- Proximity of user's home_ou to item circ_lib to see if penalties should be ignored.
    SELECT INTO item_prox prox FROM actor.org_unit_proximity WHERE from_org = user_object.home_ou AND to_org = item_object.circ_lib;

    IF renewal THEN
        penalty_type = '%RENEW%';
    ELSE
        penalty_type = '%CIRC%';
    END IF;

    -- Look up any custom override for PATRON_EXCEEDS_FINES penalty
    SELECT BTRIM(value,'"')::INT INTO penalty_id FROM actor.org_unit_ancestor_setting('circ.custom_penalty_override.PATRON_EXCEEDS_FINES', circ_ou);
    IF NOT FOUND THEN penalty_id := 1; END IF;

    FOR standing_penalty IN
        SELECT  DISTINCT csp.*
          FROM  actor.usr_standing_penalty usp
                JOIN config.standing_penalty csp ON (csp.id = usp.standing_penalty)
          WHERE usr = match_user
                AND usp.org_unit IN ( SELECT * FROM unnest(context_org_list) )
                AND (usp.stop_date IS NULL or usp.stop_date > NOW())
                AND (csp.ignore_proximity IS NULL
                     OR csp.ignore_proximity < home_prox
                     OR csp.ignore_proximity < item_prox)
                AND csp.block_list LIKE penalty_type LOOP
        -- override PATRON_EXCEEDS_FINES penalty for renewals based on org setting
        IF renewal AND standing_penalty.id = penalty_id THEN
            SELECT INTO permit_renew value FROM actor.org_unit_ancestor_setting('circ.permit_renew_when_exceeds_fines', circ_ou);
            IF permit_renew IS NOT NULL AND permit_renew ILIKE 'true' THEN
                CONTINUE;
            END IF;
        END IF;

        result.fail_part := standing_penalty.name;
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END LOOP;

    -- Fail if the test is set to hard non-circulating
    IF circ_matchpoint.circulate IS FALSE THEN
        result.fail_part := 'config.circ_matrix_test.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the total copy-hold ratio is too low
    IF circ_matchpoint.total_copy_hold_ratio IS NOT NULL THEN
        SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        IF hold_ratio.total_copy_ratio IS NOT NULL AND hold_ratio.total_copy_ratio < circ_matchpoint.total_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.total_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    -- Fail if the available copy-hold ratio is too low
    IF circ_matchpoint.available_copy_hold_ratio IS NOT NULL THEN
        IF hold_ratio.hold_count IS NULL THEN
            SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        END IF;
        IF hold_ratio.available_copy_ratio IS NOT NULL AND hold_ratio.available_copy_ratio < circ_matchpoint.available_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.available_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    -- Fail if the user has too many items out by defined limit sets
    FOR circ_limit_set IN SELECT ccls.* FROM config.circ_limit_set ccls
      JOIN config.circ_matrix_limit_set_map ccmlsm ON ccmlsm.limit_set = ccls.id
      WHERE ccmlsm.active AND ( ccmlsm.matchpoint = circ_matchpoint.id OR
        ( ccmlsm.matchpoint IN (SELECT * FROM unnest(result.buildrows)) AND ccmlsm.fallthrough )
        ) LOOP
            IF circ_limit_set.items_out > 0 AND NOT renewal THEN
                SELECT INTO context_org_list ARRAY_AGG(aou.id)
                  FROM actor.org_unit_full_path( circ_ou ) aou
                    JOIN actor.org_unit_type aout ON aou.ou_type = aout.id
                  WHERE aout.depth >= circ_limit_set.depth;
                IF circ_limit_set.global THEN
                    WITH RECURSIVE descendant_depth AS (
                        SELECT  ou.id,
                            ou.parent_ou
                        FROM  actor.org_unit ou
                        WHERE ou.id IN (SELECT * FROM unnest(context_org_list))
                            UNION
                        SELECT  ou.id,
                            ou.parent_ou
                        FROM  actor.org_unit ou
                            JOIN descendant_depth ot ON (ot.id = ou.parent_ou)
                    ) SELECT INTO context_org_list ARRAY_AGG(ou.id) FROM actor.org_unit ou JOIN descendant_depth USING (id);
                END IF;
                SELECT INTO items_out COUNT(DISTINCT circ.id)
                  FROM action.circulation circ
                    JOIN asset.copy copy ON (copy.id = circ.target_copy)
                    LEFT JOIN action.circulation_limit_group_map aclgm ON (circ.id = aclgm.circ)
                  WHERE circ.usr = match_user
                    AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                    AND circ.checkin_time IS NULL
                    AND circ.xact_finish IS NULL
                    AND (circ.stop_fines IN ('MAXFINES','LONGOVERDUE') OR circ.stop_fines IS NULL)
                    AND (copy.circ_modifier IN (SELECT circ_mod FROM config.circ_limit_set_circ_mod_map WHERE limit_set = circ_limit_set.id)
                        OR copy.location IN (SELECT copy_loc FROM config.circ_limit_set_copy_loc_map WHERE limit_set = circ_limit_set.id)
                        OR aclgm.limit_group IN (SELECT limit_group FROM config.circ_limit_set_group_map WHERE limit_set = circ_limit_set.id)
                    );
                IF items_out >= circ_limit_set.items_out THEN
                    result.fail_part := 'config.circ_matrix_circ_mod_test';
                    result.success := FALSE;
                    done := TRUE;
                    RETURN NEXT result;
                END IF;
            END IF;
            SELECT INTO result.limit_groups result.limit_groups || ARRAY_AGG(limit_group) FROM config.circ_limit_set_group_map WHERE limit_set = circ_limit_set.id AND NOT check_only;
    END LOOP;

    -- If we passed everything, return the successful matchpoint
    IF NOT done THEN
        RETURN NEXT result;
    END IF;

    RETURN;
END;
$func$ LANGUAGE plpgsql;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1375', :eg_version);

UPDATE action.hold_request 
SET selection_ou = request_lib
WHERE selection_ou NOT IN (
    SELECT id FROM actor.org_unit
);

ALTER TABLE action.hold_request ADD CONSTRAINT hold_request_selection_ou_fkey FOREIGN KEY (selection_ou) REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED NOT VALID;
ALTER TABLE action.hold_request VALIDATE CONSTRAINT hold_request_selection_ou_fkey;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1376', :eg_version);

-- 1236

CREATE OR REPLACE VIEW action.all_circulation_combined_types AS
 SELECT acirc.id AS id,
    acirc.xact_start,
    acirc.circ_lib,
    acirc.circ_staff,
    acirc.create_time,
    ac_acirc.circ_modifier AS item_type,
    'regular_circ'::text AS circ_type
   FROM action.circulation acirc,
    asset.copy ac_acirc
  WHERE acirc.target_copy = ac_acirc.id
UNION ALL
 SELECT ancc.id::BIGINT AS id,
    ancc.circ_time AS xact_start,
    ancc.circ_lib,
    ancc.staff AS circ_staff,
    ancc.circ_time AS create_time,
    cnct_ancc.name AS item_type,
    'non-cat_circ'::text AS circ_type
   FROM action.non_cataloged_circulation ancc,
    config.non_cataloged_type cnct_ancc
  WHERE ancc.item_type = cnct_ancc.id
UNION ALL
 SELECT aihu.id::BIGINT AS id,
    aihu.use_time AS xact_start,
    aihu.org_unit AS circ_lib,
    aihu.staff AS circ_staff,
    aihu.use_time AS create_time,
    ac_aihu.circ_modifier AS item_type,
    'in-house_use'::text AS circ_type
   FROM action.in_house_use aihu,
    asset.copy ac_aihu
  WHERE aihu.item = ac_aihu.id
UNION ALL
 SELECT ancihu.id::BIGINT AS id,
    ancihu.use_time AS xact_start,
    ancihu.org_unit AS circ_lib,
    ancihu.staff AS circ_staff,
    ancihu.use_time AS create_time,
    cnct_ancihu.name AS item_type,
    'non-cat-in-house_use'::text AS circ_type
   FROM action.non_cat_in_house_use ancihu,
    config.non_cataloged_type cnct_ancihu
  WHERE ancihu.item_type = cnct_ancihu.id
UNION ALL
 SELECT aacirc.id AS id,
    aacirc.xact_start,
    aacirc.circ_lib,
    aacirc.circ_staff,
    aacirc.create_time,
    ac_aacirc.circ_modifier AS item_type,
    'aged_circ'::text AS circ_type
   FROM action.aged_circulation aacirc,
    asset.copy ac_aacirc
  WHERE aacirc.target_copy = ac_aacirc.id;

-- 1237

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
SELECT
    'eg.staffcat.exclude_electronic', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.staffcat.exclude_electronic',
        'Staff Catalog "Exclude Electronic Resources" Option',
        'cwst', 'label'
    )
WHERE NOT EXISTS (
    SELECT 1
    FROM config.workstation_setting_type
    WHERE name = 'eg.staffcat.exclude_electronic'
);

-- 1238

INSERT INTO permission.perm_list ( id, code, description ) SELECT
 625, 'VIEW_BOOKING_RESERVATION', oils_i18n_gettext(625,
    'View booking reservations', 'ppl', 'description')
WHERE NOT EXISTS (
    SELECT 1
    FROM permission.perm_list
    WHERE id = 625
    AND   code = 'VIEW_BOOKING_RESERVATION'
);

INSERT INTO permission.perm_list ( id, code, description ) SELECT
 626, 'VIEW_BOOKING_RESERVATION_ATTR_MAP', oils_i18n_gettext(626,
    'View booking reservation attribute maps', 'ppl', 'description')
WHERE NOT EXISTS (
    SELECT 1
    FROM permission.perm_list
    WHERE id = 626
    AND   code = 'VIEW_BOOKING_RESERVATION_ATTR_MAP'
);

-- reprise 1269 just in case now that the perms should definitely exist

WITH perms_to_add AS
    (SELECT id FROM
    permission.perm_list
    WHERE code IN ('VIEW_BOOKING_RESERVATION', 'VIEW_BOOKING_RESERVATION_ATTR_MAP'))

INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
    SELECT grp, perms_to_add.id as perm, depth, grantable
        FROM perms_to_add,
        permission.grp_perm_map
        
        --- Don't add the permissions if they have already been assigned
        WHERE grp NOT IN
            (SELECT DISTINCT grp FROM permission.grp_perm_map
            INNER JOIN perms_to_add ON perm=perms_to_add.id)
            
        --- Anybody who can view resources should also see reservations
        --- at the same level
        AND perm = (
            SELECT id
                FROM permission.perm_list
                WHERE code = 'VIEW_BOOKING_RESOURCE'
        );

-- 1239

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
SELECT
    'eg.grid.booking.pull_list', 'gui', 'object',
    oils_i18n_gettext(
        'booking.pull_list',
        'Grid Config: Booking Pull List',
        'cwst', 'label')
WHERE NOT EXISTS (
    SELECT 1
    FROM config.workstation_setting_type
    WHERE name = 'eg.grid.booking.pull_list'
);

-- 1240

INSERT INTO action_trigger.event_params (event_def, param, value)
SELECT id, 'check_sms_notify', 1
FROM action_trigger.event_definition
WHERE reactor = 'SendSMS'
AND validator IN ('HoldIsAvailable', 'HoldIsCancelled', 'HoldNotifyCheck')
AND NOT EXISTS (
    SELECT * FROM action_trigger.event_params
    WHERE param = 'check_sms_notify'
);

-- fill in the gaps, but only if the upgrade log indicates that
-- this database had been at version 3.6.0 at some point.
INSERT INTO config.upgrade_log (version, applied_to) SELECT '1236', :eg_version
WHERE NOT EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '1236')
AND       EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '3.6.0');
INSERT INTO config.upgrade_log (version, applied_to) SELECT '1237', :eg_version
WHERE NOT EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '1237')
AND       EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '3.6.0');
INSERT INTO config.upgrade_log (version, applied_to) SELECT '1238', :eg_version
WHERE NOT EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '1238')
AND       EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '3.6.0');
INSERT INTO config.upgrade_log (version, applied_to) SELECT '1239', :eg_version
WHERE NOT EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '1239')
AND       EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '3.6.0');
INSERT INTO config.upgrade_log (version, applied_to) SELECT '1240', :eg_version
WHERE NOT EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '1240')
AND       EXISTS (SELECT 1 FROM config.upgrade_log WHERE version = '3.6.0');

COMMIT;
BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1377', :eg_version);

-- 950.data.seed-values.sql

INSERT INTO config.global_flag (name, value, enabled, label)
VALUES (
    'opac.login_redirect_domains',
    '',
    TRUE,
    oils_i18n_gettext(
        'opac.login_redirect_domains',
        'Restrict post-login redirection to local URLs, or those that match the supplied comma-separated list of foreign domains or host names.',
        'cgf', 'label'
    )
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1378', :eg_version);

CREATE OR REPLACE FUNCTION search.highlight_display_fields(
    rid         BIGINT,
    tsq_map     TEXT, -- '(a | b) & c' => '1,2,3,4', ...
    css_class   TEXT DEFAULT 'oils_SH',
    hl_all      BOOL DEFAULT TRUE,
    minwords    INT DEFAULT 5,
    maxwords    INT DEFAULT 25,
    shortwords  INT DEFAULT 0,
    maxfrags    INT DEFAULT 0,
    delimiter   TEXT DEFAULT ' ... '
) RETURNS SETOF search.highlight_result AS $f$
DECLARE
    tsq         TEXT;
    fields      TEXT;
    afields     INT[];
    seen        INT[];
BEGIN

    FOR tsq, fields IN SELECT key, value FROM each(tsq_map::HSTORE) LOOP
        SELECT  ARRAY_AGG(unnest::INT) INTO afields
          FROM  unnest(regexp_split_to_array(fields,','));
        seen := seen || afields;

        RETURN QUERY
            SELECT * FROM search.highlight_display_fields_impl(
                rid, tsq, afields, css_class, hl_all,minwords,
                maxwords, shortwords, maxfrags, delimiter
            );
    END LOOP;

    RETURN QUERY
        SELECT  id,
                source,
                field,
                evergreen.escape_for_html(value) AS value,
                evergreen.escape_for_html(value) AS highlight
          FROM  metabib.display_entry
          WHERE source = rid
                AND NOT (field = ANY (seen));
END;
$f$ LANGUAGE PLPGSQL ROWS 10;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1379', :eg_version);

-- this intentionally does nothing other than inserting the
-- database revision stamp; the only substantive use of 1379
-- is in rel_3_10, but it's important to ensure that anybody
-- applying the individual DB updates doesn't accidentally
-- apply the 1379 change to a 3.11 or later system

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1380', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 644, 'ADMIN_PROXIMITY_ADJUSTMENT', oils_i18n_gettext(644,
    'Allow a user to administer Org Unit Proximity Adjustments', 'ppl', 'description'));

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1381', :eg_version);

CREATE OR REPLACE VIEW action.open_non_cataloged_circulation AS
    SELECT ncc.* 
    FROM action.non_cataloged_circulation ncc
    JOIN config.non_cataloged_type nct ON nct.id = ncc.item_type
    WHERE ncc.circ_time + nct.circ_duration > CURRENT_TIMESTAMP
;

COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1382', :eg_version); -- JBoyer / smorrison

-- Remove previous acpl 1 protection
DROP RULE protect_acl_id_1 ON asset.copy_location;

-- Ensure that the owning_lib is set to CONS (equivalent), *should* be a noop.
UPDATE asset.copy_location SET owning_lib = (SELECT id FROM actor.org_unit_ancestor_at_depth(owning_lib,0)) WHERE id = 1;

CREATE OR REPLACE FUNCTION asset.check_delete_copy_location(acpl_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM TRUE FROM asset.copy WHERE location = acpl_id AND NOT deleted LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Copy location % contains active copies and cannot be deleted', acpl_id;
    END IF;
    
    IF acpl_id = 1 THEN
        RAISE EXCEPTION
            'Copy location 1 cannot be deleted';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION asset.copy_location_validate_edit()
  RETURNS trigger
  LANGUAGE plpgsql
AS $function$
BEGIN
    IF OLD.id = 1 THEN
        IF OLD.owning_lib != NEW.owning_lib OR NEW.deleted THEN
            RAISE EXCEPTION 'Copy location 1 cannot be moved or deleted';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER acpl_validate_edit BEFORE UPDATE ON asset.copy_location FOR EACH ROW EXECUTE PROCEDURE asset.copy_location_validate_edit();

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1383', :eg_version);

DROP INDEX IF EXISTS asset.cp_available_by_circ_lib_idx;

DROP INDEX IF EXISTS serial.unit_available_by_circ_lib_idx;

CREATE INDEX cp_extant_by_circ_lib_idx ON asset.copy(circ_lib) WHERE deleted = FALSE OR deleted IS FALSE;

CREATE INDEX unit_extant_by_circ_lib_idx ON serial.unit(circ_lib) WHERE deleted = FALSE OR deleted IS FALSE;

CREATE OR REPLACE FUNCTION action.copy_related_hold_stats (copy_id BIGINT) RETURNS action.hold_stats AS $func$
DECLARE
    output          action.hold_stats%ROWTYPE;
    hold_count      INT := 0;
    copy_count      INT := 0;
    available_count INT := 0;
    hold_map_data   RECORD;
BEGIN

    output.hold_count := 0;
    output.copy_count := 0;
    output.available_count := 0;

    SELECT  COUNT( DISTINCT m.hold ) INTO hold_count
      FROM  action.hold_copy_map m
            JOIN action.hold_request h ON (m.hold = h.id)
      WHERE m.target_copy = copy_id
            AND NOT h.frozen;

    output.hold_count := hold_count;

    IF output.hold_count > 0 THEN
        FOR hold_map_data IN
            SELECT  DISTINCT m.target_copy,
                    acp.status
              FROM  action.hold_copy_map m
                    JOIN asset.copy acp ON (m.target_copy = acp.id)
                    JOIN action.hold_request h ON (m.hold = h.id)
              WHERE m.hold IN ( SELECT DISTINCT hold FROM action.hold_copy_map WHERE target_copy = copy_id ) AND NOT h.frozen
        LOOP
            output.copy_count := output.copy_count + 1;
            IF hold_map_data.status IN (SELECT id from config.copy_status where holdable and is_available) THEN
                output.available_count := output.available_count + 1;
            END IF;
        END LOOP;
        output.total_copy_ratio = output.copy_count::FLOAT / output.hold_count::FLOAT;
        output.available_copy_ratio = output.available_count::FLOAT / output.hold_count::FLOAT;

    END IF;

    RETURN output;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION asset.staff_lasso_record_copy_count (i_lasso INT, rid BIGINT) RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT) AS $f$
DECLARE
    ans RECORD;
    trans INT;
BEGIN
    SELECT 1 INTO trans FROM biblio.record_entry b JOIN config.bib_source src ON (b.source = src.id) WHERE src.transcendant AND b.id = rid;

    FOR ans IN SELECT u.org_unit AS id FROM actor.org_lasso_map AS u WHERE lasso = i_lasso LOOP
        RETURN QUERY
        SELECT  -1,
                ans.id,
                COUNT( cp.id ),
                SUM( CASE WHEN cp.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available)
                   THEN 1 ELSE 0 END ),
                SUM( CASE WHEN cl.opac_visible AND cp.opac_visible THEN 1 ELSE 0 END),
                trans
          FROM
                actor.org_unit_descendants(ans.id) d
                JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
                JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
                JOIN asset.call_number cn ON (cn.record = rid AND cn.id = cp.call_number AND NOT cn.deleted)
          GROUP BY 1,2,6;

        IF NOT FOUND THEN
            RETURN QUERY SELECT -1, ans.id, 0::BIGINT, 0::BIGINT, 0::BIGINT, trans;
        END IF;

    END LOOP;

    RETURN;
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION asset.staff_ou_metarecord_copy_count (org INT, rid BIGINT) RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT) AS $f$
DECLARE
    ans RECORD;
    trans INT;
BEGIN
    SELECT 1 INTO trans FROM biblio.record_entry b JOIN config.bib_source src ON (b.source = src.id) JOIN metabib.metarecord_source_map m ON (m.source = b.id) WHERE src.transcendant AND m.metarecord = rid;

    FOR ans IN SELECT u.id, t.depth FROM actor.org_unit_ancestors(org) AS u JOIN actor.org_unit_type t ON (u.ou_type = t.id) LOOP
        RETURN QUERY
        SELECT  ans.depth,
                ans.id,
                COUNT( cp.id ),
                SUM( CASE WHEN cp.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available) THEN 1 ELSE 0 END ),
                COUNT( cp.id ),
                trans
          FROM
                actor.org_unit_descendants(ans.id) d
                JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
                JOIN asset.call_number cn ON (cn.id = cp.call_number AND NOT cn.deleted)
                JOIN metabib.metarecord_source_map m ON (m.metarecord = rid AND m.source = cn.record)
          GROUP BY 1,2,6;

        IF NOT FOUND THEN
            RETURN QUERY SELECT ans.depth, ans.id, 0::BIGINT, 0::BIGINT, 0::BIGINT, trans;
        END IF;

    END LOOP;

    RETURN;
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION asset.staff_lasso_metarecord_copy_count (i_lasso INT, rid BIGINT) RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT) AS $f$
DECLARE
    ans RECORD;
    trans INT;
BEGIN
    SELECT 1 INTO trans FROM biblio.record_entry b JOIN config.bib_source src ON (b.source = src.id) JOIN metabib.metarecord_source_map m ON (m.source = b.id) WHERE src.transcendant AND m.metarecord = rid;

    FOR ans IN SELECT u.org_unit AS id FROM actor.org_lasso_map AS u WHERE lasso = i_lasso LOOP
        RETURN QUERY
        SELECT  -1,
                ans.id,
                COUNT( cp.id ),
                SUM( CASE WHEN cp.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available) THEN 1 ELSE 0 END ),
                COUNT( cp.id ),
                trans
          FROM
                actor.org_unit_descendants(ans.id) d
                JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
                JOIN asset.call_number cn ON (cn.id = cp.call_number AND NOT cn.deleted)
                JOIN metabib.metarecord_source_map m ON (m.metarecord = rid AND m.source = cn.record)
          GROUP BY 1,2,6;

        IF NOT FOUND THEN
            RETURN QUERY SELECT ans.depth, ans.id, 0::BIGINT, 0::BIGINT, 0::BIGINT, trans;
        END IF;

    END LOOP;

    RETURN;
END;
$f$ LANGUAGE PLPGSQL;


COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1384', :eg_version); -- dbriem, berick, tmccanna

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.holds.pull_list_filters', 'gui', 'object',
    oils_i18n_gettext(
        'eg.holds.pull_list_filters',
        'Holds pull list filter values for pickup library and shelving locations.',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1385', :eg_version); -- mmorgan, rfrasur, tmccanna

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 645, 'ADMIN_USER_BUCKET', oils_i18n_gettext(645,
    'Allow a user to administer User Buckets', 'ppl', 'description'));
INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 646, 'CREATE_USER_BUCKET', oils_i18n_gettext(646,
    'Allow a user to create a User Bucket', 'ppl', 'description'));

INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
        SELECT
                pgt.id, perm.id, aout.depth, FALSE
        FROM
                permission.grp_tree pgt,
                permission.perm_list perm,
                actor.org_unit_type aout
        WHERE
                pgt.name = 'Circulators' AND
                aout.name = 'System' AND
                perm.code IN (
                        'ADMIN_USER_BUCKET',
                        'CREATE_USER_BUCKET');

INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
        SELECT
                pgt.id, perm.id, aout.depth, FALSE
        FROM
                permission.grp_tree pgt,
                permission.perm_list perm,
                actor.org_unit_type aout
        WHERE
                pgt.name = 'Circulation Administrator' AND
                aout.name = 'System' AND
                perm.code IN (
                        'ADMIN_USER_BUCKET',
                        'CREATE_USER_BUCKET');

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1386', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) VALUES (
    647, 'UPDATE_ADDED_CONTENT_URL',
    oils_i18n_gettext(647, 'Update the NoveList added-content javascript URL', 'ppl', 'description')
);

-- Note: see local.syndetics_id as precedence for not requiring view or update perms for credentials

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'staff.added_content.novelistselect.version',
    'gui',
    oils_i18n_gettext('staff.added_content.novelistselect.version',
        'Staff Client added content: NoveList Select API version',
        'coust', 'label'),
    oils_i18n_gettext('staff.added_content.novelistselect.version',
        'API version used to provide NoveList Select added content in the Staff Client',
        'coust', 'description'),
    'string'
);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'staff.added_content.novelistselect.profile',
    'gui',
    oils_i18n_gettext('staff.added_content.novelistselect.profile',
        'Staff Client added content: NoveList Select profile/user',
        'coust', 'label'),
    oils_i18n_gettext('staff.added_content.novelistselect.profile',
        'Profile/user used to provide NoveList Select added content in the Staff Client',
        'coust', 'description'),
    'string'
);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'staff.added_content.novelistselect.passwd',
    'gui',
    oils_i18n_gettext('staff.added_content.novelistselect.passwd',
        'Staff Client added content: NoveList Select key/password',
        'coust', 'label'),
    oils_i18n_gettext('staff.added_content.novelistselect.passwd',
        'Key/password used to provide NoveList Select added content in the Staff Client',
        'coust', 'description'),
    'string'
);

INSERT into config.org_unit_setting_type
    (name, datatype, grp, update_perm, label, description)
VALUES (
    'staff.added_content.novelistselect.url', 'string', 'opac', 647,
    oils_i18n_gettext(
        'staff.added_content.novelistselect.url',
        'URL Override for NoveList Select added content javascript',
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'staff.added_content.novelistselect.url',
        'URL Override for NoveList Select added content javascript',
        'coust', 'description'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1387', :eg_version);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'opac.uri_default_note_text', 'opac',
    oils_i18n_gettext('opac.uri_default_note_text',
        'Default text to appear for 856 links if none is present',
        'coust', 'label'),
    oils_i18n_gettext('opac.uri_default_note_text',
        'When no value is present in the 856$z this string will be used instead',
        'coust', 'description'),
    'string', null)
;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1388', :eg_version);

UPDATE action_trigger.event_definition
SET delay = '-24:01:00'::INTERVAL
WHERE reactor = 'Circ::AutoRenew'
AND delay = '-23 hours'::INTERVAL
AND max_delay = '-1 minute'::INTERVAL;


COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1389', :eg_version);

ALTER TABLE acq.provider ADD COLUMN buyer_san TEXT;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1390', :eg_version);

ALTER TABLE actor.org_unit_custom_tree_node
DROP CONSTRAINT org_unit_custom_tree_node_parent_node_fkey;

ALTER TABLE actor.org_unit_custom_tree_node
ADD CONSTRAINT org_unit_custom_tree_node_parent_node_fkey 
FOREIGN KEY (parent_node) 
REFERENCES actor.org_unit_custom_tree_node(id) 
ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1391', :eg_version);

DROP FUNCTION IF EXISTS evergreen.find_next_open_time(INT, TIMESTAMPTZ, BOOL, TIME, INT); --Get rid of the last version of this function with different arguments so it doesn't cause conflicts when calling it
CREATE OR REPLACE FUNCTION evergreen.find_next_open_time ( circ_lib INT, initial TIMESTAMPTZ, hourly BOOL DEFAULT FALSE, initial_time TIME DEFAULT NULL, has_hoo BOOL DEFAULT TRUE )
    RETURNS TIMESTAMPTZ AS $$
DECLARE
    day_number      INT;
    plus_days       INT;
    final_time      TEXT;
    time_adjusted   BOOL;
    hoo_open        TIME WITHOUT TIME ZONE;
    hoo_close       TIME WITHOUT TIME ZONE;
    adjacent        actor.org_unit_closed%ROWTYPE;
    breakout        INT := 0;
BEGIN

    IF initial_time IS NULL THEN
        initial_time := initial::TIME;
    END IF;

    final_time := (initial + '1 second'::INTERVAL)::TEXT;
    LOOP
        breakout := breakout + 1;

        time_adjusted := FALSE;

        IF has_hoo THEN -- Don't check hours if they have no hoo. I think the behavior in that case is that we act like they're always open? Better than making things due in 2 years.
                        -- Don't expect anyone to call this with it set to false; it's just for our own recursive use.
            day_number := EXTRACT(ISODOW FROM final_time::TIMESTAMPTZ) - 1; --Get which day of the week  it is from which it started on.
            plus_days := 0;
            has_hoo := FALSE; -- set has_hoo to false to check if any days are open (for the first recursion where it's always true)
            FOR i IN 1..7 LOOP
                EXECUTE 'SELECT dow_' || day_number || '_open, dow_' || day_number || '_close FROM actor.hours_of_operation WHERE id = $1'
                    INTO hoo_open, hoo_close
                    USING circ_lib;

                -- RAISE NOTICE 'initial time: %; dow: %; close: %',initial_time,day_number,hoo_close;

                IF hoo_close = '00:00:00' THEN -- bah ... I guess we'll check the next day
                    day_number := (day_number + 1) % 7;
                    plus_days := plus_days + 1;
                    time_adjusted := TRUE;
                    CONTINUE;
                ELSE
                    has_hoo := TRUE; --We do have hours open sometimes, yay!
                END IF;

                IF hoo_close IS NULL THEN -- no hours of operation ... assume no closing?
                    hoo_close := '23:59:59';
                END IF;

                EXIT;
            END LOOP;

            IF NOT has_hoo THEN -- If always closed then forget the extra days - just determine based on closures.
                plus_days := 0;
            END IF;

            final_time := DATE(final_time::TIMESTAMPTZ + (plus_days || ' days')::INTERVAL)::TEXT;
            IF hoo_close <> '00:00:00' AND hourly THEN -- Not a day-granular circ
                final_time := final_time||' '|| hoo_close;
            ELSE
                final_time := final_time||' 23:59:59';
            END IF;
        END IF;

        --RAISE NOTICE 'final_time: %',final_time;

        -- Loop through other closings
        LOOP 
            SELECT * INTO adjacent FROM actor.org_unit_closed WHERE org_unit = circ_lib AND final_time::TIMESTAMPTZ between close_start AND close_end;
            EXIT WHEN adjacent.id IS NULL;
            time_adjusted := TRUE;
            -- RAISE NOTICE 'recursing for closings with final_time: %',final_time;
            final_time := evergreen.find_next_open_time(circ_lib, adjacent.close_end::TIMESTAMPTZ, hourly, initial_time, has_hoo)::TEXT;
        END LOOP;

        EXIT WHEN breakout > 100;
        EXIT WHEN NOT time_adjusted;

    END LOOP;

    RETURN final_time;
END;
$$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1392', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.acq.fiscal_calendar', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.acq.fiscal_calendar',
        'Grid Config: eg.grid.admin.acq.fiscal_calendar',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.acq.fiscal_year', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.acq.fiscal_year',
        'Grid Config: eg.grid.admin.acq.fiscal_year',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1393', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.staffcat.course_materials_selector', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.staffcat.course_materials_selector',
        'Add the "Reserves material" dropdown to refine search results',
        'cwst', 'label'
    )
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1394', :eg_version);

ALTER TABLE url_verify.url_selector
    DROP CONSTRAINT url_selector_session_fkey,
    ADD CONSTRAINT url_selector_session_fkey 
        FOREIGN KEY (session) 
        REFERENCES url_verify.session(id) 
        ON UPDATE CASCADE
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE url_verify.url
    DROP CONSTRAINT url_session_fkey,
    DROP CONSTRAINT url_redirect_from_fkey,
    ADD CONSTRAINT url_session_fkey 
        FOREIGN KEY (session) 
        REFERENCES url_verify.session(id) 
        ON UPDATE CASCADE
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT url_redirect_from_fkey
        FOREIGN KEY (redirect_from)
        REFERENCES url_verify.url(id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE url_verify.verification_attempt
    DROP CONSTRAINT verification_attempt_session_fkey,
    ADD CONSTRAINT verification_attempt_session_fkey 
        FOREIGN KEY (session) 
        REFERENCES url_verify.session(id) 
        ON UPDATE CASCADE
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE url_verify.url_verification
    DROP CONSTRAINT url_verification_url_fkey,
    ADD CONSTRAINT url_verification_url_fkey
        FOREIGN KEY (url)
        REFERENCES url_verify.url(id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED;

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.catalog.link_checker', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.link_checker',
        'Grid Config: catalog.link_checker',
        'cwst', 'label'
    )
), (
    'eg.grid.catalog.link_checker.attempt', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.link_checker.attempt',
        'Grid Config: catalog.link_checker.attempt',
        'cwst', 'label'
    )
), (
    'eg.grid.catalog.link_checker.url', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.link_checker.url',
        'Grid Config: catalog.link_checker.url',
        'cwst', 'label'
    )
), (
    'eg.grid.filters.catalog.link_checker', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.filters.catalog.link_checker',
        'Grid Filter Sets: catalog.link_checker',
        'cwst', 'label'
    )
), (
    'eg.grid.filters.catalog.link_checker.attempt', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.filters.catalog.link_checker.attempt',
        'Grid Filter Sets: catalog.link_checker.attempt',
        'cwst', 'label'
    )
), (
    'eg.grid.filters.catalog.link_checker.url', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.filters.catalog.link_checker.url',
        'Grid Filter Sets: catalog.link_checker.url',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1395', :eg_version);

DELETE FROM actor.org_unit_setting WHERE name IN (
    'opac.did_you_mean.low_result_threshold',
    'opac.did_you_mean.max_suggestions',
    'search.symspell.keyboard_distance.weight',
    'search.symspell.min_suggestion_use_threshold',
    'search.symspell.pg_trgm.weight',
    'search.symspell.soundex.weight'
);

DELETE FROM config.org_unit_setting_type WHERE name IN (
    'opac.did_you_mean.low_result_threshold',
    'opac.did_you_mean.max_suggestions',
    'search.symspell.keyboard_distance.weight',
    'search.symspell.min_suggestion_use_threshold',
    'search.symspell.pg_trgm.weight',
    'search.symspell.soundex.weight'
);

DELETE FROM config.org_unit_setting_type_log WHERE field_name IN (
    'opac.did_you_mean.low_result_threshold',
    'opac.did_you_mean.max_suggestions',
    'search.symspell.keyboard_distance.weight',
    'search.symspell.min_suggestion_use_threshold',
    'search.symspell.pg_trgm.weight',
    'search.symspell.soundex.weight'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1396', :eg_version);

DELETE FROM config.record_attr_definition
WHERE name = 'on_reserve';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1397', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.actor.stat_cat', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.actor.stat_cat',
        'Grid Config: admin.local.actor.stat_cat',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.local.asset.stat_cat', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.asset.stat_cat',
        'Grid Config: admin.local.asset.stat_cat',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1398', :eg_version);

CREATE OR REPLACE FUNCTION search.symspell_lookup(
    raw_input       TEXT,
    search_class    TEXT,
    verbosity       INT DEFAULT NULL,
    xfer_case       BOOL DEFAULT NULL,
    count_threshold INT DEFAULT NULL,
    soundex_weight  INT DEFAULT NULL,
    pg_trgm_weight  INT DEFAULT NULL,
    kbdist_weight   INT DEFAULT NULL
) RETURNS SETOF search.symspell_lookup_output AS $F$
DECLARE
    prefix_length INT;
    maxED         INT;
    good_suggs  HSTORE;
    word_list   TEXT[];
    edit_list   TEXT[] := '{}';
    seen_list   TEXT[] := '{}';
    output      search.symspell_lookup_output;
    output_list search.symspell_lookup_output[];
    entry       RECORD;
    entry_key   TEXT;
    prefix_key  TEXT;
    sugg        TEXT;
    input       TEXT;
    word        TEXT;
    w_pos       INT := -1;
    smallest_ed INT := -1;
    global_ed   INT;
    c_symspell_suggestion_verbosity INT;
    c_min_suggestion_use_threshold  INT;
    c_soundex_weight                INT;
    c_pg_trgm_weight                INT;
    c_keyboard_distance_weight      INT;
    c_symspell_transfer_case        BOOL;
BEGIN

    SELECT  cmc.min_suggestion_use_threshold,
            cmc.soundex_weight,
            cmc.pg_trgm_weight,
            cmc.keyboard_distance_weight,
            cmc.symspell_transfer_case,
            cmc.symspell_suggestion_verbosity
      INTO  c_min_suggestion_use_threshold,
            c_soundex_weight,
            c_pg_trgm_weight,
            c_keyboard_distance_weight,
            c_symspell_transfer_case,
            c_symspell_suggestion_verbosity
      FROM  config.metabib_class cmc
      WHERE cmc.name = search_class;

    c_min_suggestion_use_threshold := COALESCE(count_threshold,c_min_suggestion_use_threshold);
    c_symspell_transfer_case := COALESCE(xfer_case,c_symspell_transfer_case);
    c_symspell_suggestion_verbosity := COALESCE(verbosity,c_symspell_suggestion_verbosity);
    c_soundex_weight := COALESCE(soundex_weight,c_soundex_weight);
    c_pg_trgm_weight := COALESCE(pg_trgm_weight,c_pg_trgm_weight);
    c_keyboard_distance_weight := COALESCE(kbdist_weight,c_keyboard_distance_weight);

    SELECT value::INT INTO prefix_length FROM config.internal_flag WHERE name = 'symspell.prefix_length' AND enabled;
    prefix_length := COALESCE(prefix_length, 6);

    SELECT value::INT INTO maxED FROM config.internal_flag WHERE name = 'symspell.max_edit_distance' AND enabled;
    maxED := COALESCE(maxED, 3);

    -- XXX This should get some more thought ... maybe search_normalize?
    word_list := ARRAY_AGG(x.word) FROM search.query_parse_positions(raw_input) x;

    -- Common case exact match test for preformance
    IF c_symspell_suggestion_verbosity = 0 AND CARDINALITY(word_list) = 1 AND CHARACTER_LENGTH(word_list[1]) <= prefix_length THEN
        EXECUTE
          'SELECT  '||search_class||'_suggestions AS suggestions,
                   '||search_class||'_count AS count,
                   prefix_key
             FROM  search.symspell_dictionary
             WHERE prefix_key = $1
                   AND '||search_class||'_count >= $2 
                   AND '||search_class||'_suggestions @> ARRAY[$1]' 
          INTO entry USING evergreen.lowercase(word_list[1]), c_min_suggestion_use_threshold;
        IF entry.prefix_key IS NOT NULL THEN
            output.lev_distance := 0; -- definitionally
            output.prefix_key := entry.prefix_key;
            output.prefix_key_count := entry.count;
            output.suggestion_count := entry.count;
            output.input := word_list[1];
            IF c_symspell_transfer_case THEN
                output.suggestion := search.symspell_transfer_casing(output.input, entry.prefix_key);
            ELSE
                output.suggestion := entry.prefix_key;
            END IF;
            output.norm_input := entry.prefix_key;
            output.qwerty_kb_match := 1;
            output.pg_trgm_sim := 1;
            output.soundex_sim := 1;
            RETURN NEXT output;
            RETURN;
        END IF;
    END IF;

    <<word_loop>>
    FOREACH word IN ARRAY word_list LOOP
        w_pos := w_pos + 1;
        input := evergreen.lowercase(word);

        IF CHARACTER_LENGTH(input) > prefix_length THEN
            prefix_key := SUBSTRING(input FROM 1 FOR prefix_length);
            edit_list := ARRAY[input,prefix_key] || search.symspell_generate_edits(prefix_key, 1, maxED);
        ELSE
            edit_list := input || search.symspell_generate_edits(input, 1, maxED);
        END IF;

        SELECT ARRAY_AGG(x ORDER BY CHARACTER_LENGTH(x) DESC) INTO edit_list FROM UNNEST(edit_list) x;

        output_list := '{}';
        seen_list := '{}';
        global_ed := NULL;

        <<entry_key_loop>>
        FOREACH entry_key IN ARRAY edit_list LOOP
            smallest_ed := -1;
            IF global_ed IS NOT NULL THEN
                smallest_ed := global_ed;
            END IF;
            FOR entry IN EXECUTE
                'SELECT  '||search_class||'_suggestions AS suggestions,
                         '||search_class||'_count AS count,
                         prefix_key
                   FROM  search.symspell_dictionary
                   WHERE prefix_key = $1
                         AND '||search_class||'_suggestions IS NOT NULL' 
                USING entry_key
            LOOP

                SELECT  HSTORE(
                            ARRAY_AGG(
                                ARRAY[s, evergreen.levenshtein_damerau_edistance(input,s,maxED)::TEXT]
                                    ORDER BY evergreen.levenshtein_damerau_edistance(input,s,maxED) ASC
                            )
                        )
                  INTO  good_suggs
                  FROM  UNNEST(entry.suggestions) s
                  WHERE (ABS(CHARACTER_LENGTH(s) - CHARACTER_LENGTH(input)) <= maxEd
                        AND evergreen.levenshtein_damerau_edistance(input,s,maxED) BETWEEN 0 AND maxED)
                        AND NOT seen_list @> ARRAY[s];

                CONTINUE WHEN good_suggs IS NULL;

                FOR sugg, output.suggestion_count IN EXECUTE
                    'SELECT  prefix_key, '||search_class||'_count
                       FROM  search.symspell_dictionary
                       WHERE prefix_key = ANY ($1)
                             AND '||search_class||'_count >= $2'
                    USING AKEYS(good_suggs), c_min_suggestion_use_threshold
                LOOP

                    IF NOT seen_list @> ARRAY[sugg] THEN
                        output.lev_distance := good_suggs->sugg;
                        seen_list := seen_list || sugg;

                        -- Track the smallest edit distance among suggestions from this prefix key.
                        IF smallest_ed = -1 OR output.lev_distance < smallest_ed THEN
                            smallest_ed := output.lev_distance;
                        END IF;

                        -- Track the smallest edit distance for all prefix keys for this word.
                        IF global_ed IS NULL OR smallest_ed < global_ed THEN
                            global_ed = smallest_ed;
                        END IF;

                        -- Only proceed if the edit distance is <= the max for the dictionary.
                        IF output.lev_distance <= maxED THEN
                            IF output.lev_distance > global_ed AND c_symspell_suggestion_verbosity <= 1 THEN
                                -- Lev distance is our main similarity measure. While
                                -- trgm or soundex similarity could be the main filter,
                                -- Lev is both language agnostic and faster.
                                --
                                -- Here we will skip suggestions that have a longer edit distance
                                -- than the shortest we've already found. This is simply an
                                -- optimization that allows us to avoid further processing
                                -- of this entry. It would be filtered out later.

                                CONTINUE;
                            END IF;

                            -- If we have an exact match on the suggestion key we can also avoid
                            -- some function calls.
                            IF output.lev_distance = 0 THEN
                                output.qwerty_kb_match := 1;
                                output.pg_trgm_sim := 1;
                                output.soundex_sim := 1;
                            ELSE
                                output.qwerty_kb_match := evergreen.qwerty_keyboard_distance_match(input, sugg);
                                output.pg_trgm_sim := similarity(input, sugg);
                                output.soundex_sim := difference(input, sugg) / 4.0;
                            END IF;

                            -- Fill in some fields
                            IF c_symspell_transfer_case THEN
                                output.suggestion := search.symspell_transfer_casing(word, sugg);
                            ELSE
                                output.suggestion := sugg;
                            END IF;
                            output.prefix_key := entry.prefix_key;
                            output.prefix_key_count := entry.count;
                            output.input := word;
                            output.norm_input := input;
                            output.word_pos := w_pos;

                            -- We can't "cache" a set of generated records directly, so
                            -- here we build up an array of search.symspell_lookup_output
                            -- records that we can revivicate later as a table using UNNEST().
                            output_list := output_list || output;

                            EXIT entry_key_loop WHEN smallest_ed = 0 AND c_symspell_suggestion_verbosity = 0; -- exact match early exit
                            CONTINUE entry_key_loop WHEN smallest_ed = 0 AND c_symspell_suggestion_verbosity = 1; -- exact match early jump to the next key
                        END IF; -- maxED test
                    END IF; -- suggestion not seen test
                END LOOP; -- loop over suggestions
            END LOOP; -- loop over entries
        END LOOP; -- loop over entry_keys

        -- Now we're done examining this word
        IF c_symspell_suggestion_verbosity = 0 THEN
            -- Return the "best" suggestion from the smallest edit
            -- distance group.  We define best based on the weighting
            -- of the non-lev similarity measures and use the suggestion
            -- use count to break ties.
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC
                        LIMIT 1;
        ELSIF c_symspell_suggestion_verbosity = 1 THEN
            -- Return all suggestions from the smallest
            -- edit distance group.
            RETURN QUERY
                SELECT * FROM UNNEST(output_list) WHERE lev_distance = smallest_ed
                    ORDER BY (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 2 THEN
            -- Return everything we find, along with relevant stats
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 3 THEN
            -- Return everything we find from the two smallest edit distance groups
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    WHERE lev_distance IN (SELECT DISTINCT lev_distance FROM UNNEST(output_list) ORDER BY 1 LIMIT 2)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        ELSIF c_symspell_suggestion_verbosity = 4 THEN
            -- Return everything we find from the two smallest edit distance groups that are NOT 0 distance
            RETURN QUERY
                SELECT * FROM UNNEST(output_list)
                    WHERE lev_distance IN (SELECT DISTINCT lev_distance FROM UNNEST(output_list) WHERE lev_distance > 0 ORDER BY 1 LIMIT 2)
                    ORDER BY lev_distance,
                        (soundex_sim * c_soundex_weight)
                            + (pg_trgm_sim * c_pg_trgm_weight)
                            + (qwerty_kb_match * c_keyboard_distance_weight) DESC,
                        suggestion_count DESC;
        END IF;
    END LOOP; -- loop over words
END;
$F$ LANGUAGE PLPGSQL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1399', :eg_version);

ALTER TABLE asset.copy_template DROP CONSTRAINT valid_fine_level;
ALTER TABLE asset.copy_template ADD CONSTRAINT valid_fine_level
      CHECK (fine_level IS NULL OR fine_level IN (1,2,3));

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1400', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.actor.stat_cat_entry', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.actor.stat_cat_entry',
        'Grid Config: admin.local.actor.stat_cat_entry',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.local.asset.stat_cat_entry', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.asset.stat_cat_entry',
        'Grid Config: admin.local.asset.stat_cat_entry',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1401', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
  648,
  'ADMIN_BIB_BUCKET',
  oils_i18n_gettext(648,
    'Administer bibliographic record buckets', 'ppl', 'description'
  )
  FROM permission.perm_list
  WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_BIB_BUCKET');
 
INSERT INTO permission.perm_list ( id, code, description )  SELECT DISTINCT
  649,
  'CREATE_BIB_BUCKET',
  oils_i18n_gettext(649,
    'Create bibliographic record buckets', 'ppl', 'description'
  )
  FROM permission.perm_list
  WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'CREATE_BIB_BUCKET');

COMMIT;BEGIN;

SELECT evergreen.upgrade_deps_block_check('1402', :eg_version);

INSERT INTO config.org_unit_setting_type (
  name, grp, label, description, datatype
) VALUES (
  'cat.patron_view_discovery_layer_url',
  'cat',
  oils_i18n_gettext(
    'cat.patron_view_discovery_layer_url',
    'Patron view discovery layer URL',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'cat.patron_view_discovery_layer_url',
    'URL for displaying an item in the "patron view" discovery layer with a placeholder for the bib record ID: {eg_record_id}. For example: https://example.com/Record/{eg_record_id}',
    'coust',
    'description'
  ),
  'string'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1403', :eg_version);

UPDATE action_trigger.event_definition SET template = 

$$
[%-
# target is the book list itself. The 'items' variable does not need to be in
# the environment because a special reactor will take care of filling it in.

FOR item IN items;
    bibxml = helpers.unapi_bre(item.target_biblio_record_entry, {flesh => '{mra}'});
    title = "";
    FOR part IN bibxml.findnodes('//*[@tag="245"]/*[@code="a" or @code="b" or @code="n" or @code="p"]');
        title = title _ part.textContent;
    END;
    author = bibxml.findnodes('//*[@tag="100"]/*[@code="a"]').textContent;
    item_type = bibxml.findnodes('//*[local-name()="attributes"]/*[local-name()="field"][@name="item_type"]').getAttribute('coded-value');
    pub_date = "";
    FOR pdatum IN bibxml.findnodes('//*[@tag="260"]/*[@code="c"]');
        IF pub_date ;
            pub_date = pub_date _ ", " _ pdatum.textContent;
        ELSE ;
            pub_date = pdatum.textContent;
        END;
    END;
    helpers.csv_datum(title) %],[% helpers.csv_datum(author) %],[% helpers.csv_datum(pub_date) %],[% helpers.csv_datum(item_type) %],[% FOR note IN item.notes; helpers.csv_datum(note.note); ","; END; "\n";
END -%]
$$

WHERE hook = 'container.biblio_record_entry_bucket.csv' AND MD5(template) = '386d7ab2a78a69a44a47e2b0b8c5699b';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1404', :eg_version);

UPDATE config.org_unit_setting_type
SET description = oils_i18n_gettext('acq.default_owning_lib_for_auto_lids_strategy',
        'Strategy to use when setting the default owning library for line item items that are auto-created due to the provider''s default copy count being set. Valid values are "workstation" to use the workstation library, "blank" to leave it blank, and "use_setting" to use the "Default owning library for auto-created line item items" setting. If not set, the workstation library will be used.',
        'coust', 'description')
WHERE name = 'acq.default_owning_lib_for_auto_lids_strategy'
AND description = 'Stategy to use to set default owning library to set when line item items are auto-created because the provider''s default copy count has been set. Valid values are "workstation" to use the workstation library, "blank" to leave it blank, and "use_setting" to use the "Default owning library for auto-created line item items" setting. If not set, the workstation library will be used.';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1405', :eg_version);

ALTER TABLE action.hold_request 
ADD COLUMN canceled_by INT REFERENCES actor.usr (id) DEFERRABLE INITIALLY DEFERRED,
ADD COLUMN canceling_ws INT REFERENCES actor.workstation (id) DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX hold_request_canceled_by_idx ON action.hold_request (canceled_by);
CREATE INDEX hold_request_canceling_ws_idx ON action.hold_request (canceling_ws);

CREATE OR REPLACE FUNCTION actor.usr_merge( src_usr INT, dest_usr INT, del_addrs BOOLEAN, del_cards BOOLEAN, deactivate_cards BOOLEAN ) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	bucket_row RECORD;
	picklist_row RECORD;
	queue_row RECORD;
	folder_row RECORD;
BEGIN

    -- Bail if src_usr equals dest_usr because the result of merging a
    -- user with itself is not what you want.
    IF src_usr = dest_usr THEN
        RETURN;
    END IF;

    -- do some initial cleanup 
    UPDATE actor.usr SET card = NULL WHERE id = src_usr;
    UPDATE actor.usr SET mailing_address = NULL WHERE id = src_usr;
    UPDATE actor.usr SET billing_address = NULL WHERE id = src_usr;

    -- actor.*
    IF del_cards THEN
        DELETE FROM actor.card where usr = src_usr;
    ELSE
        IF deactivate_cards THEN
            UPDATE actor.card SET active = 'f' WHERE usr = src_usr;
        END IF;
        UPDATE actor.card SET usr = dest_usr WHERE usr = src_usr;
    END IF;


    IF del_addrs THEN
        DELETE FROM actor.usr_address WHERE usr = src_usr;
    ELSE
        UPDATE actor.usr_address SET usr = dest_usr WHERE usr = src_usr;
    END IF;

    UPDATE actor.usr_message SET usr = dest_usr WHERE usr = src_usr;
    -- dupes are technically OK in actor.usr_standing_penalty, should manually delete them...
    UPDATE actor.usr_standing_penalty SET usr = dest_usr WHERE usr = src_usr;
    PERFORM actor.usr_merge_rows('actor.usr_org_unit_opt_in', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('actor.usr_setting', 'usr', src_usr, dest_usr);

    -- permission.*
    PERFORM actor.usr_merge_rows('permission.usr_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_object_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_grp_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_work_ou_map', 'usr', src_usr, dest_usr);


    -- container.*
	
	-- For each *_bucket table: transfer every bucket belonging to src_usr
	-- into the custody of dest_usr.
	--
	-- In order to avoid colliding with an existing bucket owned by
	-- the destination user, append the source user's id (in parenthesese)
	-- to the name.  If you still get a collision, add successive
	-- spaces to the name and keep trying until you succeed.
	--
	FOR bucket_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE container.user_bucket_item SET target_user = dest_usr WHERE target_user = src_usr;

    -- vandelay.*
	-- transfer queues the same way we transfer buckets (see above)
	FOR queue_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = queue_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- money.*
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'collector', src_usr, dest_usr);
    UPDATE money.billable_xact SET usr = dest_usr WHERE usr = src_usr;
    UPDATE money.billing SET voider = dest_usr WHERE voider = src_usr;
    UPDATE money.bnm_payment SET accepting_usr = dest_usr WHERE accepting_usr = src_usr;

    -- action.*
    UPDATE action.circulation SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
    UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
    UPDATE action.usr_circ_history SET usr = dest_usr WHERE usr = src_usr;

    UPDATE action.hold_request SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
    UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
    UPDATE action.hold_request SET canceled_by = dest_usr WHERE canceled_by = src_usr;
    UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;

    UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET patron = dest_usr WHERE patron = src_usr;
    UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.survey_response SET usr = dest_usr WHERE usr = src_usr;

    -- acq.*
    UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.fund_transfer SET transfer_user = dest_usr WHERE transfer_user = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;

	-- transfer picklists the same way we transfer buckets (see above)
	FOR picklist_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = picklist_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
    UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.provider_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.provider_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_usr_attr_definition SET usr = dest_usr WHERE usr = src_usr;

    -- asset.*
    UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;

    -- serial.*
    UPDATE serial.record_entry SET creator = dest_usr WHERE creator = src_usr;
    UPDATE serial.record_entry SET editor = dest_usr WHERE editor = src_usr;

    -- reporter.*
    -- It's not uncommon to define the reporter schema in a replica 
    -- DB only, so don't assume these tables exist in the write DB.
    BEGIN
    	UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;

    -- propagate preferred name values from the source user to the
    -- destination user, but only when values are not being replaced.
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr)
    UPDATE actor.usr SET 
        pref_prefix = 
            COALESCE(pref_prefix, (SELECT pref_prefix FROM susr)),
        pref_first_given_name = 
            COALESCE(pref_first_given_name, (SELECT pref_first_given_name FROM susr)),
        pref_second_given_name = 
            COALESCE(pref_second_given_name, (SELECT pref_second_given_name FROM susr)),
        pref_family_name = 
            COALESCE(pref_family_name, (SELECT pref_family_name FROM susr)),
        pref_suffix = 
            COALESCE(pref_suffix, (SELECT pref_suffix FROM susr))
    WHERE id = dest_usr;

    -- Copy and deduplicate name keywords
    -- String -> array -> rows -> DISTINCT -> array -> string
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr),
         dusr AS (SELECT * FROM actor.usr WHERE id = dest_usr)
    UPDATE actor.usr SET name_keywords = (
        WITH keywords AS (
            SELECT DISTINCT UNNEST(
                REGEXP_SPLIT_TO_ARRAY(
                    COALESCE((SELECT name_keywords FROM susr), '') || ' ' ||
                    COALESCE((SELECT name_keywords FROM dusr), ''),  E'\\s+'
                )
            ) AS parts
        ) SELECT STRING_AGG(kw.parts, ' ') FROM keywords kw
    ) WHERE id = dest_usr;

    -- Finally, delete the source user
    PERFORM actor.usr_delete(src_usr,dest_usr);

END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION actor.usr_purge_data(
	src_usr  IN INTEGER,
	specified_dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	renamable_row RECORD;
	dest_usr INTEGER;
BEGIN

	IF specified_dest_usr IS NULL THEN
		dest_usr := 1; -- Admin user on stock installs
	ELSE
		dest_usr := specified_dest_usr;
	END IF;

    -- action_trigger.event (even doing this, event_output may--and probably does--contain PII and should have a retention/removal policy)
    UPDATE action_trigger.event SET context_user = dest_usr WHERE context_user = src_usr;

	-- acq.*
	UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.lineitem SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.lineitem SET selector = dest_usr WHERE selector = src_usr;
	UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;
	DELETE FROM acq.lineitem_usr_attr_definition WHERE usr = src_usr;

	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE acq.picklist SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.picklist SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
	UPDATE acq.purchase_order SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.purchase_order SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.claim_event SET creator = dest_usr WHERE creator = src_usr;

	-- action.*
	DELETE FROM action.circulation WHERE usr = src_usr;
	UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
	UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
	UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;
	UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
	UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
	UPDATE action.hold_request SET canceled_by = dest_usr WHERE canceled_by = src_usr;
	DELETE FROM action.hold_request WHERE usr = src_usr;
	UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
	UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.non_cataloged_circulation WHERE patron = src_usr;
	UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.survey_response WHERE usr = src_usr;
	UPDATE action.fieldset SET owner = dest_usr WHERE owner = src_usr;
	DELETE FROM action.usr_circ_history WHERE usr = src_usr;
	UPDATE action.curbside SET notes = NULL WHERE patron = src_usr;

	-- actor.*
	DELETE FROM actor.card WHERE usr = src_usr;
	DELETE FROM actor.stat_cat_entry_usr_map WHERE target_usr = src_usr;
	DELETE FROM actor.usr_privacy_waiver WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;

	-- The following update is intended to avoid transient violations of a foreign
	-- key constraint, whereby actor.usr_address references itself.  It may not be
	-- necessary, but it does no harm.
	UPDATE actor.usr_address SET replaces = NULL
		WHERE usr = src_usr AND replaces IS NOT NULL;
	DELETE FROM actor.usr_address WHERE usr = src_usr;
	DELETE FROM actor.usr_org_unit_opt_in WHERE usr = src_usr;
	UPDATE actor.usr_org_unit_opt_in SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM actor.usr_setting WHERE usr = src_usr;
	DELETE FROM actor.usr_standing_penalty WHERE usr = src_usr;
	UPDATE actor.usr_message SET title = 'purged', message = 'purged', read_date = NOW() WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;
	UPDATE actor.usr_standing_penalty SET staff = dest_usr WHERE staff = src_usr;
	UPDATE actor.usr_message SET editor = dest_usr WHERE editor = src_usr;

	-- asset.*
	UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;

	-- auditor.*
	DELETE FROM auditor.actor_usr_address_history WHERE id = src_usr;
	DELETE FROM auditor.actor_usr_history WHERE id = src_usr;
	UPDATE auditor.asset_call_number_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_call_number_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.asset_copy_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_copy_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.biblio_record_entry_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.biblio_record_entry_history SET editor  = dest_usr WHERE editor  = src_usr;

	-- biblio.*
	UPDATE biblio.record_entry SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_entry SET editor = dest_usr WHERE editor = src_usr;
	UPDATE biblio.record_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_note SET editor = dest_usr WHERE editor = src_usr;

	-- container.*
	-- Update buckets with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	DELETE FROM container.user_bucket_item WHERE target_user = src_usr;

	-- money.*
	DELETE FROM money.billable_xact WHERE usr = src_usr;
	DELETE FROM money.collections_tracker WHERE usr = src_usr;
	UPDATE money.collections_tracker SET collector = dest_usr WHERE collector = src_usr;

	-- permission.*
	DELETE FROM permission.usr_grp_map WHERE usr = src_usr;
	DELETE FROM permission.usr_object_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_work_ou_map WHERE usr = src_usr;

	-- reporter.*
	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
	-- do nothing
	END;

	-- vandelay.*
	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- NULL-ify addresses last so other cleanup (e.g. circ anonymization)
    -- can access the information before deletion.
	UPDATE actor.usr SET
		active = FALSE,
		card = NULL,
		mailing_address = NULL,
		billing_address = NULL
	WHERE id = src_usr;

END;
$$ LANGUAGE plpgsql;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1406', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label) 
VALUES (
    'eg.grid.admin.config.circ_matrix_matchpoint', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.config.circ_matrix_matchpoint',
        'Grid Config: admin.config.circ_matrix_matchpoint',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1407', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES 
(
    'acq.lineitem.sort_order.claims', 'gui', 'integer',
    oils_i18n_gettext(
        'acq.lineitem.sort_order.claims',
        'ACQ Claim-Ready Lineitem List Sort Order',
        'cwst', 'label')
),
(
    'acq.lineitem.page_size.claims', 'gui', 'integer',
    oils_i18n_gettext(
        'acq.lineitem.page_size.claims',
        'ACQ Claim-Ready Lineitem List Page Size',
        'cwst', 'label')
),
(
    'eg.acq.search.lineitems.filter_to_invoiceable', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.acq.search.lineitems.filter_to_invoiceable',
        'ACQ Lineitem Search Filter to Invoiceable',
        'cwst', 'label')
),
(
    'eg.acq.search.lineitems.keep_results', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.acq.search.lineitems.keep_results',
        'ACQ Lineitem Search Keep Results Between Searches',
        'cwst', 'label')
),
(
    'eg.acq.search.lineitems.trim_list', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.acq.search.lineitems.trim_list',
        'ACQ Lineitem Search Trim List When Keeping Results',
        'cwst', 'label')
);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 650, 'ACQ_ALLOW_OVERSPEND', oils_i18n_gettext(650,
    'Allow a user to ignore a fund''s stop percentage.', 'ppl', 'description'))
;

COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1408', :eg_version);

INSERT INTO config.usr_setting_type (name, grp, datatype, label)
VALUES
(
    'eg.cat.z3950.default_field', 'gui', 'string',
    oils_i18n_gettext(
        'eg.cat.z3950.default_field',
        'Z39.50 Search default field',
        'cust', 'label')
),(
    'eg.cat.z3950.default_targets', 'gui', 'object',
    oils_i18n_gettext(
        'eg.cat.z3950.default_targets',
        'Z39.50 Search default targets',
        'cust', 'label')
);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES
(
    'eg.grid.global_z3950.search_results', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.global_z3950.search_results',
        'Grid Config: Z39.50 Search Results',
        'cwst', 'label')
),(
    'acq.default_bib_marc_template', 'gui', 'integer',
    oils_i18n_gettext(
        'acq.default_bib_marc_template',
        'Default ACQ Brief Record Bibliographic Template',
        'cwst', 'label')
),(
    'eg.grid.cat.vandelay.queue.list.acq', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.vandelay.queue.list.acq',
        'Grid Config: Vandelay ACQ Queue List',
        'cwst', 'label'
    )
),(
    'eg.grid.cat.vandelay.background-import.list', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.vandelay.background-import.list',
        'Grid Config: Vandelay Background Import List',
        'cwst', 'label'
    )
);

INSERT into config.org_unit_setting_type
    (name, datatype, grp, label, description)
VALUES (
    'acq.import_tab_display', 'string', 'gui',
    oils_i18n_gettext(
        'acq.import_tab_display',
        'ACQ: Which import tab(s) display in general Import/Export?',
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'acq.import_tab_display',
        'Valid values are: "cat" for Import for Cataloging, '
        || '"acq" for Import for Acquisitions, "both" or unset to display both.',
        'coust', 'description'
    )
);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 651, 'VIEW_BACKGROUND_IMPORT', oils_i18n_gettext(651,
                    'View background record import jobs', 'ppl', 'description')),
 ( 652, 'CREATE_BACKGROUND_IMPORT', oils_i18n_gettext(652,
                    'Create background record import jobs', 'ppl', 'description')),
 ( 653, 'UPDATE_BACKGROUND_IMPORT', oils_i18n_gettext(653,
                    'Update background record import jobs', 'ppl', 'description'))
;

CREATE TABLE vandelay.background_import (
    id              SERIAL      PRIMARY KEY,
    owner           INT         NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    workstation     INT         REFERENCES actor.workstation (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    import_type     TEXT        NOT NULL DEFAULT 'bib' CHECK (import_type IN ('bib','acq','authority')),
    params          TEXT,
    email           TEXT,
    state           TEXT        NOT NULL DEFAULT 'new' CHECK (state IN ('new','running','complete')),
    request_time    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    complete_time   TIMESTAMPTZ,
    queue           BIGINT      -- no fkey, could be either bib_queue or authority_queue, based on import_type
);

INSERT INTO action_trigger.hook (key, core_type, passive, description) VALUES
(  'vandelay.background_import.requested', 'vbi', TRUE,
   oils_i18n_gettext('vandelay.background_import.requested','A Import/Overlay background job was requested','ath', 'description')
),('vandelay.background_import.completed', 'vbi', TRUE,
   oils_i18n_gettext('vandelay.background_import.completed','A Import/Overlay background job was completed','ath', 'description')
);

INSERT INTO action_trigger.event_definition (active, owner, name, hook, validator, reactor, group_field, usr_field, template)
    VALUES ('f', 1, 'Vandelay Background Import Requested', 'vandelay.background_import.requested', 'NOOP_True', 'SendEmail', 'email', 'owner',
$$
[%- USE date -%]
[%- hostname = '' # set this in order to generate a link -%]
To: [%- target.0.email || params.recipient_email %]
From: [%- params.sender_email || default_sender %]
Date: [%- date.format(date.now, '%a, %d %b %Y %T -0000', gmt => 1) %]
Subject: Background Import Requested
Auto-Submitted: auto-generated

[% target.size %] new background import requests were added:

[% FOR bi IN target %]
    [%- IF bi.queue; summary = helpers.fetch_vbi_queue_summary(bi)%]
  * Queue: [% summary.queue.name %] ([% bi.import_type %])
    Records in queue: [% summary.total %]
    Items in queue: [% summary.total_items %]
     [% IF bi.state != 'new' %]
     - Records imported: [% summary.imported %]
     - Items imported: [% summary.total_items_imported %]
     - Records import errors: [% summary.rec_import_errors %]
     - Items import errors: [% summary.item_import_errors %]
     [% END %]
    [% END %]
  [% IF hostname %]View queue at: https://[% hostname %]/eg2/staff/cat/vandelay/queue/[% bi.import_type %]/[% bi.queue %][% END %]

[% END %]

[% IF hostname %]Manage background imports at: https://[% hostname %]/eg2/staff/cat/vandelay/background-import[% END %]

$$);

INSERT INTO action_trigger.event_definition (active, owner, name, hook, validator, reactor, group_field, usr_field, template)
    VALUES ('f', 1, 'Vandelay Background Import Completed', 'vandelay.background_import.completed', 'NOOP_True', 'SendEmail', 'email', 'owner',
$$
[%- USE date -%]
[%- hostname = '' # set this in order to generate a link -%]
To: [%- target.0.email || params.recipient_email %]
From: [%- params.sender_email || default_sender %]
Date: [%- date.format(date.now, '%a, %d %b %Y %T -0000', gmt => 1) %]
Subject: Background Import Completed
Auto-Submitted: auto-generated

[% target.size %] new background import requests were completed:

[% FOR bi IN target %]
    [%- summary = helpers.fetch_vbi_queue_summary(bi) -%]
  * Queue: [% summary.queue.name %] ([% bi.import_type %])
    Records in queue: [% summary.total %]
    Items in queue: [% summary.total_items %]
     - Records imported: [% summary.imported %]
     - Items imported: [% summary.total_items_imported %]
     - Records import errors: [% summary.rec_import_errors %]
     - Items import errors: [% summary.item_import_errors %]
  [% IF hostname %]View queue at: https://[% hostname %]/eg2/staff/cat/vandelay/queue/[% bi.import_type %]/[% bi.queue %][% END %]

[% END %]

[% IF hostname %]Manage background imports at: https://[% hostname %]/eg2/staff/cat/vandelay/background-import[% END %]

$$);

COMMIT;

-- Evergreen DB patch XXXX.shelving-location-with-lassos.sql
--
-- Global flag to display shelving locations with lassos in the staff client
--
BEGIN;


-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1409', :eg_version);

INSERT INTO config.global_flag (name, enabled, label)
    VALUES (
        'staff.search.shelving_location_groups_with_lassos', TRUE,
        oils_i18n_gettext(
            'staff.search.shelving_location_groups_with_lassos',
            'Staff Catalog Search: Display shelving location groups with library groups',
            'cgf',
            'label'
        )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1410', :eg_version);

INSERT INTO config.org_unit_setting_type (
  name, grp, label, description, datatype
) VALUES (
  'ui.patron.edit.aus.default_phone.regex',
  'gui',
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_phone.regex',
    'Regex for default_phone field on patron registration',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_phone.regex',
    'The Regular Expression for validation on the default_phone field in patron registration.',
    'coust',
    'description'
  ),
  'string'
), (
  'ui.patron.edit.aus.default_phone.example',
  'gui',
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_phone.example',
    'Example for default_phone field on patron registration',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_phone.example',
    'The Example for validation on the default_phone field in patron registration.',
    'coust',
    'description'
  ),
  'string'
), (
  'ui.patron.edit.aus.default_sms_notify.regex',
  'gui',
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_sms_notify.regex',
    'Regex for default_sms_notify field on patron registration',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_sms_notify.regex',
    'The Regular Expression for validation on the default_sms_notify field in patron registration.',
    'coust',
    'description'
  ),
  'string'
), (
  'ui.patron.edit.aus.default_sms_notify.example',
  'gui',
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_sms_notify.example',
    'Example for default_sms_notify field on patron registration',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'ui.patron.edit.aus.default_sms_notify.example',
    'The Example for validation on the default_sms_notify field in patron registration.',
    'coust',
    'description'
  ),
  'string'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1411', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.reporter.full.outputs.pending', 'gui', 'object', 
    oils_i18n_gettext( 'eg.grid.reporter.full.outputs.pending', 'Pending report output grid settings', 'cwst', 'label')
), (
    'eg.grid.reporter.full.outputs.complete', 'gui', 'object', 
    oils_i18n_gettext( 'eg.grid.reporter.full.outputs.complete', 'Completed report output grid settings', 'cwst', 'label')
), (
    'eg.grid.reporter.full.templates', 'gui', 'object', 
    oils_i18n_gettext( 'eg.grid.reporter.full.templates', 'Report template grid settings', 'cwst', 'label')
), (
    'eg.grid.reporter.full.reports', 'gui', 'object', 
    oils_i18n_gettext( 'eg.grid.reporter.full.reports', 'Report definition grid settings', 'cwst', 'label')
);

UPDATE  config.ui_staff_portal_page_entry
  SET   target_url = '/eg2/staff/reporter/full'
  WHERE id = 12
        AND entry_type = 'menuitem'
        AND target_url = '/eg/staff/reporter/legacy/main'
;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1412', :eg_version);

DROP SCHEMA IF EXISTS sip CASCADE;

CREATE SCHEMA sip;

-- Collections of settings that can be linked to one or more SIP accounts.
CREATE TABLE sip.setting_group (
    id          SERIAL PRIMARY KEY,
    label       TEXT UNIQUE NOT NULL,
    institution TEXT NOT NULL -- Duplicates OK
);

-- Key/value setting pairs
CREATE TABLE sip.setting (
    id SERIAL       PRIMARY KEY,
    setting_group   INTEGER NOT NULL REFERENCES sip.setting_group (id)
                    ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL,
    value           JSON NOT NULL,
    CONSTRAINT      name_once_per_inst UNIQUE (setting_group, name)
);

CREATE TABLE sip.account (
    id              SERIAL PRIMARY KEY,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    setting_group   INTEGER NOT NULL REFERENCES sip.setting_group (id)
                    DEFERRABLE INITIALLY DEFERRED,
    sip_username    TEXT UNIQUE NOT NULL,
    usr             BIGINT NOT NULL REFERENCES actor.usr(id)
                    DEFERRABLE INITIALLY DEFERRED,
    workstation     INTEGER REFERENCES actor.workstation(id),
    -- sessions for transient accounts are not tracked in sip.session
    transient       BOOLEAN NOT NULL DEFAULT FALSE,
    activity_who    TEXT -- config.usr_activity_type.ewho
);

CREATE TABLE sip.session (
    key         TEXT PRIMARY KEY,
    ils_token   TEXT NOT NULL UNIQUE,
    account     INTEGER NOT NULL REFERENCES sip.account(id)
                ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    create_time TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sip.screen_message (
    key     TEXT PRIMARY KEY,
    message TEXT NOT NULL
);

-- SEED DATA

INSERT INTO actor.passwd_type (code, name, login, crypt_algo, iter_count)
    VALUES ('sip2', 'SIP2 Client Password', FALSE, 'bf', 5);

-- ID 1 is magic.
INSERT INTO sip.setting_group (id, label, institution) 
    VALUES (1, 'Default Settings', 'example');

-- carve space for other canned setting groups
SELECT SETVAL('sip.setting_group_id_seq'::TEXT, 1000);

-- has to be global since settings are linked to accounts and if
-- status-before-login is used, no account information will be available.
INSERT INTO config.global_flag (name, value, enabled, label) VALUES
(   'sip.sc_status_before_login_institution', NULL, FALSE, 
    oils_i18n_gettext(
        'sip.sc_status_before_login_institution',
        'Activate status-before-login-support and define the institution ' ||
        'value which should be used in the response',
        'cgf', 'label')
);

INSERT INTO sip.setting (setting_group, name, value, description)
VALUES (
    1, 'currency', '"USD"',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'currency'),
        'Monetary amounts are reported in this currency',
        'sipset', 'description')
), (
    1, 'av_format', '"eg_legacy"',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'av_format'),
        'AV Format. Options: eg_legacy, 3m, swyer_a, swyer_b',
        'sipset', 'description')
), (
    1, 'due_date_use_sip_date_format', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'due_date_use_sip_date_format'),
        'Due date uses 18-char date format (YYYYMMDDZZZZHHMMSS).  Otherwise "YYYY-MM-DD HH:MM:SS',
        'sipset', 'description')
), (
    1, 'patron_status_permit_loans', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'patron_status_permit_loans'),
        'Checkout and renewal are allowed even when penalties blocking these actions exist',
        'sipset', 'description')
), (
    1, 'patron_status_permit_all', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'patron_status_permit_all'),
        'Holds, checkouts, and renewals allowed regardless of blocking penalties',
        'sipset', 'description')
), (
    1, 'default_activity_who', 'null',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'default_activity_who'),
        'Patron holds data may be returned as either "title" or "barcode"',
        'sipset', 'description')
), (
    1, 'msg64_summary_datatype', '"title"',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'msg64_summary_datatype'),
        'Patron circulation data may be returned as either "title" or "barcode"',
        'sipset', 'description')
), (
    1, 'msg64_hold_datatype', '"title"',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'msg64_hold_datatype'),
        'Patron holds data may be returned as either "title" or "barcode"',
        'sipset', 'description')
), (
    1, 'msg64_hold_items_available', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'msg64_hold_items_available'),
        'Only return information on available holds',
        'sipset', 'description')
), (
    1, 'checkout.override.COPY_ALERT_MESSAGE', 'true',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkout.override.COPY_ALERT_MESSAGE'),
        'Checkout override copy alert message',
        'sipset', 'description')
), (
    1, 'checkout.override.COPY_NOT_AVAILABLE', 'true',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkout.override.COPY_NOT_AVAILABLE'),
        'Checkout override copy not available message',
        'sipset', 'description')
), (
    1, 'checkin.override.COPY_ALERT_MESSAGE', 'true',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkin.override.COPY_ALERT_MESSAGE'),
        'Checkin override copy alert message',
        'sipset', 'description')
), (
    1, 'checkin.override.COPY_BAD_STATUS', 'true',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkin.override.COPY_BAD_STATUS'),
        'Checkin override bad copy status',
        'sipset', 'description')
), (
    1, 'checkin.override.COPY_STATUS_MISSING', 'true',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkin.override.COPY_STATUS_MISSING'),
        'Checkin override copy status missing',
        'sipset', 'description')
), (
    1, 'checkin_hold_as_transit', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'checkin_hold_as_transit'),
        'Checkin local holds as transits',
        'sipset', 'description')
), (
    1, 'support_acs_resend_messages', 'false',
    oils_i18n_gettext(
        (SELECT id FROM sip.setting WHERE name = 'support_acs_resend_messages'),
        'Support ACS Resend Messages (code 97)',
        'sipset', 'description')
);

INSERT INTO sip.screen_message (key, message) VALUES (
    'checkout.open_circ_exists', 
    oils_i18n_gettext(
        'checkout.open_circ_exists',
        'This item is already checked out',
        'sipsm', 'message')
), (
    'checkout.patron_not_allowed', 
    oils_i18n_gettext(
        'checkout.patron_not_allowed',
        'Patron is not allowed to checkout the selected item',
        'sipsm', 'message')
), (
    'payment.overpayment_not_allowed',
    oils_i18n_gettext(
        'payment.overpayment_not_allowed',
        'Overpayment not allowed',
        'sipsm', 'message')
), (
    'payment.transaction_not_found',
    oils_i18n_gettext(
        'payment.transaction_not_found',
        'Bill not found',
        'sipsm', 'message')
);


/* EXAMPLE SETTINGS

-- Example linking a SIP password to the 'admin' account.
SELECT actor.set_passwd(1, 'sip2', 'sip_password');

INSERT INTO actor.workstation (name, owning_lib) VALUES ('BR1-SIP2-Gateway', 4);

INSERT INTO sip.account(
    setting_group, sip_username, sip_password, usr, workstation
) VALUES (
    1, 'admin', 
    (SELECT id FROM actor.passwd WHERE usr = 1 AND passwd_type = 'sip2'),
    1, 
    (SELECT id FROM actor.workstation WHERE name = 'BR1-SIP2-Gateway')
);

*/

COMMIT;



BEGIN;

SELECT evergreen.upgrade_deps_block_check('1413', :eg_version);

CREATE TABLE sip.filter (
    id              SERIAL PRIMARY KEY,
    enabled         BOOLEAN NOT NULL DEFAULT FALSE,
    setting_group   INTEGER NOT NULL REFERENCES sip.setting_group (id)
                    ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    identifier      TEXT NOT NULL,
    strip           BOOLEAN NOT NULL DEFAULT FALSE,
    replace_with    TEXT
);

COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1414', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
  654,
  'VIEW_SHIPMENT_NOTIFICATION',
  oils_i18n_gettext(654,
    'View shipment notifications', 'ppl', 'description'
  )
  FROM permission.perm_list
  WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_SHIPMENT_NOTIFICATION');
 
INSERT INTO permission.perm_list ( id, code, description )  SELECT DISTINCT
  655,
  'MANAGE_SHIPMENT_NOTIFICATION',
  oils_i18n_gettext(655,
    'Manage shipment notifications', 'ppl', 'description'
  )
  FROM permission.perm_list
  WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'MANAGE_SHIPMENT_NOTIFICATION');

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1415', :eg_version);
INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   656,
   'PATRON_BARRED.override',
   oils_i18n_gettext(656,
     'Override the PATRON_BARRED event', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'PATRON_BARRED.override');


COMMIT;
BEGIN;

-- This upgrade script is now disabled
-- See LP2073561
-- SELECT evergreen.upgrade_deps_block_check('1416', :eg_version);


COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1417', :eg_version);

CREATE OR REPLACE FUNCTION action.process_ingest_queue_entry (qeid BIGINT) RETURNS BOOL AS $func$
DECLARE
    ingest_success  BOOL := NULL;
    qe              action.ingest_queue_entry%ROWTYPE;
    aid             authority.record_entry.id%TYPE;
BEGIN

    SELECT * INTO qe FROM action.ingest_queue_entry WHERE id = qeid;
    IF qe.ingest_time IS NOT NULL OR qe.override_by IS NOT NULL THEN
        RETURN TRUE; -- Already done
    END IF;

    IF qe.action = 'delete' THEN
        IF qe.record_type = 'biblio' THEN
            SELECT metabib.indexing_delete(r.*, qe.state_data) INTO ingest_success FROM biblio.record_entry r WHERE r.id = qe.record;
        ELSIF qe.record_type = 'authority' THEN
            SELECT authority.indexing_delete(r.*, qe.state_data) INTO ingest_success FROM authority.record_entry r WHERE r.id = qe.record;
        END IF;
    ELSE
        IF qe.record_type = 'biblio' THEN
            IF qe.action = 'propagate' THEN
                SELECT authority.apply_propagate_changes(qe.state_data::BIGINT, qe.record) INTO aid;
                SELECT aid = qe.state_data::BIGINT INTO ingest_success;
            ELSE
                SELECT metabib.indexing_update(r.*, qe.action = 'insert', qe.state_data) INTO ingest_success FROM biblio.record_entry r WHERE r.id = qe.record;
            END IF;
        ELSIF qe.record_type = 'authority' THEN
            SELECT authority.indexing_update(r.*, qe.action = 'insert', qe.state_data) INTO ingest_success FROM authority.record_entry r WHERE r.id = qe.record;
        END IF;
    END IF;

    IF NOT ingest_success THEN
        UPDATE action.ingest_queue_entry SET fail_time = NOW() WHERE id = qe.id;
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.queued.abort_on_error' AND enabled;
        IF FOUND THEN
            RAISE EXCEPTION 'Ingest action of % on %.record_entry % for queue entry % failed', qe.action, qe.record_type, qe.record, qe.id;
        ELSE
            RAISE WARNING 'Ingest action of % on %.record_entry % for queue entry % failed', qe.action, qe.record_type, qe.record, qe.id;
        END IF;
    ELSE
        IF qe.record_type = 'biblio' THEN
            PERFORM reporter.simple_rec_update(qe.record, qe.action = 'delete');
        END IF;
        UPDATE action.ingest_queue_entry SET ingest_time = NOW() WHERE id = qe.id;
    END IF;

    RETURN ingest_success;
END;
$func$ LANGUAGE PLPGSQL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1418', :eg_version);

INSERT INTO config.global_flag (name, enabled, value, label) 
    VALUES (
        'search.max_suggestion_search_terms',
        TRUE,
        3,
        oils_i18n_gettext(
            'search.max_suggestion_search_terms',
            'Limit suggestion generation to searches with this many terms or less',
            'cgf',
            'label'
        )
    );

COMMIT;

/* UNDO
BEGIN;
DELETE FROM config.global_flag WHERE name = 'search.max_suggestion_search_terms';
COMMIT;
*/

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1419', :eg_version);

INSERT INTO config.usr_setting_type (name,grp,opac_visible,label,description,datatype) VALUES (
    'ui.show_search_highlight',
    'gui',
    TRUE,
    oils_i18n_gettext(
        'ui.show_search_highlight',
        'Search Highlight',
        'cust',
        'label'
    ),
    oils_i18n_gettext(
        'ui.show_search_highlight',
        'A toggle deciding whether to highlight strings in a keyword search result matching the searched term(s)',
        'cust',
        'description'
    ),
    'bool'
);

COMMIT;BEGIN;

SELECT evergreen.upgrade_deps_block_check('1420', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.search.sort_order', 'gui', 'string',
    oils_i18n_gettext(
        'eg.search.sort_order',
        'Default sort order upon first opening a catalog search',
        'cwst', 'label'
    )
), 
(
    'eg.search.available_only', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.search.available_only',
        'Whether to search for only bibs with available items upon first opening a catalog search',
        'cwst', 'label'
    )
),
(
    'eg.search.group_formats', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.search.group_formats',
        'Whether to group formats/editions upon first opening a catalog search',
        'cwst', 'label'
    )
);


COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1421', :eg_version);

CREATE OR REPLACE FUNCTION unapi.acpt ( obj_id BIGINT, format TEXT,  ename TEXT, includes TEXT[], org TEXT, depth INT DEFAULT NULL, slimit HSTORE DEFAULT NULL, soffset HSTORE DEFAULT NULL, include_xmlns BOOL DEFAULT TRUE ) RETURNS XML AS $F$
        SELECT  XMLELEMENT(
                    name copy_tag,
                    XMLATTRIBUTES(
                        CASE WHEN $9 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                        copy_tag_type.label AS type,
                        copy_tag.url AS url
                    ),
                    copy_tag.value
                )
          FROM  asset.copy_tag
          JOIN  config.copy_tag_type
          ON    copy_tag_type.code = copy_tag.tag_type
          WHERE copy_tag.id = $1;
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION unapi.acp ( obj_id BIGINT, format TEXT,  ename TEXT, includes TEXT[], org TEXT, depth INT DEFAULT NULL, slimit HSTORE DEFAULT NULL, soffset HSTORE DEFAULT NULL, include_xmlns BOOL DEFAULT TRUE ) RETURNS XML AS $F$
        SELECT  XMLELEMENT(
                    name copy,
                    XMLATTRIBUTES(
                        CASE WHEN $9 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                        'tag:open-ils.org:U2@acp/' || id AS id, id AS copy_id,
                        create_date, edit_date, copy_number, circulate, deposit,
                        ref, holdable, deleted, deposit_amount, price, barcode,
                        circ_modifier, circ_as_type, opac_visible, age_protect
                    ),
                    unapi.ccs( status, $2, 'status', array_remove($4,'acp'), $5, $6, $7, $8, FALSE),
                    unapi.acl( location, $2, 'location', array_remove($4,'acp'), $5, $6, $7, $8, FALSE),
                    unapi.aou( circ_lib, $2, 'circ_lib', array_remove($4,'acp'), $5, $6, $7, $8),
                    unapi.aou( circ_lib, $2, 'circlib', array_remove($4,'acp'), $5, $6, $7, $8),
                    CASE WHEN ('acn' = ANY ($4)) THEN unapi.acn( call_number, $2, 'call_number', array_remove($4,'acp'), $5, $6, $7, $8, FALSE) ELSE NULL END,
                    CASE
                        WHEN ('acpn' = ANY ($4)) THEN
                            XMLELEMENT( name copy_notes,
                                (SELECT XMLAGG(acpn) FROM (
                                    SELECT  unapi.acpn( id, 'xml', 'copy_note', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_note
                                      WHERE owning_copy = cp.id AND pub
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('acpt' = ANY ($4)) THEN
                            XMLELEMENT( name copy_tags,
                                (SELECT XMLAGG(acpt) FROM (
                                    SELECT  unapi.acpt( copy_tag.id, 'xml', 'copy_tag', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_tag_copy_map
                                      JOIN asset.copy_tag ON copy_tag.id = copy_tag_copy_map.tag
                                      WHERE copy_tag_copy_map.copy = cp.id AND copy_tag.pub
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('ascecm' = ANY ($4)) THEN
                            XMLELEMENT( name statcats,
                                (SELECT XMLAGG(ascecm) FROM (
                                    SELECT  unapi.ascecm( stat_cat_entry, 'xml', 'statcat', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.stat_cat_entry_copy_map
                                      WHERE owning_copy = cp.id
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('bre' = ANY ($4)) THEN
                            XMLELEMENT( name foreign_records,
                                (SELECT XMLAGG(bre) FROM (
                                    SELECT  unapi.bre(peer_record,'marcxml','record','{}'::TEXT[], $5, $6, $7, $8, FALSE)
                                      FROM  biblio.peer_bib_copy_map
                                      WHERE target_copy = cp.id
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('bmp' = ANY ($4)) THEN
                            XMLELEMENT( name monograph_parts,
                                (SELECT XMLAGG(bmp) FROM (
                                    SELECT  unapi.bmp( part, 'xml', 'monograph_part', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_part_map
                                      WHERE target_copy = cp.id
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('circ' = ANY ($4)) THEN
                            XMLELEMENT( name current_circulation,
                                (SELECT XMLAGG(circ) FROM (
                                    SELECT  unapi.circ( id, 'xml', 'circ', array_remove($4,'circ'), $5, $6, $7, $8, FALSE)
                                      FROM  action.circulation
                                      WHERE target_copy = cp.id
                                            AND checkin_time IS NULL
                                )x)
                            )
                        ELSE NULL
                    END
                )
          FROM  asset.copy cp
          WHERE id = $1
              AND cp.deleted IS FALSE
          GROUP BY id, status, location, circ_lib, call_number, create_date,
              edit_date, copy_number, circulate, deposit, ref, holdable,
              deleted, deposit_amount, price, barcode, circ_modifier,
              circ_as_type, opac_visible, age_protect;
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION unapi.sunit ( obj_id BIGINT, format TEXT,  ename TEXT, includes TEXT[], org TEXT, depth INT DEFAULT NULL, slimit HSTORE DEFAULT NULL, soffset HSTORE DEFAULT NULL, include_xmlns BOOL DEFAULT TRUE ) RETURNS XML AS $F$
        SELECT  XMLELEMENT(
                    name serial_unit,
                    XMLATTRIBUTES(
                        CASE WHEN $9 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                        'tag:open-ils.org:U2@acp/' || id AS id, id AS copy_id,
                        create_date, edit_date, copy_number, circulate, deposit,
                        ref, holdable, deleted, deposit_amount, price, barcode,
                        circ_modifier, circ_as_type, opac_visible, age_protect,
                        status_changed_time, floating, mint_condition,
                        detailed_contents, sort_key, summary_contents, cost
                    ),
                    unapi.ccs( status, $2, 'status', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8, FALSE),
                    unapi.acl( location, $2, 'location', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8, FALSE),
                    unapi.aou( circ_lib, $2, 'circ_lib', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8),
                    unapi.aou( circ_lib, $2, 'circlib', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8),
                    CASE WHEN ('acn' = ANY ($4)) THEN unapi.acn( call_number, $2, 'call_number', array_remove($4,'acp'), $5, $6, $7, $8, FALSE) ELSE NULL END,
                    XMLELEMENT( name copy_notes,
                        CASE
                            WHEN ('acpn' = ANY ($4)) THEN
                                (SELECT XMLAGG(acpn) FROM (
                                    SELECT  unapi.acpn( id, 'xml', 'copy_note', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_note
                                      WHERE owning_copy = cp.id AND pub
                                )x)
                            ELSE NULL
                        END
                    ),
                    XMLELEMENT( name copy_tags,
                        CASE
                            WHEN ('acpt' = ANY ($4)) THEN
                                (SELECT XMLAGG(acpt) FROM (
                                    SELECT  unapi.acpt( copy_tag.id, 'xml', 'copy_tag', array_remove( array_remove($4,'acp'),'sunit'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_tag_copy_map
                                      JOIN  asset.copy_tag ON copy_tag.id = copy_tag_copy_map.tag
                                      WHERE copy_tag_copy_map.copy = cp.id AND copy_tag.pub
                                )x)
                            ELSE NULL
                        END
                    ),
                    XMLELEMENT( name statcats,
                        CASE
                            WHEN ('ascecm' = ANY ($4)) THEN
                                (SELECT XMLAGG(ascecm) FROM (
                                    SELECT  unapi.ascecm( stat_cat_entry, 'xml', 'statcat', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.stat_cat_entry_copy_map
                                      WHERE owning_copy = cp.id
                                )x)
                            ELSE NULL
                        END
                    ),
                    XMLELEMENT( name foreign_records,
                        CASE
                            WHEN ('bre' = ANY ($4)) THEN
                                (SELECT XMLAGG(bre) FROM (
                                    SELECT  unapi.bre(peer_record,'marcxml','record','{}'::TEXT[], $5, $6, $7, $8, FALSE)
                                      FROM  biblio.peer_bib_copy_map
                                      WHERE target_copy = cp.id
                                )x)
                            ELSE NULL
                        END
                    ),
                    CASE
                        WHEN ('bmp' = ANY ($4)) THEN
                            XMLELEMENT( name monograph_parts,
                                (SELECT XMLAGG(bmp) FROM (
                                    SELECT  unapi.bmp( part, 'xml', 'monograph_part', array_remove($4,'acp'), $5, $6, $7, $8, FALSE)
                                      FROM  asset.copy_part_map
                                      WHERE target_copy = cp.id
                                )x)
                            )
                        ELSE NULL
                    END,
                    CASE
                        WHEN ('circ' = ANY ($4)) THEN
                            XMLELEMENT( name current_circulation,
                                (SELECT XMLAGG(circ) FROM (
                                    SELECT  unapi.circ( id, 'xml', 'circ', array_remove($4,'circ'), $5, $6, $7, $8, FALSE)
                                      FROM  action.circulation
                                      WHERE target_copy = cp.id
                                            AND checkin_time IS NULL
                                )x)
                            )
                        ELSE NULL
                    END
                )
          FROM  serial.unit cp
          WHERE id = $1
              AND cp.deleted IS FALSE
          GROUP BY id, status, location, circ_lib, call_number, create_date,
              edit_date, copy_number, circulate, floating, mint_condition,
              deposit, ref, holdable, deleted, deposit_amount, price,
              barcode, circ_modifier, circ_as_type, opac_visible,
              status_changed_time, detailed_contents, sort_key,
              summary_contents, cost, age_protect;
$F$ LANGUAGE SQL STABLE;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1422', :eg_version);

UPDATE config.org_unit_setting_type
SET description = oils_i18n_gettext('circ.holds.ui_require_monographic_part_when_present',
        'Normally the selection of a monographic part during hold placement is optional if there is at least one copy on the bib without a monographic part.  A true value for this setting will require part selection even under this condition.  A true value for this setting will also require a part to be added before saving any changes or creating a new item in the holdings editor, if there are parts on the bib.',
        'coust', 'description')
WHERE name = 'circ.holds.ui_require_monographic_part_when_present';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1423', :eg_version);

INSERT INTO config.org_unit_setting_type
    (name, grp, datatype, label, description)
VALUES (
    'opac.self_register.dob_order',
    'opac',
    'string',
    oils_i18n_gettext(
        'opac.self_register.dob_order',
        'Patron Self-Reg. Date of Birth Order',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'opac.self_register.dob_order',
        'The order in which to present the Month, Day, and Year elements for the Date of Birth field in Patron Self-Registration. Use the letter M for Month, D for Day, and Y for Year. Examples: MDY, DMY, YMD',
        'coust',
        'description'
    )
);

INSERT INTO config.org_unit_setting_type
    (name, grp, datatype, label, description)
VALUES (
    'opac.patron.edit.au.usrname.hide',
    'opac',
    'bool',
    oils_i18n_gettext(
        'opac.patron.edit.au.usrname.hide',
        'Hide Username field in Patron Self-Reg.',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'opac.patron.edit.au.usrname.hide',
        'Hides the Requested Username field in the Patron Self-Registration interface.',
        'coust',
        'description'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1424', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.acq.distribution_formula', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.acq.distribution_formula',
        'Grid Config: admin.acq.distribution_formula',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1425', :eg_version);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'ui.toast_duration',
    'gui',
    oils_i18n_gettext('ui.toast_duration',
        'Staff Client toast alert duration (seconds)',
        'coust', 'label'),
    oils_i18n_gettext('ui.toast_duration',
        'The number of seconds a toast alert should remain visible if not manually dismissed. Default is 10.',
        'coust', 'description'),
    'integer'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1426', :eg_version);


CREATE TABLE action.hold_request_reset_reason (
    id SERIAL NOT NULL PRIMARY KEY,
    manual BOOLEAN,
    name TEXT UNIQUE
);

CREATE TABLE action.hold_request_reset_reason_entry (
    id SERIAL NOT NULL PRIMARY KEY,
    hold INT REFERENCES action.hold_request (id) DEFERRABLE INITIALLY DEFERRED,
    reset_reason INT REFERENCES action.hold_request_reset_reason (id) DEFERRABLE INITIALLY DEFERRED,
    note TEXT,
    reset_time TIMESTAMP WITH TIME ZONE,
    previous_copy BIGINT REFERENCES asset.copy (id) DEFERRABLE INITIALLY DEFERRED,
    requestor INT REFERENCES actor.usr (id) DEFERRABLE INITIALLY DEFERRED,
    requestor_workstation INT REFERENCES actor.workstation (id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX ahrrre_hold_idx ON action.hold_request_reset_reason_entry (hold);

INSERT INTO action.hold_request_reset_reason (id, name, manual) VALUES
(1,'HOLD_TIMED_OUT',false),
(2,'HOLD_MANUAL_RESET',true),
(3,'HOLD_BETTER_HOLD',false),
(4,'HOLD_FROZEN',true),
(5,'HOLD_UNFROZEN',true),
(6,'HOLD_CANCELED',true),
(7,'HOLD_UNCANCELED',true),
(8,'HOLD_UPDATED',true),
(9,'HOLD_CHECKED_OUT',true),
(10,'HOLD_CHECKED_IN',true);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'circ.hold_retarget_previous_targets_interval', 'holds',
  oils_i18n_gettext('circ.hold_retarget_previous_targets_interval',
    'Retarget previous targets interval',
    'coust', 'label'),
  oils_i18n_gettext('circ.hold_retarget_previous_targets_interval',
    'Hold targeter will create proximity adjustments for previously targeted copies within this time interval (in days).',
    'coust', 'description'),
  'integer', null);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'circ.hold_reset_reason_entry_age_threshold', 'holds',
  oils_i18n_gettext('circ.hold_reset_reason_entry_age_threshold',
    'Hold reset reason entry deletion interval',
    'coust', 'label'),
  oils_i18n_gettext('circ.hold_reset_reason_entry_age_threshold',
    'Hold reset reason entries will be removed if older than this interval. Default 1 year if no value provided.',
    'coust', 'description'),
  'interval', null);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1427', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.catalog.record.conjoined', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.record.conjoined',
        'Grid Config: catalog.record.conjoined',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1428', :eg_version);

ALTER TABLE acq.exchange_rate 
	DROP CONSTRAINT exchange_rate_from_currency_fkey
	,ADD CONSTRAINT exchange_rate_from_currency_fkey FOREIGN KEY (from_currency) REFERENCES acq.currency_type (code) ON UPDATE CASCADE;

ALTER TABLE acq.exchange_rate 
	DROP CONSTRAINT exchange_rate_to_currency_fkey
	,ADD CONSTRAINT exchange_rate_to_currency_fkey FOREIGN KEY (to_currency) REFERENCES acq.currency_type (code) ON UPDATE CASCADE;

ALTER TABLE acq.funding_source
    DROP CONSTRAINT funding_source_currency_type_fkey
    ,ADD CONSTRAINT funding_source_currency_type_fkey FOREIGN KEY (currency_type) REFERENCES acq.currency_type (code) ON UPDATE CASCADE;

UPDATE acq.fund SET currency_type ='CAD' WHERE currency_type = 'CAN';
UPDATE acq.fund_debit SET origin_currency_type ='CAD' WHERE origin_currency_type = 'CAN';
UPDATE acq.provider SET currency_type ='CAD' WHERE currency_type = 'CAN';
UPDATE acq.currency_type SET code = 'CAD' WHERE code = 'CAN';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1429', :eg_version);

UPDATE config.org_unit_setting_type
SET description = oils_i18n_gettext('circ.course_materials_brief_record_bib_source',
    'The course materials module will use this bib source for any new brief bibliographic records made inside that module. For best results, use a transcendent bib source.',
    'coust', 'description')
WHERE name='circ.course_materials_brief_record_bib_source';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1430', :eg_version);

INSERT INTO config.print_template
    (name, label, owner, active, locale, content_type, template)
VALUES ('serials_routing_list', 'Serials routing list', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  SET title = template_data.title;
  SET distribution = template_data.distribution;
  SET issuance = template_data.issuance;
  SET routing_list = template_data.routing_list;
  SET stream = template_data.stream;
%] 

<p>[% title %]</p>
<p>[% issuance.label %]</p>
<p>([% distribution.holding_lib.shortname %]) [% distribution.label %] / [% stream.routing_label %] ID [% stream.id %]</p>
  <ol>
	[% FOR route IN routing_list %]
    <li>
    [% IF route.reader %]
      [% route.reader.first_given_name %] [% route.reader.family_name %]
      [% IF route.note %]
        - [% route.note %]
      [% END %]
      [% route.reader.mailing_address.street1 %]
      [% route.reader.mailing_address.street2 %]
      [% route.reader.mailing_address.city %], [% route.reader.mailing_address.state %] [% route.reader.mailing_address.post_code %]
    [% ELSIF route.department %]
      [% route.department %]
      [% IF route.note %]
        - [% route.note %]
      [% END %]
    [% END %]
    </li>
  [% END %]
  </ol>
</div>

$TEMPLATE$ WHERE name = 'serials_routing_list';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1431', :eg_version);

--Add the new information used to calculate available_copy_ratio to the stats the function sends out
DROP TYPE IF EXISTS action.hold_stats CASCADE;
CREATE TYPE action.hold_stats AS (
    hold_count              INT,
    competing_hold_count    INT,
    copy_count              INT,
    available_count         INT,
    total_copy_ratio        FLOAT,
    available_copy_ratio    FLOAT
);

--copy_id is a numeric id from asset.copy.
--A copy is treated as unavailable if it is still age protected and belongs to a different org unit
CREATE OR REPLACE FUNCTION action.copy_related_hold_stats (copy_id BIGINT) RETURNS action.hold_stats AS $func$
DECLARE
    output                  action.hold_stats%ROWTYPE;
    hold_count              INT := 0;
    competing_hold_count    INT := 0;
    copy_count              INT := 0;
    available_count         INT := 0;
    copy                    RECORD;
    hold                    RECORD;
BEGIN

    output.hold_count := 0;
    output.competing_hold_count := 0;
    output.copy_count := 0;
    output.available_count := 0;

    --Find all unique holds considering our copy
    CREATE TEMPORARY TABLE copy_holds_tmp AS 
        SELECT  DISTINCT m.hold, m.target_copy, h.pickup_lib, h.request_lib, h.requestor, h.usr
        FROM  action.hold_copy_map m
                JOIN action.hold_request h ON (m.hold = h.id)
        WHERE m.target_copy = copy_id
                AND NOT h.frozen;
        

    --Count how many holds there are
    SELECT  COUNT( DISTINCT m.hold ) INTO hold_count
       FROM  action.hold_copy_map m
             JOIN action.hold_request h ON (m.hold = h.id)
       WHERE m.target_copy = copy_id
             AND NOT h.frozen;

    output.hold_count := hold_count;

    --Count how many holds looking at our copy would be allowed to be fulfilled by our copy (are valid competition for our copy)
    CREATE TEMPORARY TABLE competing_holds AS
        SELECT *
        FROM copy_holds_tmp
        WHERE (SELECT success FROM action.hold_request_permit_test(pickup_lib, request_lib, copy_id, usr, requestor) LIMIT 1);

    SELECT COUNT(*) INTO competing_hold_count
    FROM competing_holds;

    output.competing_hold_count := competing_hold_count;

    IF output.hold_count > 0 THEN

        --Get the total count separately in case the competing hold we find the available on is old and missed a target
        SELECT INTO output.copy_count COUNT(DISTINCT m.target_copy)
        FROM  action.hold_copy_map m
                JOIN asset.copy acp ON (m.target_copy = acp.id)
                JOIN action.hold_request h ON (m.hold = h.id)
        WHERE m.hold IN ( SELECT DISTINCT hold_copy_map.hold FROM action.hold_copy_map WHERE target_copy = copy_id ) 
        AND NOT h.frozen
        AND NOT acp.deleted;

        --'Available' means available to the same people, so we use the competing hold to test if it's available to them
        SELECT INTO hold * FROM competing_holds ORDER BY competing_holds.hold DESC LIMIT 1;

        --Assuming any competing hold can be placed on the same copies as every competing hold ; can't afford a nested loop
        --Could maybe be broken by a hold from a user with superpermissions ignoring age protections? Still using available status first as fallback.
        FOR copy IN
            SELECT DISTINCT m.target_copy AS id, acp.status
            FROM competing_holds c
                JOIN action.hold_copy_map m ON c.hold = m.hold
                JOIN asset.copy acp ON m.target_copy = acp.id
        LOOP
            --Check age protection by checking if the hold is permitted with hold_permit_test
            --Hopefully hold_matrix never needs to know if an item could circulate or there'd be an infinite loop
            IF (copy.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available)) AND
                (SELECT success FROM action.hold_request_permit_test(hold.pickup_lib, hold.request_lib, copy.id, hold.usr, hold.requestor) LIMIT 1) THEN
                    output.available_count := output.available_count + 1;
            END IF;
        END LOOP;

        output.total_copy_ratio = output.copy_count::FLOAT / output.hold_count::FLOAT;
        IF output.competing_hold_count > 0 THEN
            output.available_copy_ratio = output.available_count::FLOAT / output.competing_hold_count::FLOAT;
        END IF;
    END IF;
    
    --Clean up our temporary tables
    DROP TABLE copy_holds_tmp;
    DROP TABLE competing_holds;

    RETURN output;

END;
$func$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1432', :eg_version);

CREATE OR REPLACE FUNCTION vandelay.add_field ( target_xml TEXT, source_xml TEXT, field TEXT, force_add INT ) RETURNS TEXT AS $_$

    use MARC::Record;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;
    use strict;

    MARC::Charset->assume_unicode(1);

    my $target_xml = shift;
    my $source_xml = shift;
    my $field_spec = shift;
    my $force_add = shift || 0;

    my $target_r = MARC::Record->new_from_xml( $target_xml );
    my $source_r = MARC::Record->new_from_xml( $source_xml );

    return $target_xml unless ($target_r && $source_r);

    my @field_list = split(',', $field_spec);

    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                }
            }
        }
    }

    for my $f ( keys %fields) {
        if ( @{$fields{$f}{sf}} ) {
            for my $from_field ($source_r->field( $f )) {
                my @tos = $target_r->field( $f );
                if (!@tos) {
                    next if (exists($fields{$f}{match}) and !$force_add);
                    my @new_fields = map { $_->clone } $source_r->field( $f );
                    $target_r->insert_fields_ordered( @new_fields );
                } else {
                    for my $to_field (@tos) {
                        if (exists($fields{$f}{match})) {
                            my @match_list = grep { $to_field->subfield($_) =~ $fields{$f}{match}{$_} } keys %{$fields{$f}{match}};
                            next unless (scalar(@match_list) == scalar(keys %{$fields{$f}{match}}));
                        }
                        for my $old_sf ($from_field->subfields) {
                            $to_field->add_subfields( @$old_sf ) if grep(/$$old_sf[0]/,@{$fields{$f}{sf}});
                        }
                    }
                }
            }
        } else {
            my @new_fields = map { $_->clone } $source_r->field( $f );
            $target_r->insert_fields_ordered( @new_fields );
        }
    }

    $target_xml = $target_r->as_xml_record;
    $target_xml =~ s/^<\?.+?\?>$//mo;
    $target_xml =~ s/\n//sgo;
    $target_xml =~ s/>\s+</></sgo;

    return $target_xml;

$_$ LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION vandelay.replace_field 
    (target_xml TEXT, source_xml TEXT, field TEXT) RETURNS TEXT AS $_$

    use strict;
    use MARC::Record;
    use MARC::Field;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;

    MARC::Charset->assume_unicode(1);

    my $target_xml = shift;
    my $source_xml = shift;
    my $field_spec = shift;

    my $target_r = MARC::Record->new_from_xml($target_xml);
    my $source_r = MARC::Record->new_from_xml($source_xml);

    return $target_xml unless $target_r && $source_r;

    # Extract the field_spec components into MARC tags, subfields, 
    # and regex matches.  Copied wholesale from vandelay.strip_field()

    my @field_list = split(',', $field_spec);
    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                 }
            }
        }
    }

    # Returns a flat list of subfield (code, value, code, value, ...)
    # suitable for adding to a MARC::Field.
    sub generate_replacement_subfields {
        my ($source_field, $target_field, @controlled_subfields) = @_;

        # Performing a wholesale field replacment.  
        # Use the entire source field as-is.
        return map {$_->[0], $_->[1]} $source_field->subfields
            unless @controlled_subfields;

        my @new_subfields;

        # Iterate over all target field subfields:
        # 1. Keep uncontrolled subfields as is.
        # 2. Replace values for controlled subfields when a
        #    replacement value exists on the source record.
        # 3. Delete values for controlled subfields when no 
        #    replacement value exists on the source record.

        for my $target_sf ($target_field->subfields) {
            my $subfield = $target_sf->[0];
            my $target_val = $target_sf->[1];

            if (grep {$_ eq $subfield} @controlled_subfields) {
                if (my $source_val = $source_field->subfield($subfield)) {
                    # We have a replacement value
                    push(@new_subfields, $subfield, $source_val);
                } else {
                    # no replacement value for controlled subfield, drop it.
                }
            } else {
                # Field is not controlled.  Copy it over as-is.
                push(@new_subfields, $subfield, $target_val);
            }
        }

        # Iterate over all subfields in the source field and back-fill
        # any values that exist only in the source field.  Insert these
        # subfields in the same relative position they exist in the
        # source field.
                
        my @seen_subfields;
        for my $source_sf ($source_field->subfields) {
            my $subfield = $source_sf->[0];
            my $source_val = $source_sf->[1];
            push(@seen_subfields, $subfield);

            # target field already contains this subfield, 
            # so it would have been addressed above.
            next if $target_field->subfield($subfield);

            # Ignore uncontrolled subfields.
            next unless grep {$_ eq $subfield} @controlled_subfields;

            # Adding a new subfield.  Find its relative position and add
            # it to the list under construction.  Work backwards from
            # the list of already seen subfields to find the best slot.

            my $done = 0;
            for my $seen_sf (reverse(@seen_subfields)) {
                my $idx = @new_subfields;
                for my $new_sf (reverse(@new_subfields)) {
                    $idx--;
                    next if $idx % 2 == 1; # sf codes are in the even slots

                    if ($new_subfields[$idx] eq $seen_sf) {
                        splice(@new_subfields, $idx + 2, 0, $subfield, $source_val);
                        $done = 1;
                        last;
                    }
                }
                last if $done;
            }

            # if no slot was found, add to the end of the list.
            push(@new_subfields, $subfield, $source_val) unless $done;
        }

        return @new_subfields;
    }

    # MARC tag loop
    for my $f (keys %fields) {
        my $tag_idx = -1;
        my @target_fields = $target_r->field($f);

        if (!@target_fields and !defined($fields{$f}{match})) {
            # we will just add the source fields
            # unless they require a target match.
            my @add_these = map { $_->clone } $source_r->field($f);
            $target_r->insert_fields_ordered( @add_these );
        }

        for my $target_field (@target_fields) { # This will not run when the above "if" does.

            # field spec contains a regex for this field.  Confirm field on 
            # target record matches the specified regex before replacing.
            if (exists($fields{$f}{match})) {
                my @match_list = grep { $target_field->subfield($_) =~ $fields{$f}{match}{$_} } keys %{$fields{$f}{match}};
                next unless (scalar(@match_list) == scalar(keys %{$fields{$f}{match}}));
            }

            my @new_subfields;
            my @controlled_subfields = @{$fields{$f}{sf}};

            # If the target record has multiple matching bib fields,
            # replace them from matching fields on the source record
            # in a predictable order to avoid replacing with them with
            # same source field repeatedly.
            my @source_fields = $source_r->field($f);
            my $source_field = $source_fields[++$tag_idx];

            if (!$source_field && @controlled_subfields) {
                # When there are more target fields than source fields
                # and we are replacing values for subfields and not
                # performing wholesale field replacment, use the last
                # available source field as the input for all remaining
                # target fields.
                $source_field = $source_fields[$#source_fields];
            }

            if (!$source_field) {
                # No source field exists.  Delete all affected target
                # data.  This is a little bit counterintuitive, but is
                # backwards compatible with the previous version of this
                # function which first deleted all affected data, then
                # replaced values where possible.
                if (@controlled_subfields) {
                    $target_field->delete_subfield($_) for @controlled_subfields;
                } else {
                    $target_r->delete_field($target_field);
                }
                next;
            }

            my @new_subfields = generate_replacement_subfields(
                $source_field, $target_field, @controlled_subfields);

            # Build the replacement field from scratch.  
            my $replacement_field = MARC::Field->new(
                $target_field->tag,
                $target_field->indicator(1),
                $target_field->indicator(2),
                @new_subfields
            );

            $target_field->replace_with($replacement_field);
        }
    }

    $target_xml = $target_r->as_xml_record;
    $target_xml =~ s/^<\?.+?\?>$//mo;
    $target_xml =~ s/\n//sgo;
    $target_xml =~ s/>\s+</></sgo;

    return $target_xml;

$_$ LANGUAGE PLPERLU;

COMMIT;

-- Outside the transaction because the first change is.
SELECT evergreen.upgrade_deps_block_check('1433', :eg_version);

-- This has to happen outside the transaction that uses it below.
ALTER TYPE config.usr_activity_group ADD VALUE IF NOT EXISTS 'mfa';

BEGIN;


-- Permission seed data 
INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 657, 'REMOVE_USER_MFA', oils_i18n_gettext(657,
                    'Remove configured MFA factors for another user', 'ppl', 'description')),

    -- XXX Update the YAOUS update_perm below with the ADMIN_MFA permission id if it changes at commit time!!!
 ( 658, 'ADMIN_MFA', oils_i18n_gettext(658,
                    'Configure Multi-factor Authentication', 'ppl', 'description'))
;

INSERT INTO config.org_unit_setting_type ( name, label, description, datatype, grp, update_perm )
    VALUES (
        'auth.mfa_expire_interval',
        oils_i18n_gettext(
            'auth.mfa_expire_interval',
            'Security: MFA recheck interval',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'auth.mfa_expire_interval',
            'How long before MFA verification is required again, when MFA is required for a user.',
            'coust',
            'description'
        ),
        'interval',
        'sec',
        658 -- XXX Update this with the ADMIN_MFA permission id if that changes at commit time!!!
    );

-- A/T seed data
INSERT into action_trigger.hook (key, core_type, description) VALUES
( 'mfa.send_email', 'au', 'User has requested a One-Time MFA code by email'),
( 'mfa.send_sms', 'au', 'User has requested a One-Time MFA code by SMS');

INSERT INTO action_trigger.event_definition (active, owner, name, hook, validator, reactor, delay, template)
VALUES (
    't', 1, 'Send One-Time Password Email', 'mfa.send_email', 'NOOP_True', 'SendEmail', '00:00:00',
$$
[%- USE date -%]
[%- user = target -%]
[%- lib = target.home_ou -%]
To: [%- user_data.email %]
From: [%- helpers.get_org_setting(target.home_ou.id, 'org.bounced_emails') || lib.email || params.sender_email || default_sender %]
Date: [%- date.format(date.now, '%a, %d %b %Y %T -0000', gmt => 1) %]
Reply-To: [%- lib.email || params.sender_email || default_sender %]
Subject: Your Library One-Time access code
Auto-Submitted: auto-generated

Dear [% user.first_given_name %] [% user.family_name %],

We will never call to ask you for this code, and make sure you do not share it with anyone calling you directly.

Use this code to continue logging in to your Evergreen account:

One-Time code: [% user_data.otp_code %]

Sincerely,
[% user_data.issuer %] - [% lib.name %]

Contact your library for more information:

[% lib.name %]
[%- SET addr = lib.mailing_address -%]
[%- IF !addr -%] [%- SET addr = lib.billing_address -%] [%- END %]
[% addr.street1 %] [% addr.street2 %]
[% addr.city %], [% addr.state %]
[% addr.post_code %]
[% lib.phone %]
$$);

INSERT INTO action_trigger.environment (event_def, path)
VALUES (currval('action_trigger.event_definition_id_seq'), 'home_ou'),
       (currval('action_trigger.event_definition_id_seq'), 'home_ou.mailing_address'),
       (currval('action_trigger.event_definition_id_seq'), 'home_ou.billing_address');

INSERT INTO action_trigger.event_definition (active, owner, name, hook, validator, reactor, delay, template)
VALUES (
    't', 1, 'Send One-Time Password SMS', 'mfa.send_sms', 'NOOP_True', 'SendSMS', '00:00:00',
$$
[%- USE date -%]
[%- user = target -%]
[%- lib = user.home_ou -%]
From: [%- helpers.get_org_setting(target.home_ou.id, 'org.bounced_emails') || lib.email || params.sender_email || default_sender %]
To: [%- helpers.get_sms_gateway_email(user_data.carrier,user_data.phone) %]
Subject: One-Time code

Your [% user_data.issuer %] code is: [%user_data.otp_code %] $$);

INSERT INTO action_trigger.environment (event_def, path)
VALUES (currval('action_trigger.event_definition_id_seq'), 'home_ou');

-- New stuff!
CREATE TABLE IF NOT EXISTS config.mfa_factor (
    name        TEXT    PRIMARY KEY,
    label       TEXT    NOT NULL,
    description TEXT    NOT NULL
);

INSERT INTO config.mfa_factor (name, label, description) VALUES
  ('webauthn', 'Web Authentication API', 'Uses external Public Key credentials to confirm authentication'),
  ('totp', 'Time-based One-Time Password', 'For use with TOTP applications such as Google Authenticator'),
  ('email', 'One-Time Password by Email', 'Uses a dedicated MFA email address to confirm authentication'),
  ('sms', 'One-Time Password by SMS', 'Uses a dedicated MFA phone number and carrier to confirm authentication'),
  ('static', 'Pre-generated backup passwords', 'Confirms authentication via pre-shared One-Time passwords')
;

CREATE TABLE IF NOT EXISTS actor.usr_mfa_exception (
    id      SERIAL  PRIMARY KEY,
    usr     BIGINT  NOT NULL REFERENCES actor.usr (id) DEFERRABLE INITIALLY DEFERRED,
    ingress TEXT    -- disregard MFA requirement for specific ehow (ingress types, like 'sip2'), or NULL for all
); 

CREATE TABLE IF NOT EXISTS actor.usr_mfa_factor_map (
    id          SERIAL  PRIMARY KEY,
    usr         BIGINT  NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    factor      TEXT    NOT NULL REFERENCES config.mfa_factor (name) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    purpose     TEXT    NOT NULL DEFAULT 'mfa', -- mfa || login, for now
    add_time    TIMESTAMPTZ NOT NULL DEFAULT NOW()
); 
CREATE UNIQUE INDEX IF NOT EXISTS factor_purpose_usr_once ON actor.usr_mfa_factor_map (usr, purpose, factor);

CREATE TABLE IF NOT EXISTS permission.group_mfa_factor_map (
    id      SERIAL  PRIMARY KEY,
    grp     BIGINT  NOT NULL REFERENCES permission.grp_tree (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    factor  TEXT    NOT NULL REFERENCES config.mfa_factor (name) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

ALTER TABLE permission.grp_tree
    ADD COLUMN IF NOT EXISTS mfa_allowed BOOL NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS mfa_required BOOL NOT NULL DEFAULT FALSE;

INSERT INTO config.usr_activity_type (id, ewhat, egroup, label)
    VALUES (31, 'confirm', 'mfa', 'Generic MFA authentication confirmation')
    ;--ON CONFLICT DO NOTHING;

ALTER TABLE actor.usr_activity
    ADD COLUMN IF NOT EXISTS event_data TEXT;

DROP FUNCTION actor.insert_usr_activity(INT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION actor.insert_usr_activity(usr INT, ewho TEXT, ewhat TEXT, ehow TEXT, edata TEXT DEFAULT NULL)
 RETURNS SETOF actor.usr_activity
AS $f$
DECLARE
    new_row actor.usr_activity%ROWTYPE;
BEGIN
    SELECT id INTO new_row.etype FROM actor.usr_activity_get_type(ewho, ewhat, ehow);
    IF FOUND THEN
        new_row.usr := usr;
        new_row.event_data := edata;
        INSERT INTO actor.usr_activity (usr, etype, event_data)
            VALUES (usr, new_row.etype, new_row.event_data)
            RETURNING * INTO new_row;
        RETURN NEXT new_row;
    END IF;
END;
$f$ LANGUAGE plpgsql;

----- Support functions for encoding WebAuthn -----
CREATE OR REPLACE FUNCTION evergreen.gen_random_bytes_b64 (INT) RETURNS TEXT AS $f$
    SELECT encode(gen_random_bytes($1),'base64');
$f$ STRICT IMMUTABLE LANGUAGE SQL;


----- Support functions for encoding URLs -----
CREATE OR REPLACE FUNCTION evergreen.encode_base32 (TEXT) RETURNS TEXT AS $f$
  use MIME::Base32;
  my $input = shift;
  return encode_base32($input);
$f$ STRICT IMMUTABLE LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION evergreen.decode_base32 (TEXT) RETURNS TEXT AS $f$
  use MIME::Base32;
  my $input = shift;
  return decode_base32($input);
$f$ STRICT IMMUTABLE LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION evergreen.uri_escape (TEXT) RETURNS TEXT AS $f$
  use URI::Escape;
  my $input = shift;
  return uri_escape_utf8($input);
$f$ STRICT IMMUTABLE LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION evergreen.uri_unescape (TEXT) RETURNS TEXT AS $f$
  my $input = shift;
  $input =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg; # inline the RE, it is 700% faster than URI::Escape::uri_unescape
  return $input;
$f$ STRICT IMMUTABLE LANGUAGE PLPERLU;

----- Flags used to control OTP calculations -----
INSERT INTO config.global_flag (name, label, value, enabled) VALUES
    ('webauthn.mfa.issuer', 'WebAuthn Relying Party name for multi-factor authentication', 'Evergreen WebAuthn', TRUE),
    ('webauthn.mfa.domain', 'WebAuthn Relying Party domain (optional base domain) for multi-factor authentication', '', TRUE),
    ('webauthn.mfa.digits', 'WebAuthn challenge size (bytes)', '16', TRUE),
    ('webauthn.mfa.period', 'WebAuthn challenge timeout (seconds)', '60', TRUE), -- 1 minute for WebAuthn
    ('webauthn.mfa.multicred', 'If Enabled, allows a user to register multiple multi-factor login WebAuthn verification devices', NULL, TRUE),
    ('webauthn.login.issuer', 'WebAuthn Relying Party name for single-factor login', 'Evergreen WebAuthn', TRUE),
    ('webauthn.login.domain', 'WebAuthn Relying Party domain (optional base domain) for single-factor login', '', TRUE),
    ('webauthn.login.digits', 'WebAuthn single-factor login challenge size (bytes)', '16', TRUE),
    ('webauthn.login.period', 'WebAuthn single-factor login challenge timeout (seconds)', '60', TRUE),
    ('webauthn.login.multicred', 'If Enabled, allows a user to register multiple single-factor login WebAuthn verification devices', NULL, TRUE),
    ('totp.mfa.issuer', 'TOTP Issuer string for multi-factor authentication', 'Evergreen-MFA', TRUE),
    ('totp.mfa.digits', 'TOTP code length (Google Authenticator supports only 6)', '6', TRUE),
    ('totp.mfa.algorithm', 'TOTP code generation algorithm (Google Authenticator supports only SHA1)', 'SHA1', TRUE),
    ('totp.mfa.period', 'TOTP code validity period in seconds  (Google Authenticator supports only 30)', '30', TRUE), -- 30 seconds for totp, but remember, fuzziness!
    ('totp.login.issuer', 'TOTP Issuer string for single-factor login', 'Evergreen-Login', TRUE),
    ('totp.login.digits', 'TOTP code length (Google Authenticator supports only 6)', '6', TRUE),
    ('totp.login.algorithm', 'TOTP code generation algorithm (Google Authenticator supports only SHA1)', 'SHA1', TRUE),
    ('totp.login.period', 'TOTP code validity period in seconds  (Google Authenticator supports only 30)', '30', TRUE),
    ('email.mfa.issuer', 'Email Issuer string for multi-factor authentication', 'Evergreen-MFA', TRUE),
    ('email.mfa.digits', 'Email One-Time code length for multi-factor authentication; max: 8', '6', TRUE),
    ('email.mfa.algorithm', 'Email One-Time code algorithm for multi-factor authentication: SHA1, SHA256, SHA512', 'SHA1', TRUE),
    ('email.mfa.period', 'Email One-Time validity period for multi-factor authentication in seconds (default: 30 minutes)', '1800', TRUE), -- 30 minutes for email
    ('email.login.issuer', 'Email Issuer string for single-factor login', 'Evergreen-Login', TRUE),
    ('email.login.digits', 'Email One-Time code length for single-factor login; max: 8', '6', TRUE),
    ('email.login.algorithm', 'Email One-Time code algorithm for single-factor login: SHA1, SHA256, SHA512', 'SHA1', TRUE),
    ('email.login.period', 'Email One-Time validity period for single-factor login in seconds (default: 30 minutes)', '1800', TRUE),
    ('sms.mfa.issuer', 'SMS Issuer string for multi-factor authentication', 'Evergreen-MFA', TRUE),
    ('sms.mfa.digits', 'SMS One-Time code length for multi-factor authentication; max: 8', '6', TRUE),
    ('sms.mfa.algorithm', 'SMS One-Time code algorithm for multi-factor authentication: SHA1, SHA256, SHA512', 'SHA1', TRUE),
    ('sms.mfa.period', 'SMS One-Time validity period for multi-factor authentication in seconds (default: 15 minutes)', '900', TRUE), -- 15 minutes for SMS
    ('sms.login.issuer', 'SMS Issuer string for single-factor login', 'Evergreen-Login', TRUE),
    ('sms.login.digits', 'SMS One-Time code length for single-factor login; max: 8', '6', TRUE),
    ('sms.login.algorithm', 'SMS One-Time code algorithm for single-factor login: SHA1, SHA256, SHA512', 'SHA1', TRUE),
    ('sms.login.period', 'SMS One-Time validity period for single-factor login in seconds (default: 15 minutes)', '900', TRUE)
;

----- Password types to support secondary factors -----
INSERT INTO actor.passwd_type (code, name) VALUES
    ('email-mfa', 'Time-base One-Time Password Secret for multi-factor authentication via EMail'),
    ('email-login', 'Time-base One-Time Password Secret for single-factor login via EMail'),
    ('sms-mfa', 'Time-base One-Time Password Secret for multi-factor authentication via SMS'),
    ('sms-login', 'Time-base One-Time Password Secret for single-factor login via SMS'),
    ('totp-mfa', 'Time-base One-Time Password Secret for multi-factor authentication'),
    ('totp-login', 'Time-base One-Time Password Secret for single-factor login'),
    ('webauthn-mfa', 'WebAuthn data for multi-factor authentication'),
    ('webauthn-login', 'WebAuthn data for single-factor login')
;

----- OTP URI destroyer: Removes the TOTP password entry if the user knows the secret NOW -----
CREATE OR REPLACE FUNCTION actor.remove_otpauth_uri(
    usr_id INT,
    otype TEXT,
    purpose TEXT,
    proof TEXT,
    fuzziness INT DEFAULT 1
) RETURNS BOOL AS $f$

use Pass::OTP;
use Pass::OTP::URI;

my $usr_id = shift;
my $otype = shift;
my $purpose = shift;
my $proof = shift;
my $fuzziness_width = shift // 1;

if ($otype eq 'webauthn') { # nothing to prove
    my $waq = spi_prepare('DELETE FROM actor.passwd WHERE usr = $1 AND passwd_type = $2 || $$-$$ || $3;', 'INTEGER', 'TEXT', 'TEXT');
    my $res = spi_exec_prepared($waq, $usr_id, $otype, $purpose);
    spi_freeplan($waq);
    return 1;
}

# Normalize the proof value
$proof =~ s/\D//g;
return 0 unless $proof; # all-0s is not valid

my $q = spi_prepare('SELECT actor.otpauth_uri($1, $2, $3) AS uri;', 'INTEGER', 'TEXT', 'TEXT');
my $otp_uri = spi_exec_prepared($q, {limit => 1}, $usr_id, $otype, $purpose)->{rows}[0]{uri};
spi_freeplan($q);

return 0 unless $otp_uri;

my %otp_config = Pass::OTP::URI::parse($otp_uri);

for my $fuzziness ( -$fuzziness_width .. $fuzziness_width ) {
    $otp_config{'start-time'} = $otp_config{period} * $fuzziness;
    my $otp_code = Pass::OTP::otp(%otp_config);
    if ($otp_code eq $proof) {
        $q = spi_prepare('DELETE FROM actor.passwd WHERE usr = $1 AND passwd_type = $2 || $$-$$ || $3;', 'INTEGER', 'TEXT', 'TEXT');
        my $res = spi_exec_prepared($q, $usr_id, $otype, $purpose);
        spi_freeplan($q);
        return 1;
    }
}

return 0;
$f$ LANGUAGE PLPERLU;

----- OTP proof generator: find the TOTP code, optionally with fuzziness -----
CREATE OR REPLACE FUNCTION actor.otpauth_uri_get_proof(
    otp_uri TEXT,
    fuzziness INT DEFAULT 0
) RETURNS TABLE ( period_step INT, proof TEXT) AS $f$

use Pass::OTP;
use Pass::OTP::URI;

my $otp_uri = shift;
my $fuzziness_width = shift // 0;

return undef unless $otp_uri;

my %otp_config = Pass::OTP::URI::parse($otp_uri);
return undef unless $otp_config{type};

for my $fuzziness ( -$fuzziness_width .. $fuzziness_width ) {
    $otp_config{'start-time'} = $otp_config{period} * $fuzziness;
    return_next({period_step => $fuzziness, proof => Pass::OTP::otp(%otp_config)});
}

return undef;

$f$ LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION actor.otpauth_uri_get_proof(
    usr_id INT,
    otype TEXT,
    purpose TEXT,
    fuzziness INT DEFAULT 0
) RETURNS TABLE ( period_step INT, proof TEXT) AS $f$
BEGIN
    RETURN QUERY
      SELECT * FROM actor.otpauth_uri_get_proof( actor.otpauth_uri($1, $2, $3), $4 );
    RETURN;
END;
$f$ LANGUAGE PLPGSQL;

----- TOTP URI generator: Saves the secret on the first call for each user ID -----
CREATE OR REPLACE FUNCTION actor.otpauth_uri(
    usr_id INT,
    otype TEXT DEFAULT 'totp',
    purpose TEXT DEFAULT 'mfa',
    additional_params HSTORE DEFAULT ''::HSTORE -- this can be used to pass a start-time parameter to offset totp calc
) RETURNS TEXT AS $f$
DECLARE
    issuer      TEXT := 'Evergreen';
    algorithm   TEXT := 'SHA1';
    digits      TEXT := '6';
    period      TEXT := '30';
    counter     TEXT := '0';
    otp_secret  TEXT;
    otp_params  HSTORE;
    uri         TEXT;
    param_name  TEXT;
    uri_otype  TEXT;
BEGIN

    IF additional_params IS NULL THEN additional_params = ''::HSTORE; END IF;

    -- we're going to be a bit strict here, for now
    IF otype NOT IN ('webauthn','email','sms','totp','hotp') THEN RETURN NULL; END IF;
    IF purpose NOT IN ('mfa','login') THEN RETURN NULL; END IF;

    uri_otype := otype;
    IF otype NOT IN ('totp','hotp') THEN
        uri_otype := 'totp'; -- others are time-based, but with different settings
    END IF;

    -- protect "our" keys
    additional_params := additional_params - ARRAY['issuer','algorithm','digits','period'];

    SELECT passwd, salt::HSTORE INTO otp_secret, otp_params FROM actor.passwd WHERE usr = usr_id AND passwd_type = otype || '-' || purpose;

    IF NOT FOUND THEN

        issuer := COALESCE(
            (SELECT value FROM config.internal_flag WHERE name = otype||'.'||purpose||'.issuer' AND enabled),
            issuer
        );

        algorithm := COALESCE(
            (SELECT value FROM config.internal_flag WHERE name = otype||'.'||purpose||'.algorithm' AND enabled),
            algorithm
        );

        digits := COALESCE(
            (SELECT value FROM config.internal_flag WHERE name = otype||'.'||purpose||'.digits' AND enabled),
            digits
        );

        period := COALESCE(
            (SELECT value FROM config.internal_flag WHERE name = otype||'.'||purpose||'.period' AND enabled),
            period
        );

        otp_params := HSTORE('counter', counter)
                      || HSTORE('issuer', issuer)
                      || HSTORE('algorithm', UPPER(algorithm))
                      || HSTORE('digits', digits)
                      || HSTORE('period', period);

        IF additional_params ? 'counter' THEN
            otp_params := otp_params - 'counter';
        END IF;

        otp_params := additional_params || otp_params;

        WITH new_secret AS (
            INSERT INTO actor.passwd (usr, salt, passwd, passwd_type)
                VALUES (usr_id, otp_params::TEXT, gen_random_uuid()::TEXT, otype || '-' || purpose)
                RETURNING passwd, salt
        ) SELECT passwd, salt::HSTORE INTO otp_secret, otp_params FROM new_secret;

    ELSE
        otp_params := otp_params - akeys(additional_params); -- remove what we're receiving
        otp_params := additional_params || otp_params;
        IF additional_params != ''::HSTORE THEN -- new additional params were passed, let's save the salt again
            UPDATE actor.passwd SET salt = otp_params::TEXT WHERE usr = usr_id AND passwd_type = otype || '-' || purpose;
        END IF;
    END IF;


    uri :=  'otpauth://' || uri_otype || '/' || evergreen.uri_escape(otp_params -> 'issuer') || ':' || usr_id::TEXT
            ||'?secret='    || evergreen.encode_base32(otp_secret);

    FOREACH param_name IN ARRAY akeys(otp_params) LOOP
        uri := uri || '&' || evergreen.uri_escape(param_name) || '=' || evergreen.uri_escape(otp_params -> param_name);
    END LOOP;

    RETURN uri;
END;
$f$ LANGUAGE PLPGSQL;

COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1434', :eg_version); 

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('scko_items_out', 'Self-Checkout Items Out', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[%- 
    USE date;
    SET user = template_data.user;
    SET checkouts = template_data.checkouts;
-%]
<div>
  <style> li { padding: 8px; margin 5px; }</style>
  <div>[% date.format(date.now, '%x %r') %]</div>
  <br/>

  [% user.pref_family_name || user.family_name %], 
  [% user.pref_first_given_name || user.first_given_name %]

  <ol>
  [% FOR checkout IN checkouts %]
    <li>
      <div>[% checkout.title %]</div>
      <div>Barcode: [% checkout.copy.barcode %]</div>
      <div>Due Date: [% 
        date.format(helpers.format_date(
            checkout.circ.due_date, staff_org_timezone), '%x %r') 
      %]
      </div>
    </li>
  [% END %]
  </ol>
</div>
$TEMPLATE$ WHERE name = 'scko_items_out';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('scko_holds', 'Self-Checkout Holds', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[%- 
    USE date;
    SET user = template_data.user;
    SET holds = template_data.holds;
-%]
<div>
  <style> li { padding: 8px; margin 5px; }</style>
  <div>[% date.format(date.now, '%x %r') %]</div>
  <br/>

  [% user.pref_family_name || user.family_name %], 
  [% user.pref_first_given_name || user.first_given_name %]

  <ol>
  [% FOR hold IN holds %]
    <li>
      <table>
        <tr>
          <td>Title:</td>
          <td>[% hold.title %]</td>
        </tr>
        <tr>
          <td>Author:</td>
          <td>[% hold.author %]</td>
        </tr>
        <tr>
          <td>Pickup Location:</td>
          <td>[% helpers.get_org_unit(hold.pickup_lib).name %]</td>
        </tr>
        <tr>
          <td>Status:</td>
          <td>
            [%- IF hold.ready -%]
                Ready for pickup
            [% ELSE %]
                #[% hold.relative_queue_position %] of [% hold.potentials %] copies.
            [% END %]
          </td>
        </tr>
      </table>
    </li>
  [% END %]
  </ol>
</div>
$TEMPLATE$ WHERE name = 'scko_holds';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('scko_fines', 'Self-Checkout Fines', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[%- 
    USE date;
    USE money = format('$%.2f');
    SET user = template_data.user;
    SET xacts = template_data.xacts;
-%]
<div>
  <style> li { padding: 8px; margin 5px; }</style>
  <div>[% date.format(date.now, '%x %r') %]</div>
  <br/>

  [% user.pref_family_name || user.family_name %], 
  [% user.pref_first_given_name || user.first_given_name %]

  <ol>
  [% FOR xact IN xacts %]
    [% NEXT IF xact.balance_owed <= 0 %]
    <li>
      <table>
        <tr>
          <td>Details:</td>
          <td>[% xact.details %]</td>
        </tr>
        <tr>
          <td>Total Billed:</td>
          <td>[% money(xact.total_owed) %]</td>
        </tr>
        <tr>
          <td>Total Paid:</td>
          <td>[% money(xact.total_paid) %]</td>
        </tr>
        <tr>
          <td>Balance Owed:</td>
          <td>[% money(xact.balance_owed) %]</td>
        </tr>
      </table>
    </li>
  [% END %]
  </ol>
</div>
$TEMPLATE$ WHERE name = 'scko_fines';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('scko_checkouts', 'Self-Checkout Checkouts', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[%- 
    USE date;
    SET user = template_data.user;
    SET checkouts = template_data.checkouts;
    SET lib = staff_org;
    SET hours = lib.hours_of_operation;
    SET lib_addr = staff_org.billing_address || staff_org.mailing_address;
-%]
<div>
  <style> li { padding: 8px; margin 5px; }</style>
  <div>[% date.format(date.now, '%x %r') %]</div>
  <div>[% lib.name %]</div>
  <div>[% lib_addr.street1 %] [% lib_addr.street2 %]</div>
  <div>[% lib_addr.city %], [% lib_addr.state %] [% lib_addr.post_code %]</div>
  <div>[% lib.phone %]</div>
  <br/>

  [% user.pref_family_name || user.family_name %], 
  [% user.pref_first_given_name || user.first_given_name %]

  <ol>
  [% FOR checkout IN checkouts %]
    <li>
      <div>[% checkout.title %]</div>
      <div>Barcode: [% checkout.barcode %]</div>

      [% IF checkout.ctx.renewalFailure %]
      <div style="color:red;">Renewal Failed</div>
      [% END %]

      <div>Due Date: [% date.format(helpers.format_date(
        checkout.circ.due_date, staff_org_timezone), '%x') %]</div>
    </li>
  [% END %]
  </ol>

  <div>
    Library Hours
    [%- 
        BLOCK format_time;
          IF time;
            date.format(time _ ' 1/1/1000', format='%I:%M %p');
          END;
        END
    -%]
    <div>
      Monday 
      [% PROCESS format_time time = hours.dow_0_open %] 
      [% PROCESS format_time time = hours.dow_0_close %] 
    </div>
    <div>
      Tuesday 
      [% PROCESS format_time time = hours.dow_1_open %] 
      [% PROCESS format_time time = hours.dow_1_close %] 
    </div>
    <div>
      Wednesday 
      [% PROCESS format_time time = hours.dow_2_open %] 
      [% PROCESS format_time time = hours.dow_2_close %] 
    </div>
    <div>
      Thursday
      [% PROCESS format_time time = hours.dow_3_open %] 
      [% PROCESS format_time time = hours.dow_3_close %] 
    </div>
    <div>
      Friday
      [% PROCESS format_time time = hours.dow_4_open %] 
      [% PROCESS format_time time = hours.dow_4_close %] 
    </div>
    <div>
      Saturday
      [% PROCESS format_time time = hours.dow_5_open %] 
      [% PROCESS format_time time = hours.dow_5_close %] 
    </div>
    <div>
      Sunday 
      [% PROCESS format_time time = hours.dow_6_open %] 
      [% PROCESS format_time time = hours.dow_6_close %] 
    </div>
  </div>

</div>
$TEMPLATE$ WHERE name = 'scko_checkouts';


COMMIT;


BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1435', :eg_version);

-- 002.schema.config.sql

-- this may grow to support full GNU gettext functionality
CREATE TABLE config.i18n_string (
    id              SERIAL      PRIMARY KEY,
    context         TEXT        NOT NULL, -- hint for translators to disambiguate
    string          TEXT        NOT NULL
);

-- 950.data.seed-values.sql

INSERT INTO config.i18n_string (id, context, string) VALUES (1,
    oils_i18n_gettext(
        1, 'In the Place Hold interfaces for staff and patrons; when monographic parts are available, this string provides contextual information about whether and how parts are considered for holds that do not request a specific mongraphic part.',
        'i18ns','context'
    ),
    oils_i18n_gettext(
        1, 'All Parts',
        'i18ns','string'
    )
);
SELECT SETVAL('config.i18n_string_id_seq', 10000); -- reserve some for stock EG interfaces

COMMIT;
BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1436', :eg_version);

CREATE OR REPLACE FUNCTION evergreen.direct_opt_in_check(
    patron_id   INT,
    staff_id    INT, -- patron must be opted in (directly or implicitly) to one of the staff's working locations
    permlist    TEXT[] DEFAULT '{}'::TEXT[] -- if passed, staff must ADDITIONALLY possess at least one of these permissions at an opted-in location
) RETURNS BOOLEAN AS $f$
DECLARE
    default_boundary    INT;
    org_depth           INT;
    patron              actor.usr%ROWTYPE;
    staff               actor.usr%ROWTYPE;
    patron_visible_at   INT[];
    patron_hard_wall    INT[];
    staff_orgs          INT[];
    current_staff_org   INT;
    passed_optin        BOOL;
BEGIN
    passed_optin := FALSE;

    SELECT * INTO patron FROM actor.usr WHERE id = patron_id;
    SELECT * INTO staff FROM actor.usr WHERE id = staff_id;

    IF patron.id IS NULL OR staff.id IS NULL THEN
        RETURN FALSE;
    END IF;

    -- get the hard wall, if any
    SELECT oils_json_to_text(value)::INT INTO default_boundary
      FROM actor.org_unit_ancestor_setting('org.restrict_opt_to_depth', patron.home_ou);

    IF default_boundary IS NULL THEN default_boundary := 0; END IF;

    IF default_boundary = 0 THEN -- common case
        SELECT ARRAY_AGG(id) INTO patron_hard_wall FROM actor.org_unit;
    ELSE
        -- Patron opt-in scope(s), including home_ou from default_boundary depth
        SELECT  ARRAY_AGG(id) INTO patron_hard_wall
          FROM  actor.org_unit_descendants(patron.home_ou, default_boundary);
    END IF;

    -- gather where the patron has opted in, and their home
    SELECT  COALESCE(ARRAY_AGG(DISTINCT aoud.id),'{}') INTO patron_visible_at
      FROM  actor.usr_org_unit_opt_in auoi
            JOIN LATERAL actor.org_unit_descendants(auoi.org_unit) aoud ON TRUE
      WHERE auoi.usr = patron.id;

    patron_visible_at := patron_visible_at || patron.home_ou;

    <<staff_org_loop>>
    FOR current_staff_org IN SELECT work_ou FROM permission.usr_work_ou_map WHERE usr = staff.id LOOP

        SELECT oils_json_to_text(value)::INT INTO org_depth
          FROM actor.org_unit_ancestor_setting('org.patron_opt_boundary', current_staff_org);

        IF FOUND THEN
            SELECT ARRAY_AGG(DISTINCT id) INTO staff_orgs FROM actor.org_unit_descendants(current_staff_org,org_depth);
        ELSE
            SELECT ARRAY_AGG(DISTINCT id) INTO staff_orgs FROM actor.org_unit_descendants(current_staff_org);
        END IF;

        -- If this staff org (adjusted) isn't at least partly inside the allowed range, move on.
        IF NOT (staff_orgs && patron_hard_wall) THEN CONTINUE staff_org_loop; END IF;

        -- If this staff org (adjusted) overlaps with the patron visibility list
        IF staff_orgs && patron_visible_at THEN passed_optin := TRUE; EXIT staff_org_loop; END IF;

    END LOOP staff_org_loop;

    -- does the staff member have a requested permission where the patron lives or has opted in?
    IF passed_optin AND cardinality(permlist) > 0 THEN
        SELECT  ARRAY_AGG(id) INTO staff_orgs
          FROM  UNNEST(permlist) perms (p)
                JOIN LATERAL permission.usr_has_perm_at_all(staff.id, perms.p) perms_at (id) ON TRUE;

        passed_optin := COALESCE(staff_orgs && patron_visible_at, FALSE);
    END IF;

    RETURN passed_optin;

END;
$f$ STABLE LANGUAGE PLPGSQL;

-- This function defaults to RESTRICTING access to data if applied to
-- a table/class that it does not explicitly know how to handle.
CREATE OR REPLACE FUNCTION evergreen.hint_opt_in_check(
    hint_val    TEXT,
    pkey_val    BIGINT, -- pkey value of the hinted row
    staff_id    INT,
    permlist    TEXT[] DEFAULT '{}'::TEXT[] -- if passed, staff must ADDITIONALLY possess at least one of these permissions at an opted-in location
) RETURNS BOOLEAN AS $f$
BEGIN
    CASE hint_val
        WHEN 'aua' THEN
            RETURN evergreen.direct_opt_in_check((SELECT usr FROM actor.usr_address WHERE id = pkey_val LIMIT 1), staff_id, permlist);
        WHEN 'auact' THEN
            RETURN evergreen.direct_opt_in_check((SELECT usr FROM actor.usr_activity WHERE id = pkey_val LIMIT 1), staff_id, permlist);
        WHEN 'aus' THEN
            RETURN evergreen.direct_opt_in_check((SELECT usr FROM actor.usr_setting WHERE id = pkey_val LIMIT 1), staff_id, permlist);
        WHEN 'actscecm' THEN
            RETURN evergreen.direct_opt_in_check((SELECT target_usr FROM actor.stat_cat_entry_usr_map WHERE id = pkey_val LIMIT 1), staff_id, permlist);
        WHEN 'ateo' THEN
            RETURN evergreen.direct_opt_in_check(
                (SELECT e.context_user FROM action_trigger.event e JOIN action_trigger.event_output eo ON (eo.event = e.id) WHERE eo.id = pkey_val LIMIT 1),
                staff_id,
                permlist
            );
        ELSE
            RETURN FALSE;
    END CASE;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION evergreen.redact_value(
    input_data      anyelement,
    skip_redaction  BOOLEAN     DEFAULT FALSE,  -- pass TRUE for "I passed the test!" and avoid redaction
    redact_with     anyelement  DEFAULT NULL
) RETURNS anyelement AS $f$
DECLARE
    result ALIAS FOR $0;
BEGIN
    IF skip_redaction THEN
        result := input_data;
    ELSE
        result := redact_with;
    END IF;

    RETURN result;
END;
$f$ STABLE LANGUAGE PLPGSQL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1437', :eg_version);

INSERT INTO config.org_unit_setting_type
    (grp, name, datatype, label, description)
VALUES (
    'holds',
    'circ.holds.adjacent_target_while_stalling', 'bool',
    oils_i18n_gettext(
        'circ.holds.adjacent_target_while_stalling',
        'Allow adjacent copies to capture when Soft Stalling',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'circ.holds.adjacent_target_while_stalling',
        'Allow adjacent copies at the targeted library to capture when Soft Stalling interval is set',
        'coust',
        'description'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1438', :eg_version);

ALTER TABLE biblio.monograph_part
    ADD COLUMN creator INTEGER DEFAULT 1,
    ADD COLUMN editor INTEGER DEFAULT 1,
    ADD COLUMN create_date TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN edit_date TIMESTAMPTZ DEFAULT now();

UPDATE biblio.monograph_part SET creator=1, editor=1, create_date=now(),edit_date=now();

ALTER TABLE biblio.monograph_part
    ALTER COLUMN creator SET NOT NULL,
    ALTER COLUMN editor SET NOT NULL,
    ALTER COLUMN create_date SET NOT NULL,
    ALTER COLUMN edit_date SET NOT NULL;

COMMIT;BEGIN;

SELECT evergreen.upgrade_deps_block_check('1439', :eg_version);

-- Use oils_xpath_table instead of pgxml's xpath_table
CREATE OR REPLACE FUNCTION acq.extract_holding_attr_table (lineitem int, tag text) RETURNS SETOF acq.flat_lineitem_holding_subfield AS $$
DECLARE
    counter INT;
    lida    acq.flat_lineitem_holding_subfield%ROWTYPE;
BEGIN

    SELECT  COUNT(*) INTO counter
      FROM  oils_xpath_table(
                'id',
                'marc',
                'acq.lineitem',
                '//*[@tag="' || tag || '"]',
                'id=' || lineitem
            ) as t(i int,c text);

    FOR i IN 1 .. counter LOOP
        FOR lida IN
            SELECT  *
              FROM  (   SELECT  id,i,t,v
                          FROM  oils_xpath_table(
                                    'id',
                                    'marc',
                                    'acq.lineitem',
                                    '//*[@tag="' || tag || '"][position()=' || i || ']/*[text()]/@code|' ||
                                        '//*[@tag="' || tag || '"][position()=' || i || ']/*[@code and text()]',
                                    'id=' || lineitem
                                ) as t(id int,t text,v text)
                    )x
        LOOP
            RETURN NEXT lida;
        END LOOP;
    END LOOP;

    RETURN;
END;
$$ LANGUAGE PLPGSQL;


COMMIT;
BEGIN;

-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1440', :eg_version);

CREATE TABLE config.patron_loader_header_map (
    id SERIAL,
    org_unit INTEGER NOT NULL,
    import_header TEXT NOT NULL,
    default_header TEXT NOT NULL
);
ALTER TABLE config.patron_loader_header_map ADD CONSTRAINT config_patron_loader_header_map_org_fkey FOREIGN KEY (org_unit) REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE config.patron_loader_value_map (
    id SERIAL,
    org_unit INTEGER NOT NULL,
    mapping_type TEXT NOT NULL,
    import_value TEXT NOT NULL,
    native_value TEXT NOT NULL
);
ALTER TABLE config.patron_loader_value_map ADD CONSTRAINT config_patron_loader_value_map_org_fkey FOREIGN KEY (org_unit) REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE actor.patron_loader_log (
    id SERIAL,
    session BIGINT,
    org_unit INTEGER NOT NULL,
    event TEXT,
    record_count INTEGER,
    logtime TIMESTAMP DEFAULT NOW()
);
ALTER TABLE actor.patron_loader_log ADD CONSTRAINT actor_patron_loader_log_org_fkey FOREIGN KEY (org_unit) REFERENCES actor.org_unit (id) DEFERRABLE INITIALLY DEFERRED;

COMMIT;
-- Add bib bucket related columns to reporter.schedule

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1441', :eg_version);

ALTER TABLE reporter.schedule ADD COLUMN new_record_bucket BOOL NOT NULL DEFAULT 'false';
ALTER TABLE reporter.schedule ADD COLUMN existing_record_bucket BOOL NOT NULL DEFAULT 'false';

CREATE TABLE container.biblio_record_entry_bucket_shares (
    id          SERIAL      PRIMARY KEY,
    bucket      INT         NOT NULL REFERENCES container.biblio_record_entry_bucket (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
    share_org   INT         NOT NULL REFERENCES actor.org_unit (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT brebs_org_once_per_bucket UNIQUE (bucket, share_org)
);

CREATE TYPE container.usr_flag_type AS ENUM ('favorite');
CREATE TABLE container.biblio_record_entry_bucket_usr_flags (
    id          SERIAL      PRIMARY KEY,
    bucket      INT         NOT NULL REFERENCES container.biblio_record_entry_bucket (id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
    usr         INT         NOT NULL REFERENCES actor.usr (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    flag        container.usr_flag_type NOT NULL DEFAULT 'favorite',
    CONSTRAINT brebs_flag_once_per_usr_per_bucket UNIQUE (bucket, usr, flag)
);

-- Add settings for record bucket interfaces

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.catalog.record_buckets', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.record_buckets',
        'Grid Config: catalog.record_buckets',
        'cwst', 'label'
    )
), (
    'eg.grid.catalog.record_bucket.content', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.record_bucket.content',
        'Grid Config: catalog.record_bucket.content',
        'cwst', 'label'
    )
), (
    'eg.grid.filters.catalog.record_buckets', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.filters.catalog.record_buckets',
        'Grid Filters: catalog.record_buckets',
        'cwst', 'label'
    )
), (
    'eg.grid.filters.catalog.record_bucket.content', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.filters.catalog.record_bucket.content',
        'Grid Filters: catalog.record_bucket.content',
        'cwst', 'label'
    )
), (
    'eg.grid.buckets.user_shares', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.buckets.user_shares',
        'Grid Config: eg.grid.buckets.user_shares',
        'cwst', 'label'
    )
);

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   659,
   'TRANSFER_CONTAINER',
   oils_i18n_gettext(659,
     'Allow for transferring ownership of a bucket.', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'TRANSFER_CONTAINER');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   660,
   'ADMIN_CONTAINER_BIBLIO_RECORD_ENTRY_USER_SHARE',
   oils_i18n_gettext(660,
     'Allow sharing of record buckets with specific users', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_BIBLIO_RECORD_ENTRY_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   661,
   'ADMIN_CONTAINER_CALL_NUMBER_USER_SHARE',
   oils_i18n_gettext(661,
     'Allow sharing of call number buckets with specific users', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_CALL_NUMBER_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   662,
   'ADMIN_CONTAINER_COPY_USER_SHARE',
   oils_i18n_gettext(662,
     'Allow sharing of copy buckets with specific users', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_COPY_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   663,
   'ADMIN_CONTAINER_USER_USER_SHARE',
   oils_i18n_gettext(663,
     'Allow sharing of user buckets with specific users', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_USER_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   664,
   'VIEW_CONTAINER_BIBLIO_RECORD_ENTRY_USER_SHARE',
   oils_i18n_gettext(664,
     'Allow viewing of record bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_BIBLIO_RECORD_ENTRY_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   665,
   'VIEW_CONTAINER_CALL_NUMBER_USER_SHARE',
   oils_i18n_gettext(665,
     'Allow viewing of call number bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_CALL_NUMBER_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   666,
   'VIEW_CONTAINER_COPY_USER_SHARE',
   oils_i18n_gettext(666,
     'Allow viewing of copy bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_COPY_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   667,
   'VIEW_CONTAINER_USER_USER_SHARE',
   oils_i18n_gettext(667,
     'Allow viewing of user bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_USER_USER_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   668,
   'ADMIN_CONTAINER_BIBLIO_RECORD_ENTRY_ORG_SHARE',
   oils_i18n_gettext(668,
     'Allow sharing of record buckets with specific orgs', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_BIBLIO_RECORD_ENTRY_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   669,
   'ADMIN_CONTAINER_CALL_NUMBER_ORG_SHARE',
   oils_i18n_gettext(669,
     'Allow sharing of call number buckets with specific orgs', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_CALL_NUMBER_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   670,
   'ADMIN_CONTAINER_COPY_ORG_SHARE',
   oils_i18n_gettext(670,
     'Allow sharing of copy buckets with specific orgs', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_COPY_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   671,
   'ADMIN_CONTAINER_USER_ORG_SHARE',
   oils_i18n_gettext(671,
     'Allow sharing of user buckets with specific orgs', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'ADMIN_CONTAINER_USER_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   672,
   'VIEW_CONTAINER_BIBLIO_RECORD_ENTRY_ORG_SHARE',
   oils_i18n_gettext(672,
     'Allow viewing of record bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_BIBLIO_RECORD_ENTRY_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   673,
   'VIEW_CONTAINER_CALL_NUMBER_ORG_SHARE',
   oils_i18n_gettext(673,
     'Allow viewing of call number bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_CALL_NUMBER_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   674,
   'VIEW_CONTAINER_COPY_ORG_SHARE',
   oils_i18n_gettext(674,
     'Allow viewing of copy bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_COPY_ORG_SHARE');

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   675,
   'VIEW_CONTAINER_USER_ORG_SHARE',
   oils_i18n_gettext(675,
     'Allow viewing of user bucket user shares', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'VIEW_CONTAINER_USER_ORG_SHARE');

UPDATE  config.ui_staff_portal_page_entry
  SET   target_url = '/eg2/staff/cat/bucket/record'
  WHERE id = 7
        AND entry_type = 'menuitem'
        AND target_url = '/eg/staff/cat/bucket/record/'
;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1442', :eg_version);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'eg.staff.catalog.results.show_sidebar',
    'gui',
    oils_i18n_gettext('eg.staff.catalog.results.show_sidebar',
        'Staff catalog: show sidebar',
        'coust', 'label'),
    oils_i18n_gettext('eg.staff.catalog.results.show_sidebar',
        'Show the sidebar in staff catalog search results. Default is true.',
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1443', :eg_version);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'eg.circ.patron.search.show_names',
    'gui',
    oils_i18n_gettext('eg.circ.patron.search.show_names',
        'Staff Client patron search: show name fields',
        'coust', 'label'),
    oils_i18n_gettext('eg.circ.patron.search.show_names',
        'Displays the name row of advanced patron search fields',
        'coust', 'description'),
    'bool'
);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'eg.circ.patron.search.show_ids',
    'gui',
    oils_i18n_gettext('eg.circ.patron.search.show_ids',
        'Staff Client patron search: show ID fields',
        'coust', 'label'),
    oils_i18n_gettext('eg.circ.patron.search.show_ids',
        'Displays the ID row of advanced patron search fields',
        'coust', 'description'),
    'bool'
);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'eg.circ.patron.search.show_address',
    'gui',
    oils_i18n_gettext('eg.circ.patron.search.show_address',
        'Staff Client patron search: show address fields',
        'coust', 'label'),
    oils_i18n_gettext('eg.circ.patron.search.show_address',
        'Displays the address row of advanced patron search fields',
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1444', :eg_version); -- JBoyer

-- If these settings have not been marked Deprecated go ahead and do so now
UPDATE config.org_unit_setting_type SET label = 'Deprecated: ' || label WHERE name IN ('format.date', 'format.time') AND NOT label ILIKE 'deprecated: %';

COMMIT;
BEGIN;
-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1445', :eg_version);

UPDATE action_trigger.event_definition
SET template =
$$

[%- USE date -%][%- SET user = target.0.xact.usr -%]
<div style="font-family: Arial, Helvetica, sans-serif;">

   <!-- Header aligned left -->
   <div style="text-align:left;">
       <span style="padding-top:1em;">[% date.format %]</span>
    </div><br/>

     [% SET grand_total = 0.00 %]
    <ol>
    [% SET xact_mp_hash = {} %]
    [% FOR mp IN target %][%# Create an array of transactions/amount paid for each payment made %]
        [% SET xact_id = mp.xact.id %]
        [% SET amount = mp.amount %]
        [% IF ! xact_mp_hash.defined( xact_id ) %]
           [% xact_mp_hash.$xact_id = { 'xact' => mp.xact, 'payment' => amount } %]
        [% END %]
    [% END %]

    [% FOR xact_id IN xact_mp_hash.keys.sort %]
        [% SET xact = xact_mp_hash.$xact_id.xact %]
        <li>
          Transaction ID: [% xact_mp_hash.$xact_id.xact.id %]<br />
          [% IF xact.circulation %]
             Title: "[% helpers.get_copy_bib_basics(xact.circulation.target_copy).title %]" <br />
          [% END %]

           [%# Go get all the date needed from xact_summary %]

           [% SET mbts = xact.summary %]

           Transaction Type: [% mbts.last_billing_type%]<br />
           Date: [% mbts.last_billing_ts %] <br />

           Note: [% mbts.last_billing_note %] <br />

           Amount: $[% xact_mp_hash.$xact_id.payment | format("%.2f") %]
           [% grand_total = grand_total + xact_mp_hash.$xact_id.payment %]
        </li>
        <br />
    [% END %]
    </ol>

    <div> <!-- Summary of all the information -->
       Payment Type: [% SWITCH mp.payment_type -%]
                    [% CASE "cash_payment" %]Cash
                    [% CASE "check_payment" %]Check
                    [% CASE "credit_card_payment" %]Credit Card
                    [%- IF mp.credit_card_payment.cc_number %] ([% mp.credit_card_payment.cc_number %])[% END %]
                    [% CASE "debit_card_payment" %]Debit Card
                    [% CASE "credit_payment" %]Credit
                    [% CASE "forgive_payment" %]Forgiveness
                    [% CASE "goods_payment" %]Goods
                    [% CASE "work_payment" %]Work
                [%- END %] <br />
       Total:<strong> $[% grand_total | format("%.2f") %] </strong>
    </div>

</div>
$$
WHERE id = 30 AND template =
$$

[%- USE date -%][%- SET user = target.0.xact.usr -%]
<div style="font-family: Arial, Helvetica, sans-serif;">

   <!-- Header aligned left -->
   <div style="text-align:left;">
       <span style="padding-top:1em;">[% date.format %]</span>
    </div><br/>

     [% SET grand_total = 0.00 %]
    <ol>
    [% SET xact_mp_hash = {} %]
    [% FOR mp IN target %][%# Create an array of transactions/amount paid for each payment made %]
        [% SET xact_id = mp.xact.id %]
        [% SET amount = mp.amount %]
        [% IF ! xact_mp_hash.defined( xact_id ) %]
           [% xact_mp_hash.$xact_id = { 'xact' => mp.xact, 'payment' => amount } %]
        [% END %]
    [% END %]

    [% FOR xact_id IN xact_mp_hash.keys.sort %]
        [% SET xact = xact_mp_hash.$xact_id.xact %]
        <li>
          Transaction ID: [% xact_mp_hash.$xact_id.xact.id %]<br />
          [% IF xact.circulation %]
             Title: "[% helpers.get_copy_bib_basics(xact.circulation.target_copy).title %]" <br />
          [% END %]

           [%# Go get all the date needed from xact_summary %]

           [% SET mbts = xact.summary %]

           Transaction Type: [% mbts.last_billing_type%]<br />
           Date: [% mbts.last_billing_ts %] <br />

           Note: [% mbts.last_billing_note %] <br />

           Amount: $[% xact_mp_hash.$xact_id.payment | format("%.2f") %]
           [% grand_total = grand_total + xact_mp_hash.$xact_id.payment %]
        </li>
        <br />
    [% END %]
    </ol>

    <div> <!-- Summary of all the information -->
       Payment Type: Credit Card <br />
       Total:<strong> $[% grand_total | format("%.2f") %] </strong>
    </div>

</div>
$$;

COMMIT;
BEGIN;
SELECT evergreen.upgrade_deps_block_check('1446', :eg_version);

CREATE OR REPLACE FUNCTION actor.create_salt(pw_type TEXT)
    RETURNS TEXT AS $$
DECLARE
    type_row actor.passwd_type%ROWTYPE;
BEGIN
    /* Returns a new salt based on the passwd_type encryption settings.
     * Returns NULL If the password type is not crypt()'ed.
     */

    SELECT INTO type_row * FROM actor.passwd_type WHERE code = pw_type;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such password type: %', pw_type;
    END IF;

    IF type_row.iter_count IS NULL THEN
        -- This password type is unsalted.  That's OK.
        RETURN NULL;
    END IF;

    RETURN gen_salt(type_row.crypt_algo, type_row.iter_count);
END;
$$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1447', :eg_version);

CREATE OR REPLACE FUNCTION authority.generate_overlay_template (source_xml TEXT) RETURNS TEXT AS $f$
DECLARE
    cset                INT;
    main_entry          authority.control_set_authority_field%ROWTYPE;
    bib_field           authority.control_set_bib_field%ROWTYPE;
    auth_id             INT DEFAULT oils_xpath_string('//*[@tag="901"]/*[local-name()="subfield" and @code="c"]', source_xml)::INT;
    tmp_data            XML;
    replace_data        XML[] DEFAULT '{}'::XML[];
    replace_rules       TEXT[] DEFAULT '{}'::TEXT[];
    auth_field          XML[];
    auth_i1             TEXT;
    auth_i2             TEXT;
BEGIN
    IF auth_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Default to the LoC control set
    SELECT control_set INTO cset FROM authority.record_entry WHERE id = auth_id;

    -- if none, make a best guess
    IF cset IS NULL THEN
        SELECT  control_set INTO cset
          FROM  authority.control_set_authority_field
          WHERE tag IN (
                    SELECT  UNNEST(XPATH('//*[local-name()="datafield" and starts-with(@tag,"1")]/@tag',marc::XML)::TEXT[])
                      FROM  authority.record_entry
                      WHERE id = auth_id
                )
          LIMIT 1;
    END IF;

    -- if STILL none, no-op change
    IF cset IS NULL THEN
        RETURN XMLELEMENT(
            name record,
            XMLATTRIBUTES('http://www.loc.gov/MARC21/slim' AS xmlns),
            XMLELEMENT( name leader, '00881nam a2200193   4500'),
            XMLELEMENT(
                name datafield,
                XMLATTRIBUTES( '905' AS tag, ' ' AS ind1, ' ' AS ind2),
                XMLELEMENT(
                    name subfield,
                    XMLATTRIBUTES('d' AS code),
                    '901c'
                )
            )
        )::TEXT;
    END IF;

    FOR main_entry IN SELECT * FROM authority.control_set_authority_field acsaf WHERE acsaf.control_set = cset AND acsaf.main_entry IS NULL ORDER BY acsaf.tag LOOP
        auth_field := XPATH('//*[local-name()="datafield" and @tag="'||main_entry.tag||'"][1]',source_xml::XML);
        auth_i1 := (XPATH('//*[local-name()="datafield"]/@ind1',auth_field[1]))[1];
        auth_i2 := (XPATH('//*[local-name()="datafield"]/@ind2',auth_field[1]))[1];
        IF ARRAY_LENGTH(auth_field,1) > 0 THEN
            FOR bib_field IN SELECT * FROM authority.control_set_bib_field WHERE authority_field = main_entry.id ORDER BY control_set_bib_field.tag LOOP
                SELECT XMLELEMENT( -- XMLAGG avoids magical <element> creation, but requires unnest subquery
                    name datafield,
                    XMLATTRIBUTES(bib_field.tag AS tag, auth_i1 AS ind1, auth_i2 AS ind2),
                    XMLAGG(UNNEST)
                ) INTO tmp_data FROM UNNEST(XPATH('//*[local-name()="subfield"]', auth_field[1]));
                replace_data := replace_data || tmp_data;
                replace_rules := replace_rules || ( bib_field.tag || main_entry.sf_list || E'[0~\\)' || auth_id || '$]' );
                tmp_data = NULL;
            END LOOP;
            EXIT;
        END IF;
    END LOOP;

    SELECT XMLAGG(UNNEST) INTO tmp_data FROM UNNEST(replace_data);

    RETURN XMLELEMENT(
        name record,
        XMLATTRIBUTES('http://www.loc.gov/MARC21/slim' AS xmlns),
        XMLELEMENT( name leader, '00881nam a2200193   4500'),
        tmp_data,
        XMLELEMENT(
            name datafield,
            XMLATTRIBUTES( '905' AS tag, ' ' AS ind1, ' ' AS ind2),
            XMLELEMENT(
                name subfield,
                XMLATTRIBUTES('r' AS code),
                ARRAY_TO_STRING(replace_rules,',')
            )
        )
    )::TEXT;
END;
$f$ STABLE LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1448', :eg_version);

CREATE TABLE IF NOT EXISTS actor.usr_mfa_exception (
    id      SERIAL  PRIMARY KEY,
    usr     BIGINT  NOT NULL REFERENCES actor.usr (id) DEFERRABLE INITIALLY DEFERRED,
    ingress TEXT    -- disregard MFA requirement for specific ehow (ingress types, like 'sip2'), or NULL for all
); 

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1449', :eg_version);

CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries(
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE,
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE,
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id || $$ AND field = ANY($1)$$ USING field_list;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id AND def = ANY(field_list);
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

        -- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN
            -- A caveat about this SELECT: this should take care of replacing
            -- old mbe rows when data changes, but not if normalization (by
            -- which I mean specifically the output of
            -- evergreen.oils_tsearch2()) changes.  It may or may not be
            -- expensive to add a comparison of index_vector to index_vector
            -- to the WHERE clause below.

            CONTINUE WHEN ind_data.sort_value IS NULL;

            value_prepped := metabib.browse_normalize(ind_data.value, ind_data.field);
            IF ind_data.browse_nocase THEN -- for "nocase" browse definions, look for a preexisting row that matches case-insensitively on value and use that
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE evergreen.lowercase(value) = evergreen.lowercase(value_prepped) AND sort_value = ind_data.sort_value
                    ORDER BY sort_value, value LIMIT 1; -- gotta pick something, I guess
            END IF;

            IF mbe_row.id IS NOT NULL THEN -- asked to check for, and found, a "nocase" version to use
                mbe_id := mbe_row.id;
            ELSE -- otherwise, an UPSERT-protected variant
                INSERT INTO metabib.browse_entry
                    ( value, sort_value ) VALUES
                    ( SUBSTRING(value_prepped FOR 1000), SUBSTRING(ind_data.sort_value FOR 1000) )
                  ON CONFLICT (sort_value, value) DO UPDATE SET sort_value = SUBSTRING(EXCLUDED.sort_value FOR 1000) -- must update a row to return an existing id
                  RETURNING id INTO mbe_id;
            END IF;

            INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
                VALUES (mbe_id, ind_data.field, ind_data.source, ind_data.authority);
        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
        IF NOT FOUND THEN
            PERFORM search.symspell_dictionary_reify();
        END IF;
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1450', :eg_version);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'eg.admin.keyboard_shortcuts.disable_single',
    'gui',
    oils_i18n_gettext('eg.admin.keyboard_shortcuts.disable_single',
        'Staff Client: disable single-letter keyboard shortcuts',
        'coust', 'label'),
    oils_i18n_gettext('eg.admin.keyboard_shortcuts.disable_single',
        'Disables single-letter keyboard shortcuts if set to true. Screen reader users should set this to true to avoid interference with standard keyboard shortcuts.',
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1451', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.catalog.record.parts', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.record.parts',
        'Grid Config: catalog.record.parts',
        'cwst', 'label'
       )
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1452', :eg_version);

INSERT INTO config.org_unit_setting_type
    (name, label, description, grp, datatype)
VALUES (
    'ui.staff.place_holds_for_recent_patrons',
    oils_i18n_gettext(
        'ui.staff.place_holds_for_recent_patrons',
        'Place holds for recent patrons',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'ui.staff.place_holds_for_recent_patrons',
        'Loading a patron in the place holds interface designates them as recent. ' ||
        'Show the interface to load recent patrons when placing holds.',
        'coust',
        'description'
    ),
    'gui',
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1453', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) SELECT DISTINCT
   676,
   'UPDATE_TOP_OF_QUEUE',
   oils_i18n_gettext(676,
     'Allow setting and unsetting hold from top of hold queue (cut in line)', 'ppl', 'description'
   )
   FROM permission.perm_list
   WHERE NOT EXISTS (SELECT 1 FROM permission.perm_list WHERE code = 'UPDATE_TOP_OF_QUEUE');


--Assign permission to any perm groups with UPDATE_HOLD_REQUEST_TIME
WITH perms_to_add AS
    (SELECT id FROM
    permission.perm_list
    WHERE code IN ('UPDATE_TOP_OF_QUEUE'))
INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
    SELECT grp, perms_to_add.id as perm, depth, grantable
        FROM perms_to_add,
        permission.grp_perm_map

        --- Don't add the permissions if they have already been assigned
        WHERE grp NOT IN
            (SELECT DISTINCT grp FROM permission.grp_perm_map
            INNER JOIN perms_to_add ON perm=perms_to_add.id)

        --- we're going to match the depth of their existing perm
        AND perm = (
            SELECT id
                FROM permission.perm_list
                WHERE code = 'UPDATE_HOLD_REQUEST_TIME'
        );

COMMIT;BEGIN;

SELECT evergreen.upgrade_deps_block_check('1454', :eg_version);

ALTER TABLE acq.invoice_item ALTER CONSTRAINT invoice_item_fund_debit_fkey DEFERRABLE INITIALLY DEFERRED;

COMMIT;
-- Add missing FROM clause entry to asset.opac_lasso_record_copy_count

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1455', :eg_version);

CREATE OR REPLACE FUNCTION asset.opac_lasso_record_copy_count (i_lasso INT, rid BIGINT) RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT) AS $f$
DECLARE
    ans RECORD;
    trans INT;
BEGIN
    SELECT 1 INTO trans FROM biblio.record_entry b JOIN config.bib_source src ON (b.source = src.id) WHERE src.transcendant AND b.id = rid;

    FOR ans IN SELECT u.org_unit AS id FROM actor.org_lasso_map AS u WHERE lasso = i_lasso LOOP
        RETURN QUERY
        WITH org_list AS (SELECT ARRAY_AGG(id)::BIGINT[] AS orgs FROM actor.org_unit_descendants(ans.id) x),
             available_statuses AS (SELECT ARRAY_AGG(id) AS ids FROM config.copy_status WHERE is_available),
             mask AS (SELECT c_attrs FROM asset.patron_default_visibility_mask() x)
        SELECT  -1,
                ans.id,
                COUNT( av.id ),
                SUM( (cp.status = ANY (available_statuses.ids))::INT ),
                COUNT( av.id ),
                trans
          FROM  mask,
                org_list,
                available_statuses,
                asset.copy_vis_attr_cache av
                JOIN asset.copy cp ON (cp.id = av.target_copy AND av.record = rid)
          WHERE cp.circ_lib = ANY (org_list.orgs) AND av.vis_attr_vector @@ mask.c_attrs::query_int
          GROUP BY 1,2,6;

        IF NOT FOUND THEN
            RETURN QUERY SELECT -1, ans.id, 0::BIGINT, 0::BIGINT, 0::BIGINT, trans;
        END IF;

    END LOOP;

    RETURN;
END;
$f$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1456', :eg_version);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'ui.staff.grid.density',
    'gui',
    oils_i18n_gettext('ui.staff.grid.density',
        'Grid UI density',
        'coust', 'label'),
    oils_i18n_gettext('ui.staff.grid.density',
        'Whitespace around table cells in staff UI data grids. Default is "standard".',
        'coust', 'description'),
    'string'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1457', :eg_version);

ALTER TABLE action.hold_request_reset_reason_entry DROP CONSTRAINT hold_request_reset_reason_entry_hold_fkey;
ALTER TABLE action.hold_request_reset_reason_entry ADD FOREIGN KEY (hold) REFERENCES action.hold_request(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

CREATE OR REPLACE FUNCTION actor.usr_merge( src_usr INT, dest_usr INT, del_addrs BOOLEAN, del_cards BOOLEAN, deactivate_cards BOOLEAN ) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	bucket_row RECORD;
	picklist_row RECORD;
	queue_row RECORD;
	folder_row RECORD;
BEGIN

    -- Bail if src_usr equals dest_usr because the result of merging a
    -- user with itself is not what you want.
    IF src_usr = dest_usr THEN
        RETURN;
    END IF;

    -- do some initial cleanup 
    UPDATE actor.usr SET card = NULL WHERE id = src_usr;
    UPDATE actor.usr SET mailing_address = NULL WHERE id = src_usr;
    UPDATE actor.usr SET billing_address = NULL WHERE id = src_usr;

    -- actor.*
    IF del_cards THEN
        DELETE FROM actor.card where usr = src_usr;
    ELSE
        IF deactivate_cards THEN
            UPDATE actor.card SET active = 'f' WHERE usr = src_usr;
        END IF;
        UPDATE actor.card SET usr = dest_usr WHERE usr = src_usr;
    END IF;


    IF del_addrs THEN
        DELETE FROM actor.usr_address WHERE usr = src_usr;
    ELSE
        UPDATE actor.usr_address SET usr = dest_usr WHERE usr = src_usr;
    END IF;

    UPDATE actor.usr_message SET usr = dest_usr WHERE usr = src_usr;
    -- dupes are technically OK in actor.usr_standing_penalty, should manually delete them...
    UPDATE actor.usr_standing_penalty SET usr = dest_usr WHERE usr = src_usr;
    PERFORM actor.usr_merge_rows('actor.usr_org_unit_opt_in', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('actor.usr_setting', 'usr', src_usr, dest_usr);

    -- permission.*
    PERFORM actor.usr_merge_rows('permission.usr_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_object_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_grp_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_work_ou_map', 'usr', src_usr, dest_usr);


    -- container.*
	
	-- For each *_bucket table: transfer every bucket belonging to src_usr
	-- into the custody of dest_usr.
	--
	-- In order to avoid colliding with an existing bucket owned by
	-- the destination user, append the source user's id (in parenthesese)
	-- to the name.  If you still get a collision, add successive
	-- spaces to the name and keep trying until you succeed.
	--
	FOR bucket_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE container.user_bucket_item SET target_user = dest_usr WHERE target_user = src_usr;

    -- vandelay.*
	-- transfer queues the same way we transfer buckets (see above)
	FOR queue_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = queue_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- money.*
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'collector', src_usr, dest_usr);
    UPDATE money.billable_xact SET usr = dest_usr WHERE usr = src_usr;
    UPDATE money.billing SET voider = dest_usr WHERE voider = src_usr;
    UPDATE money.bnm_payment SET accepting_usr = dest_usr WHERE accepting_usr = src_usr;

    -- action.*
    UPDATE action.circulation SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
    UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
    UPDATE action.usr_circ_history SET usr = dest_usr WHERE usr = src_usr;

    UPDATE action.hold_request SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
    UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
    UPDATE action.hold_request SET canceled_by = dest_usr WHERE canceled_by = src_usr;
	UPDATE action.hold_request_reset_reason_entry SET requestor = dest_usr WHERE requestor = src_usr;
    UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;

    UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET patron = dest_usr WHERE patron = src_usr;
    UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.survey_response SET usr = dest_usr WHERE usr = src_usr;

    -- acq.*
    UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.fund_transfer SET transfer_user = dest_usr WHERE transfer_user = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;

	-- transfer picklists the same way we transfer buckets (see above)
	FOR picklist_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = picklist_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
    UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.provider_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.provider_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_usr_attr_definition SET usr = dest_usr WHERE usr = src_usr;

    -- asset.*
    UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;

    -- serial.*
    UPDATE serial.record_entry SET creator = dest_usr WHERE creator = src_usr;
    UPDATE serial.record_entry SET editor = dest_usr WHERE editor = src_usr;

    -- reporter.*
    -- It's not uncommon to define the reporter schema in a replica 
    -- DB only, so don't assume these tables exist in the write DB.
    BEGIN
    	UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;

    -- propagate preferred name values from the source user to the
    -- destination user, but only when values are not being replaced.
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr)
    UPDATE actor.usr SET 
        pref_prefix = 
            COALESCE(pref_prefix, (SELECT pref_prefix FROM susr)),
        pref_first_given_name = 
            COALESCE(pref_first_given_name, (SELECT pref_first_given_name FROM susr)),
        pref_second_given_name = 
            COALESCE(pref_second_given_name, (SELECT pref_second_given_name FROM susr)),
        pref_family_name = 
            COALESCE(pref_family_name, (SELECT pref_family_name FROM susr)),
        pref_suffix = 
            COALESCE(pref_suffix, (SELECT pref_suffix FROM susr))
    WHERE id = dest_usr;

    -- Copy and deduplicate name keywords
    -- String -> array -> rows -> DISTINCT -> array -> string
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr),
         dusr AS (SELECT * FROM actor.usr WHERE id = dest_usr)
    UPDATE actor.usr SET name_keywords = (
        WITH keywords AS (
            SELECT DISTINCT UNNEST(
                REGEXP_SPLIT_TO_ARRAY(
                    COALESCE((SELECT name_keywords FROM susr), '') || ' ' ||
                    COALESCE((SELECT name_keywords FROM dusr), ''),  E'\\s+'
                )
            ) AS parts
        ) SELECT STRING_AGG(kw.parts, ' ') FROM keywords kw
    ) WHERE id = dest_usr;

    -- Finally, delete the source user
    PERFORM actor.usr_delete(src_usr,dest_usr);

END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION actor.usr_purge_data(
	src_usr  IN INTEGER,
	specified_dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	renamable_row RECORD;
	dest_usr INTEGER;
BEGIN

	IF specified_dest_usr IS NULL THEN
		dest_usr := 1; -- Admin user on stock installs
	ELSE
		dest_usr := specified_dest_usr;
	END IF;

    -- action_trigger.event (even doing this, event_output may--and probably does--contain PII and should have a retention/removal policy)
    UPDATE action_trigger.event SET context_user = dest_usr WHERE context_user = src_usr;

	-- acq.*
	UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.lineitem SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.lineitem SET selector = dest_usr WHERE selector = src_usr;
	UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;
	DELETE FROM acq.lineitem_usr_attr_definition WHERE usr = src_usr;

	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE acq.picklist SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.picklist SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
	UPDATE acq.purchase_order SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.purchase_order SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.claim_event SET creator = dest_usr WHERE creator = src_usr;

	-- action.*
	DELETE FROM action.circulation WHERE usr = src_usr;
	UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
	UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
	UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;
	UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
	UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
	UPDATE action.hold_request SET canceled_by = dest_usr WHERE canceled_by = src_usr;
	UPDATE action.hold_request_reset_reason_entry SET requestor = dest_usr WHERE requestor = src_usr;
	DELETE FROM action.hold_request WHERE usr = src_usr;
	UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
	UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.non_cataloged_circulation WHERE patron = src_usr;
	UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.survey_response WHERE usr = src_usr;
	UPDATE action.fieldset SET owner = dest_usr WHERE owner = src_usr;
	DELETE FROM action.usr_circ_history WHERE usr = src_usr;
	UPDATE action.curbside SET notes = NULL WHERE patron = src_usr;

	-- actor.*
	DELETE FROM actor.card WHERE usr = src_usr;
	DELETE FROM actor.stat_cat_entry_usr_map WHERE target_usr = src_usr;
	DELETE FROM actor.usr_privacy_waiver WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;

	-- The following update is intended to avoid transient violations of a foreign
	-- key constraint, whereby actor.usr_address references itself.  It may not be
	-- necessary, but it does no harm.
	UPDATE actor.usr_address SET replaces = NULL
		WHERE usr = src_usr AND replaces IS NOT NULL;
	DELETE FROM actor.usr_address WHERE usr = src_usr;
	DELETE FROM actor.usr_org_unit_opt_in WHERE usr = src_usr;
	UPDATE actor.usr_org_unit_opt_in SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM actor.usr_setting WHERE usr = src_usr;
	DELETE FROM actor.usr_standing_penalty WHERE usr = src_usr;
	UPDATE actor.usr_message SET title = 'purged', message = 'purged', read_date = NOW() WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;
	UPDATE actor.usr_standing_penalty SET staff = dest_usr WHERE staff = src_usr;
	UPDATE actor.usr_message SET editor = dest_usr WHERE editor = src_usr;

	-- asset.*
	UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;

	-- auditor.*
	DELETE FROM auditor.actor_usr_address_history WHERE id = src_usr;
	DELETE FROM auditor.actor_usr_history WHERE id = src_usr;
	UPDATE auditor.asset_call_number_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_call_number_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.asset_copy_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_copy_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.biblio_record_entry_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.biblio_record_entry_history SET editor  = dest_usr WHERE editor  = src_usr;

	-- biblio.*
	UPDATE biblio.record_entry SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_entry SET editor = dest_usr WHERE editor = src_usr;
	UPDATE biblio.record_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_note SET editor = dest_usr WHERE editor = src_usr;

	-- container.*
	-- Update buckets with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	DELETE FROM container.user_bucket_item WHERE target_user = src_usr;

	-- money.*
	DELETE FROM money.billable_xact WHERE usr = src_usr;
	DELETE FROM money.collections_tracker WHERE usr = src_usr;
	UPDATE money.collections_tracker SET collector = dest_usr WHERE collector = src_usr;

	-- permission.*
	DELETE FROM permission.usr_grp_map WHERE usr = src_usr;
	DELETE FROM permission.usr_object_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_work_ou_map WHERE usr = src_usr;

	-- reporter.*
	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
	-- do nothing
	END;

	-- vandelay.*
	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- NULL-ify addresses last so other cleanup (e.g. circ anonymization)
    -- can access the information before deletion.
	UPDATE actor.usr SET
		active = FALSE,
		card = NULL,
		mailing_address = NULL,
		billing_address = NULL
	WHERE id = src_usr;

END;
$$ LANGUAGE plpgsql;

COMMIT;
BEGIN;

-- Move OPAC alert banner feature from config file to a library setting

SELECT evergreen.upgrade_deps_block_check('1458', :eg_version);

INSERT into config.org_unit_setting_type
         (name, grp, label, description, datatype)
VALUES (
         'opac.alert_banner_show',
         'opac',
         oils_i18n_gettext('opac.alert_banner_show',
         'OPAC Alert Banner: Display',
         'coust', 'label'),
         oils_i18n_gettext('opac.alert_message_show',
         'Show an alert banner in the OPAC. Default is false.',
         'coust', 'description'),
         'bool'
);

INSERT into config.org_unit_setting_type
         (name, grp, label, description, datatype)
VALUES (
         'opac.alert_banner_type',
         'opac',
         oils_i18n_gettext('opac.alert_banner_type',
         'OPAC Alert Banner: Type',
         'coust', 'label'),
         oils_i18n_gettext('opac.alert_message_type',
         'Determine the display of the banner. Options are: success, info, warning, danger.',
         'coust', 'description'),
         'string'
);

INSERT into config.org_unit_setting_type
         (name, grp, label, description, datatype)
VALUES (
         'opac.alert_banner_text',
         'opac',
         oils_i18n_gettext('opac.alert_banner_text',
         'OPAC Alert Banner: Text',
         'coust', 'label'),
         oils_i18n_gettext('opac.alert_message_text',
         'Text that will display in the alert banner.',
         'coust', 'description'),
         'string'
);

 COMMIT;BEGIN;

-- Move Google Analytics settings from config.tt2 to library settings

SELECT evergreen.upgrade_deps_block_check('1459', :eg_version);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'opac.google_analytics_enable',
    'opac',
    oils_i18n_gettext('opac.google_analytics_enable',
    'Google Analytics: Enable',
    'coust', 'label'),
    oils_i18n_gettext('opac.alert_message_show',
    'Enable Google Analytics in the OPAC. Default is false.',
    'coust', 'description'),
    'bool'
);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'opac.google_analytics_code',
    'opac',
    oils_i18n_gettext('opac.google_analytics_code',
    'Google Analytics: Code',
    'coust', 'label'),
    oils_i18n_gettext('opac.google_analytics_code',
    'Account code provided by Google. (Example: G-GVGQ11X12)',
    'coust', 'description'),
    'string'
);

COMMIT;BEGIN;

SELECT evergreen.upgrade_deps_block_check('1460', :eg_version); -- JBoyer

-- Note: the value will not be consistent from system to system. It's an opaque key that has no meaning of its own,
-- if the value cached in the client does not match or is missing, it clears some cached values and then saves the current value.
INSERT INTO config.global_flag (name, label, value, enabled) VALUES (
    'staff.client_cache_key',
    oils_i18n_gettext(
        'staff.client_cache_key',
        'Change this value to force staff clients to clear some cached values',
        'cgf',
        'label'
    ),
    md5(random()::text),
    TRUE
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1461', :eg_version);

-- for searching e.g. "111-111-1111"
CREATE INDEX actor_usr_setting_phone_values_idx
    ON actor.usr_setting (evergreen.lowercase(value))
    WHERE name IN ('opac.default_phone', 'opac.default_sms_notify');

-- for searching e.g. "1111111111"
CREATE INDEX actor_usr_setting_phone_values_numeric_idx
    ON actor.usr_setting (evergreen.lowercase(REGEXP_REPLACE(value, '[^0-9]', '', 'g')))
    WHERE name IN ('opac.default_phone', 'opac.default_sms_notify');

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1462', :eg_version);

INSERT INTO acq.edi_attr (key, label) VALUES
    ('LINEITEM_SEQUENTIAL_ID',
        oils_i18n_gettext('LINEITEM_SEQUENTIAL_ID',
        'Lineitems Are Enumerated Sequentially', 'aea', 'label'));

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1463', :eg_version);

INSERT INTO config.org_unit_setting_type
    (grp, name, datatype, label, description)
VALUES (
    'gui',
    'ui.cat.volume_copy_editor.template_bar.show_save_template', 'bool',
    oils_i18n_gettext(
        'ui.cat.volume_copy_editor.template_bar.show_save_template',
        'Show "Save Template" in Holdings Editor',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'ui.cat.volume_copy_editor.template_bar.show_save_template',
        'Displays the "Save Template" button for the template bar in the Volume/Copy/Holdings Editor. By default, this is only displayed when working with templates from the Admin interface.',
        'coust',
        'description'
    )
);

INSERT INTO config.org_unit_setting_type
    (grp, name, datatype, label, description)
VALUES (
    'gui',
    'ui.cat.volume_copy_editor.hide_template_bar', 'bool',
    oils_i18n_gettext(
        'ui.cat.volume_copy_editor.hide_template_bar',
        'Hide the entire template bar in Holdings Editor',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'ui.cat.volume_copy_editor.hide_template_bar',
        'Hides the template bar in the Volume/Copy/Holdings Editor. By default, the template bar is displayed in this interface.',
        'coust',
        'description'
    )
);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.cat.volcopy.template_grid', 'gui', 'object', 
    oils_i18n_gettext(
        'eg.grid.cat.volcopy.template_grid',
        'Holdings Template Grid Settings',
        'cwst', 'label'
    )
);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.holdings.copy_tags.tag_map_list', 'gui', 'object', 
    oils_i18n_gettext(
        'eg.grid.holdings.copy_tags.tag_map_list',
        'Copy Tag Maps Template Grid Settings',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1464', :eg_version);

-- If you want to know how many items are available in a particular library group,
-- you can't easily sum the results of, say, asset.staff_lasso_record_copy_count,
-- since library groups can theoretically include descendants of other org units
-- in the library group (for example, the group could include a system and a branch
-- within that same system), which means that certain items would be counted twice.
-- The following functions address that problem by providing deduplicated sums that
-- only count each item once.

CREATE OR REPLACE FUNCTION asset.staff_lasso_record_copy_count_sum(lasso_id INT, record_id BIGINT)
    RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT, library_group INT) AS $$
    BEGIN
    IF (lasso_id IS NULL) THEN RETURN; END IF;
    IF (record_id IS NULL) THEN RETURN; END IF;
    RETURN QUERY SELECT
        -1,
        -1,
        COUNT(cp.id),
        SUM( CASE WHEN cp.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available) THEN 1 ELSE 0 END ),
        SUM( CASE WHEN cl.opac_visible AND cp.opac_visible THEN 1 ELSE 0 END),
        0,
        lasso_id
    FROM ( SELECT DISTINCT descendants.id FROM actor.org_lasso_map aolmp JOIN LATERAL actor.org_unit_descendants(aolmp.org_unit) AS descendants ON TRUE WHERE aolmp.lasso = lasso_id) d
        JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
        JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
        JOIN asset.call_number cn ON (cn.record = record_id AND cn.id = cp.call_number AND NOT cn.deleted);
    END;
$$ LANGUAGE PLPGSQL STABLE ROWS 1;

CREATE OR REPLACE FUNCTION asset.opac_lasso_record_copy_count_sum(lasso_id INT, record_id BIGINT)
    RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT, library_group INT) AS $$
    BEGIN
    IF (lasso_id IS NULL) THEN RETURN; END IF;
    IF (record_id IS NULL) THEN RETURN; END IF;

    RETURN QUERY SELECT
        -1,
        -1,
        COUNT(cp.id),
        SUM( CASE WHEN cp.status IN (SELECT id FROM config.copy_status WHERE holdable AND is_available) THEN 1 ELSE 0 END ),
        SUM( CASE WHEN cl.opac_visible AND cp.opac_visible THEN 1 ELSE 0 END),
        0,
        lasso_id
    FROM ( SELECT DISTINCT descendants.id FROM actor.org_lasso_map aolmp JOIN LATERAL actor.org_unit_descendants(aolmp.org_unit) AS descendants ON TRUE WHERE aolmp.lasso = lasso_id) d
        JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
        JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
        JOIN asset.call_number cn ON (cn.record = record_id AND cn.id = cp.call_number AND NOT cn.deleted)
        JOIN asset.copy_vis_attr_cache av ON (cp.id = av.target_copy AND av.record = record_id)
        JOIN LATERAL (SELECT c_attrs FROM asset.patron_default_visibility_mask()) AS mask ON TRUE
        WHERE av.vis_attr_vector @@ mask.c_attrs::query_int;
    END;
$$ LANGUAGE PLPGSQL STABLE ROWS 1;

CREATE OR REPLACE FUNCTION asset.staff_lasso_metarecord_copy_count_sum(lasso_id INT, metarecord_id BIGINT)
    RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT, library_group INT) AS $$
    SELECT (
        -1,
        -1,
        SUM(sums.visible)::bigint,
        SUM(sums.available)::bigint,
        SUM(sums.unshadow)::bigint,
        MIN(sums.transcendant),
        lasso_id
    ) FROM metabib.metarecord_source_map mmsm
      JOIN LATERAL (SELECT visible, available, unshadow, transcendant FROM asset.staff_lasso_record_copy_count_sum(lasso_id, mmsm.source)) sums ON TRUE
      WHERE mmsm.metarecord = metarecord_id;
$$ LANGUAGE SQL STABLE ROWS 1;

CREATE OR REPLACE FUNCTION asset.opac_lasso_metarecord_copy_count_sum(lasso_id INT, metarecord_id BIGINT)
    RETURNS TABLE (depth INT, org_unit INT, visible BIGINT, available BIGINT, unshadow BIGINT, transcendant INT, library_group INT) AS $$
    SELECT (
        -1,
        -1,
        SUM(sums.visible)::bigint,
        SUM(sums.available)::bigint,
        SUM(sums.unshadow)::bigint,
        MIN(sums.transcendant),
        lasso_id
    ) FROM metabib.metarecord_source_map mmsm
      JOIN LATERAL (SELECT visible, available, unshadow, transcendant FROM asset.opac_lasso_record_copy_count_sum(lasso_id, mmsm.source)) sums ON TRUE
      WHERE mmsm.metarecord = metarecord_id;
$$ LANGUAGE SQL STABLE ROWS 1;


CREATE OR REPLACE FUNCTION asset.copy_org_ids(org_units INT[], depth INT, library_groups INT[])
RETURNS TABLE (id INT)
AS $$
DECLARE
    ancestor INT;
BEGIN
    RETURN QUERY SELECT org_unit FROM actor.org_lasso_map WHERE lasso = ANY(library_groups);
    FOR ancestor IN SELECT unnest(org_units)
    LOOP
        RETURN QUERY
        SELECT d.id
        FROM actor.org_unit_descendants(ancestor, depth) d;
    END LOOP;
    RETURN;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION asset.staff_copy_total(rec_id INT, org_units INT[], depth INT, library_groups INT[])
RETURNS INT AS $$
  SELECT COUNT(cp.id) total
  	FROM asset.copy cp
  	INNER JOIN asset.call_number cn ON (cn.id = cp.call_number AND NOT cn.deleted AND cn.record = rec_id)
  	INNER JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
  	WHERE cp.circ_lib = ANY (SELECT asset.copy_org_ids(org_units, depth, library_groups))
  	AND NOT cp.deleted;
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION asset.opac_copy_total(rec_id INT, org_units INT[], depth INT, library_groups INT[])
RETURNS INT AS $$
  SELECT COUNT(cp.id) total
  	FROM asset.copy cp
  	INNER JOIN asset.call_number cn ON (cn.id = cp.call_number AND NOT cn.deleted AND cn.record = rec_id)
  	INNER JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
    INNER JOIN asset.copy_vis_attr_cache av ON (cp.id = av.target_copy AND av.record = rec_id)
    JOIN LATERAL (SELECT c_attrs FROM asset.patron_default_visibility_mask()) AS mask ON TRUE
    WHERE av.vis_attr_vector @@ mask.c_attrs::query_int
  	AND cp.circ_lib = ANY (SELECT asset.copy_org_ids(org_units, depth, library_groups))
  	AND NOT cp.deleted;
$$ LANGUAGE SQL;

-- We are adding another argument, which means that we must delete functions with the old signature
DROP FUNCTION IF EXISTS unapi.holdings_xml(
    bid BIGINT,
    ouid INT,
    org TEXT,
    depth INT,
    includes TEXT[],
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL,
    pref_lib INT);

CREATE OR REPLACE FUNCTION unapi.holdings_xml (
    bid BIGINT,
    ouid INT,
    org TEXT,
    depth INT DEFAULT NULL,
    includes TEXT[] DEFAULT NULL::TEXT[],
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL
)
RETURNS XML AS $F$
     SELECT  XMLELEMENT(
                 name holdings,
                 XMLATTRIBUTES(
                    CASE WHEN $8 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                    CASE WHEN ('bre' = ANY ($5)) THEN 'tag:open-ils.org:U2@bre/' || $1 || '/' || $3 ELSE NULL END AS id,
                    (SELECT record_has_holdable_copy FROM asset.record_has_holdable_copy($1)) AS has_holdable
                 ),
                 XMLELEMENT(
                     name counts,
                     (SELECT  XMLAGG(XMLELEMENT::XML) FROM (
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('public' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_ou_record_copy_count($2,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('staff' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.staff_ou_record_copy_count($2, $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('pref_lib' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_ou_record_copy_count($9,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('public' as type, depth, library_group, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_lasso_record_copy_count_sum(library_group,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('staff' as type, depth, library_group, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.staff_lasso_record_copy_count_sum(library_group,  $1)
                                     ORDER BY 1
                     )x)
                 ),
                 CASE 
                     WHEN ('bmp' = ANY ($5)) THEN
                        XMLELEMENT(
                            name monograph_parts,
                            (SELECT XMLAGG(bmp) FROM (
                                SELECT  unapi.bmp( id, 'xml', 'monograph_part', array_remove( array_remove($5,'bre'), 'holdings_xml'), $3, $4, $6, $7, FALSE)
                                  FROM  biblio.monograph_part
                                  WHERE NOT deleted AND record = $1
                            )x)
                        )
                     ELSE NULL
                 END,
                 XMLELEMENT(
                     name volumes,
                     (SELECT XMLAGG(acn ORDER BY rank, name, label_sortkey) FROM (
                        -- Physical copies
                        SELECT  unapi.acn(y.id,'xml','volume',array_remove( array_remove($5,'holdings_xml'),'bre'), $3, $4, $6, $7, FALSE), y.rank, name, label_sortkey
                        FROM evergreen.ranked_volumes($1, $2, $4, $6, $7, $9, $5) AS y
                        UNION ALL
                        -- Located URIs
                        SELECT unapi.acn(uris.id,'xml','volume',array_remove( array_remove($5,'holdings_xml'),'bre'), $3, $4, $6, $7, FALSE), uris.rank, name, label_sortkey
                        FROM evergreen.located_uris($1, $2, $9) AS uris
                     )x)
                 ),
                 CASE WHEN ('ssub' = ANY ($5)) THEN 
                     XMLELEMENT(
                         name subscriptions,
                         (SELECT XMLAGG(ssub) FROM (
                            SELECT  unapi.ssub(id,'xml','subscription','{}'::TEXT[], $3, $4, $6, $7, FALSE)
                              FROM  serial.subscription
                              WHERE record_entry = $1
                        )x)
                     )
                 ELSE NULL END,
                 CASE WHEN ('acp' = ANY ($5)) THEN 
                     XMLELEMENT(
                         name foreign_copies,
                         (SELECT XMLAGG(acp) FROM (
                            SELECT  unapi.acp(p.target_copy,'xml','copy',array_remove($5,'acp'), $3, $4, $6, $7, FALSE)
                              FROM  biblio.peer_bib_copy_map p
                                    JOIN asset.copy c ON (p.target_copy = c.id)
                              WHERE NOT c.deleted AND p.peer_record = $1
                            LIMIT ($6 -> 'acp')::INT
                            OFFSET ($7 -> 'acp')::INT
                        )x)
                     )
                 ELSE NULL END
             );
$F$ LANGUAGE SQL STABLE;

DROP FUNCTION IF EXISTS unapi.bre (
    obj_id BIGINT,
    format TEXT,
    ename TEXT,
    includes TEXT[],
    org TEXT,
    depth INT,
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL,
    pref_lib INT);

CREATE OR REPLACE FUNCTION unapi.bre (
    obj_id BIGINT,
    format TEXT,
    ename TEXT,
    includes TEXT[],
    org TEXT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL
)
RETURNS XML AS $F$
DECLARE
    me      biblio.record_entry%ROWTYPE;
    layout  unapi.bre_output_layout%ROWTYPE;
    xfrm    config.xml_transform%ROWTYPE;
    ouid    INT;
    tmp_xml TEXT;
    top_el  TEXT;
    output  XML;
    hxml    XML;
    axml    XML;
    source  XML;
BEGIN

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;

    IF ouid IS NULL THEN
        RETURN NULL::XML;
    END IF;

    IF format = 'holdings_xml' THEN -- the special case
        output := unapi.holdings_xml( obj_id, ouid, org, depth, includes, slimit, soffset, include_xmlns, NULL, library_group);
        RETURN output;
    END IF;

    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO xfrm FROM config.xml_transform WHERE name = layout.transform;

    SELECT * INTO me FROM biblio.record_entry WHERE id = obj_id;

    -- grab bib_source, if any
    IF ('cbs' = ANY (includes) AND me.source IS NOT NULL) THEN
        source := unapi.cbs(me.source,NULL,NULL,NULL,NULL);
    ELSE
        source := NULL::XML;
    END IF;

    -- grab SVF if we need them
    IF ('mra' = ANY (includes)) THEN 
        axml := unapi.mra(obj_id,NULL,NULL,NULL,NULL);
    ELSE
        axml := NULL::XML;
    END IF;

    -- grab holdings if we need them
    IF ('holdings_xml' = ANY (includes)) THEN 
        hxml := unapi.holdings_xml(obj_id, ouid, org, depth, array_remove(includes,'holdings_xml'), slimit, soffset, include_xmlns, pref_lib, library_group);
    ELSE
        hxml := NULL::XML;
    END IF;


    -- generate our item node


    IF format = 'marcxml' THEN
        tmp_xml := me.marc;
        IF tmp_xml !~ E'<marc:' THEN -- If we're not using the prefixed namespace in this record, then remove all declarations of it
           tmp_xml := REGEXP_REPLACE(tmp_xml, ' xmlns:marc="http://www.loc.gov/MARC21/slim"', '', 'g');
        END IF; 
    ELSE
        tmp_xml := oils_xslt_process(me.marc, xfrm.xslt)::XML;
    END IF;

    top_el := REGEXP_REPLACE(tmp_xml, E'^.*?<((?:\\S+:)?' || layout.holdings_element || ').*$', E'\\1');

    IF source IS NOT NULL THEN
        tmp_xml := REGEXP_REPLACE(tmp_xml, '</' || top_el || '>(.*?)$', source || '</' || top_el || E'>\\1');
    END IF;

    IF axml IS NOT NULL THEN 
        tmp_xml := REGEXP_REPLACE(tmp_xml, '</' || top_el || '>(.*?)$', axml || '</' || top_el || E'>\\1');
    END IF;

    IF hxml IS NOT NULL THEN -- XXX how do we configure the holdings position?
        tmp_xml := REGEXP_REPLACE(tmp_xml, '</' || top_el || '>(.*?)$', hxml || '</' || top_el || E'>\\1');
    END IF;

    IF ('bre.unapi' = ANY (includes)) THEN 
        output := REGEXP_REPLACE(
            tmp_xml,
            '</' || top_el || '>(.*?)',
            XMLELEMENT(
                name abbr,
                XMLATTRIBUTES(
                    'http://www.w3.org/1999/xhtml' AS xmlns,
                    'unapi-id' AS class,
                    'tag:open-ils.org:U2@bre/' || obj_id || '/' || org AS title
                )
            )::TEXT || '</' || top_el || E'>\\1'
        );
    ELSE
        output := tmp_xml;
    END IF;

    IF ('bre.extern' = ANY (includes)) THEN 
        output := REGEXP_REPLACE(
            tmp_xml,
            '</' || top_el || '>(.*?)',
            XMLELEMENT(
                name extern,
                XMLATTRIBUTES(
                    'http://open-ils.org/spec/biblio/v1' AS xmlns,
                    me.creator AS creator,
                    me.editor AS editor,
                    me.create_date AS create_date,
                    me.edit_date AS edit_date,
                    me.quality AS quality,
                    me.fingerprint AS fingerprint,
                    me.tcn_source AS tcn_source,
                    me.tcn_value AS tcn_value,
                    me.owner AS owner,
                    me.share_depth AS share_depth,
                    me.active AS active,
                    me.deleted AS deleted
                )
            )::TEXT || '</' || top_el || E'>\\1'
        );
    ELSE
        output := tmp_xml;
    END IF;

    output := REGEXP_REPLACE(output::TEXT,E'>\\s+<','><','gs')::XML;
    RETURN output;
END;
$F$ LANGUAGE PLPGSQL STABLE;

DROP FUNCTION IF EXISTS unapi.biblio_record_entry_feed (
    id_list BIGINT[],
    format TEXT,
    includes TEXT[],
    org TEXT,
    depth INT,
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL,
    title TEXT,
    description TEXT,
    creator TEXT,
    update_ts TEXT,
    unapi_url TEXT,
    header_xml XML,
    pref_lib INT);
CREATE OR REPLACE FUNCTION unapi.biblio_record_entry_feed (
    id_list BIGINT[],
    format TEXT,
    includes TEXT[],
    org TEXT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL, 
    include_xmlns BOOL DEFAULT TRUE,
    title TEXT DEFAULT NULL,
    description TEXT DEFAULT NULL,
    creator TEXT DEFAULT NULL,
    update_ts TEXT DEFAULT NULL,
    unapi_url TEXT DEFAULT NULL,
    header_xml XML DEFAULT NULL,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL
     ) RETURNS XML AS $F$
DECLARE
    layout          unapi.bre_output_layout%ROWTYPE;
    transform       config.xml_transform%ROWTYPE;
    item_format     TEXT;
    tmp_xml         TEXT;
    xmlns_uri       TEXT := 'http://open-ils.org/spec/feed-xml/v1';
    ouid            INT;
    element_list    TEXT[];
BEGIN

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;
    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO transform FROM config.xml_transform WHERE name = layout.transform;
    xmlns_uri := COALESCE(transform.namespace_uri,xmlns_uri);

    -- Gather the bib xml
    SELECT XMLAGG( unapi.bre(i, format, '', includes, org, depth, slimit, soffset, include_xmlns, pref_lib, library_group)) INTO tmp_xml FROM UNNEST( id_list ) i;

    IF layout.title_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.title_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, title;
    END IF;

    IF layout.description_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.description_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, description;
    END IF;

    IF layout.creator_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.creator_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, creator;
    END IF;

    IF layout.update_ts_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.update_ts_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, update_ts;
    END IF;

    IF unapi_url IS NOT NULL THEN
        EXECUTE $$SELECT XMLCONCAT( XMLELEMENT( name link, XMLATTRIBUTES( 'http://www.w3.org/1999/xhtml' AS xmlns, 'unapi-server' AS rel, $1 AS href, 'unapi' AS title)), $2)$$ INTO tmp_xml USING unapi_url, tmp_xml::XML;
    END IF;

    IF header_xml IS NOT NULL THEN tmp_xml := XMLCONCAT(header_xml,tmp_xml::XML); END IF;

    element_list := regexp_split_to_array(layout.feed_top,E'\\.');
    FOR i IN REVERSE ARRAY_UPPER(element_list, 1) .. 1 LOOP
        EXECUTE 'SELECT XMLELEMENT( name '|| quote_ident(element_list[i]) ||', XMLATTRIBUTES( $1 AS xmlns), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML;
    END LOOP;

    RETURN tmp_xml::XML;
END;
$F$ LANGUAGE PLPGSQL STABLE;


DROP FUNCTION IF EXISTS unapi.metabib_virtual_record_feed (
    id_list BIGINT[],
    format TEXT,
    includes TEXT[],
    org TEXT,
    depth INT,
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL, title TEXT,
    description TEXT,
    creator TEXT,
    update_ts TEXT,
    unapi_url TEXT,
    header_xml XML,
    pref_lib INT);
CREATE OR REPLACE FUNCTION unapi.metabib_virtual_record_feed (
    id_list BIGINT[],
    format TEXT,
    includes TEXT[],
    org TEXT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    title TEXT DEFAULT NULL,
    description TEXT DEFAULT NULL,
    creator TEXT DEFAULT NULL,
    update_ts TEXT DEFAULT NULL,
    unapi_url TEXT DEFAULT NULL,
    header_xml XML DEFAULT NULL,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL ) RETURNS XML AS $F$
DECLARE
    layout          unapi.bre_output_layout%ROWTYPE;
    transform       config.xml_transform%ROWTYPE;
    item_format     TEXT;
    tmp_xml         TEXT;
    xmlns_uri       TEXT := 'http://open-ils.org/spec/feed-xml/v1';
    ouid            INT;
    element_list    TEXT[];
BEGIN

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;
    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO transform FROM config.xml_transform WHERE name = layout.transform;
    xmlns_uri := COALESCE(transform.namespace_uri,xmlns_uri);

    -- Gather the bib xml
    SELECT XMLAGG( unapi.mmr(i, format, '', includes, org, depth, slimit, soffset, include_xmlns, pref_lib, library_group)) INTO tmp_xml FROM UNNEST( id_list ) i;

    IF layout.title_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.title_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, title;
    END IF;

    IF layout.description_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.description_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, description;
    END IF;

    IF layout.creator_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.creator_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, creator;
    END IF;

    IF layout.update_ts_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.update_ts_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, update_ts;
    END IF;

    IF unapi_url IS NOT NULL THEN
        EXECUTE $$SELECT XMLCONCAT( XMLELEMENT( name link, XMLATTRIBUTES( 'http://www.w3.org/1999/xhtml' AS xmlns, 'unapi-server' AS rel, $1 AS href, 'unapi' AS title)), $2)$$ INTO tmp_xml USING unapi_url, tmp_xml::XML;
    END IF;

    IF header_xml IS NOT NULL THEN tmp_xml := XMLCONCAT(header_xml,tmp_xml::XML); END IF;

    element_list := regexp_split_to_array(layout.feed_top,E'\\.');
    FOR i IN REVERSE ARRAY_UPPER(element_list, 1) .. 1 LOOP
        EXECUTE 'SELECT XMLELEMENT( name '|| quote_ident(element_list[i]) ||', XMLATTRIBUTES( $1 AS xmlns), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML;
    END LOOP;

    RETURN tmp_xml::XML;
END;
$F$ LANGUAGE PLPGSQL STABLE;


DROP FUNCTION IF EXISTS unapi.mmr(
    obj_id BIGINT,
    format TEXT,
    ename TEXT,
    includes TEXT[],
    org TEXT,
    depth INT,
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL,
    pref_lib INT
);

CREATE OR REPLACE FUNCTION unapi.mmr (
    obj_id BIGINT,
    format TEXT,
    ename TEXT,
    includes TEXT[],
    org TEXT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL
)
RETURNS XML AS $F$
DECLARE
    mmrec   metabib.metarecord%ROWTYPE;
    leadrec biblio.record_entry%ROWTYPE;
    subrec biblio.record_entry%ROWTYPE;
    layout  unapi.bre_output_layout%ROWTYPE;
    xfrm    config.xml_transform%ROWTYPE;
    ouid    INT;
    xml_buf TEXT; -- growing XML document
    tmp_xml TEXT; -- single-use XML string
    xml_frag TEXT; -- single-use XML fragment
    top_el  TEXT;
    output  XML;
    hxml    XML;
    axml    XML;
    subxml  XML; -- subordinate records elements
    sub_xpath TEXT; 
    parts   TEXT[]; 
BEGIN

    -- xpath for extracting bre.marc values from subordinate records 
    -- so they may be appended to the MARC of the master record prior
    -- to XSLT processing.
    -- subjects, isbn, issn, upc -- anything else?
    sub_xpath := 
      '//*[starts-with(@tag, "6") or @tag="020" or @tag="022" or @tag="024"]';

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;

    IF ouid IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT INTO mmrec * FROM metabib.metarecord WHERE id = obj_id;
    IF NOT FOUND THEN
        RETURN NULL::XML;
    END IF;

    -- TODO: aggregate holdings from constituent records
    IF format = 'holdings_xml' THEN -- the special case
        output := unapi.mmr_holdings_xml(
            obj_id, ouid, org, depth,
            array_remove(includes,'holdings_xml'),
            slimit, soffset, include_xmlns, pref_lib, library_group);
        RETURN output;
    END IF;

    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO xfrm FROM config.xml_transform WHERE name = layout.transform;

    SELECT INTO leadrec * FROM biblio.record_entry WHERE id = mmrec.master_record;

    -- Grab distinct MVF for all records if requested
    IF ('mra' = ANY (includes)) THEN 
        axml := unapi.mmr_mra(obj_id,NULL,NULL,NULL,org,depth,NULL,NULL,TRUE,pref_lib);
    ELSE
        axml := NULL::XML;
    END IF;

    xml_buf = leadrec.marc;

    hxml := NULL::XML;
    IF ('holdings_xml' = ANY (includes)) THEN
        hxml := unapi.mmr_holdings_xml(
                    obj_id, ouid, org, depth,
                    array_remove(includes,'holdings_xml'),
                    slimit, soffset, include_xmlns, pref_lib, library_group);
    END IF;

    subxml := NULL::XML;
    parts := '{}'::TEXT[];
    FOR subrec IN SELECT bre.* FROM biblio.record_entry bre
         JOIN metabib.metarecord_source_map mmsm ON (mmsm.source = bre.id)
         JOIN metabib.metarecord mmr ON (mmr.id = mmsm.metarecord)
         WHERE mmr.id = obj_id AND NOT bre.deleted
         ORDER BY CASE WHEN bre.id = mmr.master_record THEN 0 ELSE bre.id END
         LIMIT COALESCE((slimit->'bre')::INT, 5) LOOP

        IF subrec.id = leadrec.id THEN CONTINUE; END IF;
        -- Append choice data from the the non-lead records to the 
        -- the lead record document

        parts := parts || xpath(sub_xpath, subrec.marc::XML)::TEXT[];
    END LOOP;

    SELECT STRING_AGG( DISTINCT p , '' )::XML INTO subxml FROM UNNEST(parts) p;

    -- append data from the subordinate records to the 
    -- main record document before applying the XSLT

    IF subxml IS NOT NULL THEN 
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</record>(.*?)$', subxml || '</record>' || E'\\1');
    END IF;

    IF format = 'marcxml' THEN
         -- If we're not using the prefixed namespace in 
         -- this record, then remove all declarations of it
        IF xml_buf !~ E'<marc:' THEN
           xml_buf := REGEXP_REPLACE(xml_buf, 
            ' xmlns:marc="http://www.loc.gov/MARC21/slim"', '', 'g');
        END IF; 
    ELSE
        xml_buf := oils_xslt_process(xml_buf, xfrm.xslt)::XML;
    END IF;

    -- update top_el to reflect the change in xml_buf, which may
    -- now be a different type of document (e.g. record -> mods)
    top_el := REGEXP_REPLACE(xml_buf, E'^.*?<((?:\\S+:)?' || 
        layout.holdings_element || ').*$', E'\\1');

    IF axml IS NOT NULL THEN 
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</' || top_el || '>(.*?)$', axml || '</' || top_el || E'>\\1');
    END IF;

    IF hxml IS NOT NULL THEN
        xml_buf := REGEXP_REPLACE(xml_buf, 
            '</' || top_el || '>(.*?)$', hxml || '</' || top_el || E'>\\1');
    END IF;

    IF ('mmr.unapi' = ANY (includes)) THEN 
        output := REGEXP_REPLACE(
            xml_buf,
            '</' || top_el || '>(.*?)',
            XMLELEMENT(
                name abbr,
                XMLATTRIBUTES(
                    'http://www.w3.org/1999/xhtml' AS xmlns,
                    'unapi-id' AS class,
                    'tag:open-ils.org:U2@mmr/' || obj_id || '/' || org AS title
                )
            )::TEXT || '</' || top_el || E'>\\1'
        );
    ELSE
        output := xml_buf;
    END IF;

    -- remove ignorable whitesace
    output := REGEXP_REPLACE(output::TEXT,E'>\\s+<','><','gs')::XML;
    RETURN output;
END;
$F$ LANGUAGE PLPGSQL STABLE;

DROP FUNCTION IF EXISTS unapi.mmr_holdings_xml (
    mid BIGINT,
    ouid INT,
    org TEXT,
    depth INT,
    includes TEXT[],
    slimit HSTORE,
    soffset HSTORE,
    include_xmlns BOOL,
    pref_lib INT
);

CREATE OR REPLACE FUNCTION unapi.mmr_holdings_xml (
    mid BIGINT,
    ouid INT,
    org TEXT,
    depth INT DEFAULT NULL,
    includes TEXT[] DEFAULT NULL::TEXT[],
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    include_xmlns BOOL DEFAULT TRUE,
    pref_lib INT DEFAULT NULL,
    library_group INT DEFAULT NULL
)
RETURNS XML AS $F$
     SELECT  XMLELEMENT(
                 name holdings,
                 XMLATTRIBUTES(
                    CASE WHEN $8 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                    CASE WHEN ('mmr' = ANY ($5)) THEN 'tag:open-ils.org:U2@mmr/' || $1 || '/' || $3 ELSE NULL END AS id,
                    (SELECT metarecord_has_holdable_copy FROM asset.metarecord_has_holdable_copy($1)) AS has_holdable
                 ),
                 XMLELEMENT(
                     name counts,
                     (SELECT  XMLAGG(XMLELEMENT::XML) FROM (
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('public' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_ou_metarecord_copy_count($2,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('staff' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.staff_ou_metarecord_copy_count($2, $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('pref_lib' as type, depth, org_unit, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_ou_metarecord_copy_count($9,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('public' as type, depth, library_group, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.opac_lasso_metarecord_copy_count_sum(library_group,  $1)
                                     UNION
                         SELECT  XMLELEMENT(
                                     name count,
                                     XMLATTRIBUTES('staff' as type, depth, library_group, coalesce(transcendant,0) as transcendant, available, visible as count, unshadow)
                                 )::text
                           FROM  asset.staff_lasso_metarecord_copy_count_sum(library_group,  $1)
                                     ORDER BY 1
                     )x)
                 ),
                 -- XXX monograph_parts and foreign_copies are skipped in MRs ... put them back some day?
                 XMLELEMENT(
                     name volumes,
                     (SELECT XMLAGG(acn ORDER BY rank, name, label_sortkey) FROM (
                        -- Physical copies
                        SELECT  unapi.acn(y.id,'xml','volume',array_remove( array_remove($5,'holdings_xml'),'bre'), $3, $4, $6, $7, FALSE), y.rank, name, label_sortkey
                        FROM evergreen.ranked_volumes((SELECT ARRAY_AGG(source) FROM metabib.metarecord_source_map WHERE metarecord = $1), $2, $4, $6, $7, $9, $5) AS y
                        UNION ALL
                        -- Located URIs
                        SELECT unapi.acn(uris.id,'xml','volume',array_remove( array_remove($5,'holdings_xml'),'bre'), $3, $4, $6, $7, FALSE), uris.rank, name, label_sortkey
                        FROM evergreen.located_uris((SELECT ARRAY_AGG(source) FROM metabib.metarecord_source_map WHERE metarecord = $1), $2, $9) AS uris
                     )x)
                 ),
                 CASE WHEN ('ssub' = ANY ($5)) THEN
                     XMLELEMENT(
                         name subscriptions,
                         (SELECT XMLAGG(ssub) FROM (
                            SELECT  unapi.ssub(id,'xml','subscription','{}'::TEXT[], $3, $4, $6, $7, FALSE)
                              FROM  serial.subscription
                              WHERE record_entry IN (SELECT source FROM metabib.metarecord_source_map WHERE metarecord = $1)
                        )x)
                     )
                 ELSE NULL END
             );
$F$ LANGUAGE SQL STABLE;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1465', :eg_version);

ALTER TABLE config.ui_staff_portal_page_entry
ADD COLUMN url_newtab boolean;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1466', :eg_version);

INSERT into config.workstation_setting_type
    (name, grp, label, description, datatype)
VALUES (
    'ui.staff.disable_links_newtabs',
    'gui',
    oils_i18n_gettext('ui.staff.disable_links_newtabs',
        'Staff Client: no new tabs',
        'coust', 'label'),
    oils_i18n_gettext('ui.staff.disable_links_newtabs',
        'Prevents links in the staff interface from opening in new tabs or windows.',
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1467', :eg_version);

CREATE TABLE action.eresource_link_click (
    id          BIGSERIAL PRIMARY KEY,
    clicked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    url         TEXT,
    record      BIGINT NOT NULL REFERENCES biblio.record_entry (id)
);

CREATE TABLE action.eresource_link_click_course (
    id            SERIAL      PRIMARY KEY,
    click         BIGINT NOT NULL REFERENCES action.eresource_link_click (id) ON DELETE CASCADE,
    course        INT REFERENCES asset.course_module_course (id) ON UPDATE CASCADE ON DELETE SET NULL,
    course_name   TEXT NOT NULL,
    course_number TEXT NOT NULL
);

INSERT INTO config.global_flag  (name, label, enabled)
    VALUES (
        'opac.eresources.link_click_tracking',
        oils_i18n_gettext('opac.eresources.link_click_tracking',
                          'Track clicks on eresources links.  Before enabling this global flag, be sure that you are monitoring disk space on your database server and have a cron job set up to delete click records after the desired retention interval.',
                          'cgf', 'label'),
        FALSE
    );

CREATE FUNCTION action.delete_old_eresource_link_clicks(days integer)
    RETURNS VOID AS
    'DELETE FROM action.eresource_link_click
     WHERE clicked_at < current_timestamp
               - ($1::text || '' days'')::interval'
    LANGUAGE SQL
    VOLATILE;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1468', :eg_version);

-- Necessary pre-seed data


INSERT INTO actor.passwd_type (code, name, login, crypt_algo, iter_count)
    VALUES ('api', 'OpenAPI Integration Password', TRUE, 'bf', 10)
ON CONFLICT DO NOTHING;

-- Move top-level perms "down" while avoiding direct-child-defined overrides
WITH old_perms AS ( DELETE FROM permission.grp_perm_map WHERE grp = 1 RETURNING * )
INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
  SELECT  g.id, o.perm, o.depth, o.grantable
    FROM  old_perms o,
          permission.grp_tree g
    WHERE g.parent = 1
  ON CONFLICT DO NOTHING; -- Conflicts with perm_grp_once to skip existing entries

-- ... and add a new branch to the group tree for API perms
INSERT INTO permission.grp_tree (name, parent, description, application_perm)
    VALUES ('API Integrator', 1, 'API Integration Accounts', 'group_application.api_integrator');

INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Patron API', id, 'Patron API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Org Unit API', id, 'Org Unit API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Bib Record API', id, 'Bib Record API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Item Record API', id, 'Item Record API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Holds API', id, 'Holds API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Debt Collection API', id, 'Debt Collection API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';
INSERT INTO permission.grp_tree (name, parent, description, application_perm) SELECT 'Course Reserves API', id, 'Course Reserves API', 'group_application.api_integrator' FROM permission.grp_tree WHERE name = 'API Integrator';

INSERT INTO permission.perm_list (code) VALUES
 ('group_application.api_integrator'),
 ('API_LOGIN'),
 ('REST.api'),
 ('REST.api.patrons'),
 ('REST.api.orgs'),
 ('REST.api.bibs'),
 ('REST.api.items'),
 ('REST.api.holds'),
 ('REST.api.collections'),
 ('REST.api.courses')
 --- ... etc
ON CONFLICT DO NOTHING;

INSERT INTO permission.grp_perm_map (grp,perm,depth)
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='API Integrator' AND p.code IN ('API_LOGIN','REST.api')
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Patron API' AND p.code = 'REST.api.patrons'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Org Unit API' AND p.code = 'REST.api.orgs'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Bib Record API' AND p.code = 'REST.api.bibs'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Item Record API' AND p.code = 'REST.api.items'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Holds API' AND p.code = 'REST.api.holds'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Debt Collection API' AND p.code = 'REST.api.collections'
        UNION
    SELECT g.id, p.id, 0 FROM permission.grp_tree g, permission.perm_list p WHERE g.name='Course Reserves API' AND p.code = 'REST.api.courses'
ON CONFLICT DO NOTHING;

DROP SCHEMA IF EXISTS openapi CASCADE;
CREATE SCHEMA IF NOT EXISTS openapi;

CREATE TABLE IF NOT EXISTS openapi.integrator (
    id      INT     PRIMARY KEY REFERENCES actor.usr (id),
    enabled BOOL    NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS openapi.json_schema_datatype (
    name        TEXT    PRIMARY KEY,
    label       TEXT    NOT NULL UNIQUE,
    description TEXT
);
INSERT INTO openapi.json_schema_datatype (name,label) VALUES
    ('boolean','Boolean'),
    ('string','String'),
    ('integer','Integer'),
    ('number','Number'),
    ('array','Array'),
    ('object','Object')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.json_schema_format (
    name        TEXT    PRIMARY KEY,
    label       TEXT    NOT NULL UNIQUE,
    description TEXT
);
INSERT INTO openapi.json_schema_format (name,label) VALUES
    ('date-time','Timestamp'),
    ('date','Date'),
    ('time','Time'),
    ('interval','Interval'),
    ('email','Email Address'),
    ('uri','URI'),
    ('identifier','Opaque Identifier'),
    ('money','Money'),
    ('float','Floating Point Number'),
    ('int64','Large Integer'),
    ('password','Password')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.rate_limit_definition (
    id              SERIAL      PRIMARY KEY,
    name            TEXT        UNIQUE NOT NULL, -- i18n
    limit_interval  INTERVAL    NOT NULL,
    limit_count     INT         NOT NULL
);
SELECT SETVAL('openapi.rate_limit_definition_id_seq'::TEXT, 100);
INSERT INTO openapi.rate_limit_definition (id, name, limit_interval, limit_count) VALUES
    (1, 'Once per second', '1 second', 1),
    (2, 'Ten per minute', '1 minute', 10),
    (3, 'One hunderd per hour', '1 hour', 100),
    (4, 'One thousand per hour', '1 hour', 1000),
    (5, 'One thousand per 24 hour period', '24 hours', 1000),
    (6, 'Ten thousand per 24 hour period', '24 hours', 10000),
    (7, 'Unlimited', '1 second', 1000000),
    (8, 'One hundred per second', '1 second', 100)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.endpoint (
    operation_id    TEXT    PRIMARY KEY,
    path            TEXT    NOT NULL,
    http_method     TEXT    NOT NULL CHECK (http_method IN ('get','put','post','delete','patch')),
    security        TEXT    NOT NULL DEFAULT 'bearerAuth' CHECK (security IN ('bearerAuth','basicAuth','cookieAuth','paramAuth')),
    summary         TEXT    NOT NULL,
    method_source   TEXT    NOT NULL, -- perl module or opensrf application, tested by regex and assumes opensrf app name contains a "."
    method_name     TEXT    NOT NULL,
    method_params   TEXT,             -- eg, 'eg_auth_token hold' or 'eg_auth_token eg_user_id circ req.json'
    active          BOOL    NOT NULL DEFAULT TRUE,
    rate_limit      INT     REFERENCES openapi.rate_limit_definition (id),
    CONSTRAINT path_and_method_once UNIQUE (path, http_method)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_param (
    id              SERIAL  PRIMARY KEY,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    name            TEXT    NOT NULL CHECK (name ~ '^\w+$'),
    required        BOOL    NOT NULL DEFAULT FALSE,
    in_part         TEXT    NOT NULL DEFAULT 'query' CHECK (in_part IN ('path','query','header','cookie')),
    fm_type         TEXT,
    schema_type     TEXT    REFERENCES openapi.json_schema_datatype (name),
    schema_format   TEXT    REFERENCES openapi.json_schema_format (name),
    array_items     TEXT    REFERENCES openapi.json_schema_datatype (name),
    default_value   TEXT,
    CONSTRAINT endpoint_and_name_once UNIQUE (endpoint, name),
    CONSTRAINT format_requires_type CHECK (schema_format IS NULL OR schema_type IS NOT NULL),
    CONSTRAINT array_items_requires_array_type CHECK (array_items IS NULL OR schema_type = 'array')
);
CREATE TABLE IF NOT EXISTS openapi.endpoint_response (
    id              SERIAL  PRIMARY KEY,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    validate        BOOL    NOT NULL DEFAULT TRUE,
    status          INT     NOT NULL DEFAULT 200,
    content_type    TEXT    NOT NULL DEFAULT 'application/json',
    description     TEXT    NOT NULL DEFAULT 'Success',
    fm_type         TEXT,
    schema_type     TEXT    REFERENCES openapi.json_schema_datatype (name),
    schema_format   TEXT    REFERENCES openapi.json_schema_format (name),
    array_items     TEXT    REFERENCES openapi.json_schema_datatype (name),
    CONSTRAINT endpoint_status_content_type_once UNIQUE (endpoint, status, content_type)
);

CREATE TABLE IF NOT EXISTS openapi.perm_set (
    id              SERIAL  PRIMARY KEY,
    name            TEXT    NOT NULL
); -- push sequence value
SELECT SETVAL('openapi.perm_set_id_seq'::TEXT, 1001);
INSERT INTO openapi.perm_set (id, name) VALUES
 (1,'Self - API only'),
 (2,'Patrons - API only'),
 (3,'Orgs - API only'),
 (4,'Bibs - API only'),
 (5,'Items - API only'),
 (6,'Holds - API only'),
 (7,'Collections - API only'),
 (8,'Courses - API only'),

 (101,'Self - standard permissions'),
 (102,'Patrons - standard permissions'),
 (103,'Orgs - standard permissions'),
 (104,'Bibs - standard permissions'),
 (105,'Items - standard permissions'),
 (106,'Holds - standard permissions'),
 (107,'Collections - standard permissions'),
 (108,'Courses - standard permissions')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.perm_set_perm_map (
    id          SERIAL  PRIMARY KEY,
    perm_set    INT     NOT NULL REFERENCES openapi.perm_set (id) ON UPDATE CASCADE ON DELETE CASCADE,
    perm        INT     NOT NULL REFERENCES permission.perm_list (id) ON UPDATE CASCADE ON DELETE CASCADE
);
INSERT INTO openapi.perm_set_perm_map (perm_set, perm)
  SELECT 1, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api')
    UNION
  SELECT 2, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.patrons')
    UNION
  SELECT 3, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.orgs')
    UNION
  SELECT 4, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.bibs')
    UNION
  SELECT 5, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.items')
    UNION
  SELECT 6, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.holds')
    UNION
  SELECT 7, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.collections')
    UNION
  SELECT 8, id FROM permission.perm_list WHERE code IN ('API_LOGIN','REST.api','REST.api.cources')
    UNION
                -- ...
  SELECT 101, id FROM permission.perm_list WHERE code IN ('OPAC_LOGIN')
    UNION
  SELECT 102, id FROM permission.perm_list WHERE code IN ('STAFF_LOGIN','VIEW_USER')
    UNION
  SELECT 103, id FROM permission.perm_list WHERE code IN ('OPAC_LOGIN')
    UNION
  SELECT 104, id FROM permission.perm_list WHERE code IN ('OPAC_LOGIN')
    UNION
  SELECT 105, id FROM permission.perm_list WHERE code IN ('OPAC_LOGIN')
    UNION
  SELECT 106, id FROM permission.perm_list WHERE code IN ('STAFF_LOGIN','VIEW_USER')
    UNION
  SELECT 107, id FROM permission.perm_list WHERE code IN ('STAFF_LOGIN','VIEW_USER')
    UNION
  SELECT 108, id FROM permission.perm_list WHERE code IN ('STAFF_LOGIN')

ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.endpoint_perm_set_map (
    id              SERIAL  PRIMARY KEY,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint(operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    perm_set        INT     NOT NULL REFERENCES openapi.perm_set (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_set (
    name            TEXT    PRIMARY KEY,
    description     TEXT    NOT NULL,
    active          BOOL    NOT NULL DEFAULT TRUE,
    rate_limit      INT     REFERENCES openapi.rate_limit_definition (id)
);
INSERT INTO openapi.endpoint_set (name, description) VALUES
  ('self', 'Methods for retrieving and manipulating your own user account information'),
  ('orgs', 'Methods for retrieving and manipulating organizational unit information'),
  ('patrons', 'Methods for retrieving and manipulating patron information'),
  ('holds', 'Methods for accessing and manipulating hold data'),
  ('collections', 'Methods for accessing and manipulating patron debt collections data'),
  ('bibs', 'Methods for accessing and manipulating bibliographic records and related data'),
  ('items', 'Methods for accessing and manipulating barcoded item records'),
  ('courses', 'Methods for accessing and manipulating course reserve data')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.endpoint_user_rate_limit_map (
    id              SERIAL  PRIMARY KEY,
    accessor        INT     NOT NULL REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE CASCADE,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    rate_limit      INT     NOT NULL REFERENCES openapi.rate_limit_definition (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT endpoint_accessor_once UNIQUE (accessor, endpoint)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_set_user_rate_limit_map (
    id              SERIAL  PRIMARY KEY,
    accessor        INT     NOT NULL REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE CASCADE,
    endpoint_set    TEXT    NOT NULL REFERENCES openapi.endpoint_set (name) ON UPDATE CASCADE ON DELETE CASCADE,
    rate_limit      INT     NOT NULL REFERENCES openapi.rate_limit_definition (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT endpoint_set_accessor_once UNIQUE (accessor, endpoint_set)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_ip_rate_limit_map (
    id              SERIAL  PRIMARY KEY,
    ip_range        INET    NOT NULL,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    rate_limit      INT     NOT NULL REFERENCES openapi.rate_limit_definition (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT endpoint_ip_range_once UNIQUE (ip_range, endpoint)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_set_ip_rate_limit_map (
    id              SERIAL  PRIMARY KEY,
    ip_range        INET    NOT NULL,
    endpoint_set    TEXT    NOT NULL REFERENCES openapi.endpoint_set (name) ON UPDATE CASCADE ON DELETE CASCADE,
    rate_limit      INT     NOT NULL REFERENCES openapi.rate_limit_definition (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT endpoint_set_ip_range_once UNIQUE (ip_range, endpoint_set)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_set_endpoint_map (
    id              SERIAL  PRIMARY KEY,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    endpoint_set    TEXT    NOT NULL REFERENCES openapi.endpoint_set (name) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT endpoint_set_endpoint_once UNIQUE (endpoint_set, endpoint)
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_perm_map (
    id              SERIAL  PRIMARY KEY,
    endpoint        TEXT    NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    perm            INT     NOT NULL REFERENCES permission.perm_list (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS openapi.endpoint_set_perm_set_map (
    id              SERIAL  PRIMARY KEY,
    endpoint_set    TEXT    NOT NULL REFERENCES openapi.endpoint_set (name) ON UPDATE CASCADE ON DELETE CASCADE,
    perm_set        INT     NOT NULL REFERENCES openapi.perm_set (id) ON UPDATE CASCADE ON DELETE CASCADE
);
INSERT INTO openapi.endpoint_set_perm_set_map (endpoint_set, perm_set) VALUES
  ('self', 1),        ('self', 101),
  ('patrons', 2),     ('patrons', 102),
  ('orgs', 3),        ('orgs', 103),
  ('bibs', 4),        ('bibs', 104),
  ('items', 5),       ('items', 105),
  ('holds', 6),       ('holds', 106),
  ('collections', 7), ('collections', 107),
  ('courses', 8),     ('courses', 108)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS openapi.endpoint_set_perm_map (
    id              SERIAL  PRIMARY KEY,
    endpoint_set    TEXT    NOT NULL REFERENCES openapi.endpoint_set (name) ON UPDATE CASCADE ON DELETE CASCADE,
    perm            INT     NOT NULL REFERENCES permission.perm_list (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS openapi.authen_attempt_log (
    request_id      TEXT        PRIMARY KEY,
    attempt_time    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_addr         INET,
    cred_user       TEXT,
    token           TEXT
);
CREATE INDEX authen_cred_user_attempt_time_idx ON openapi.authen_attempt_log (attempt_time, cred_user);
CREATE INDEX authen_ip_addr_attempt_time_idx ON openapi.authen_attempt_log (attempt_time, ip_addr);

CREATE TABLE IF NOT EXISTS openapi.endpoint_access_attempt_log (
    request_id      TEXT        PRIMARY KEY,
    attempt_time    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    endpoint        TEXT        NOT NULL REFERENCES openapi.endpoint (operation_id) ON UPDATE CASCADE ON DELETE CASCADE,
    allowed         BOOL        NOT NULL,
    ip_addr         INET,
    accessor        INT         REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE CASCADE,
    token           TEXT
);
CREATE INDEX access_accessor_attempt_time_idx ON openapi.endpoint_access_attempt_log (accessor, attempt_time);

CREATE TABLE IF NOT EXISTS openapi.endpoint_dispatch_log (
    request_id      TEXT        PRIMARY KEY,
    complete_time   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error           BOOL        NOT NULL
);

CREATE OR REPLACE FUNCTION actor.verify_passwd(pw_usr integer, pw_type text, test_passwd text) RETURNS boolean AS $f$
DECLARE
    pw_salt     TEXT;
    api_enabled BOOL;
BEGIN
    /* Returns TRUE if the password provided matches the in-db password.
     * If the password type is salted, we compare the output of CRYPT().
     * NOTE: test_passwd is MD5(salt || MD5(password)) for legacy
     * 'main' passwords.
     *
     * Password type 'api' requires that the user be enabled as an
     * integrator in the openapi.integrator table.
     */

    IF pw_type = 'api' THEN
        SELECT  enabled INTO api_enabled
          FROM  openapi.integrator
          WHERE id = pw_usr;

        IF NOT FOUND OR api_enabled IS FALSE THEN
            -- API integrator account not registered
            RETURN FALSE;
        END IF;
    END IF;

    SELECT INTO pw_salt salt FROM actor.passwd
        WHERE usr = pw_usr AND passwd_type = pw_type;

    IF NOT FOUND THEN
        -- no such password
        RETURN FALSE;
    END IF;

    IF pw_salt IS NULL THEN
        -- Password is unsalted, compare the un-CRYPT'ed values.
        RETURN EXISTS (
            SELECT TRUE FROM actor.passwd WHERE
                usr = pw_usr AND
                passwd_type = pw_type AND
                passwd = test_passwd
        );
    END IF;

    RETURN EXISTS (
        SELECT TRUE FROM actor.passwd WHERE
            usr = pw_usr AND
            passwd_type = pw_type AND
            passwd = CRYPT(test_passwd, pw_salt)
    );
END;
$f$ STRICT LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION openapi.find_default_endpoint_rate_limit (target_endpoint TEXT) RETURNS openapi.rate_limit_definition AS $f$
DECLARE
    def_rl    openapi.rate_limit_definition%ROWTYPE;
BEGIN
    -- Default rate limits can be applied at the endpoint or endpoint_set level;
    -- endpoint overrides endpoint_set, and we choose the most restrictive from
    -- the set if we have to look there.
    SELECT  d.* INTO def_rl
      FROM  openapi.rate_limit_definition d
            JOIN openapi.endpoint e ON (e.rate_limit = d.id)
      WHERE e.operation_id = target_endpoint;

    IF NOT FOUND THEN
        SELECT  d.* INTO def_rl
          FROM  openapi.rate_limit_definition d
                JOIN openapi.endpoint_set es ON (es.rate_limit = d.id)
                JOIN openapi.endpoint_set_endpoint_map m ON (es.name = m.endpoint_set AND m.endpoint = target_endpoint)
           -- This ORDER BY calculates the avg time between requests the user would have to wait to perfectly
           -- avoid rate limiting.  So, a bigger wait means it's more restrictive.  We take the most restrictive
           -- set-applied one.
          ORDER BY EXTRACT(EPOCH FROM d.limit_interval) / d.limit_count::NUMERIC DESC
          LIMIT 1;
    END IF;

    -- If there's no default for the endpoint or set, we provide 1/sec.
    IF NOT FOUND THEN
        def_rl.limit_interval := '1 second'::INTERVAL;
        def_rl.limit_count := 1;
    END IF;

    RETURN def_rl;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION openapi.find_user_endpoint_rate_limit (target_endpoint TEXT, accessing_usr INT) RETURNS openapi.rate_limit_definition AS $f$
DECLARE
    def_u_rl    openapi.rate_limit_definition%ROWTYPE;
BEGIN
    SELECT  d.* INTO def_u_rl
      FROM  openapi.rate_limit_definition d
            JOIN openapi.endpoint_user_rate_limit_map e ON (e.rate_limit = d.id)
      WHERE e.endpoint = target_endpoint
            AND e.accessor = accessing_usr;

    IF NOT FOUND THEN
        SELECT  d.* INTO def_u_rl
          FROM  openapi.rate_limit_definition d
                JOIN openapi.endpoint_set_user_rate_limit_map e ON (e.rate_limit = d.id AND e.accessor = accessing_usr)
                JOIN openapi.endpoint_set_endpoint_map m ON (e.endpoint_set = m.endpoint_set AND m.endpoint = target_endpoint)
          ORDER BY EXTRACT(EPOCH FROM d.limit_interval) / d.limit_count::NUMERIC DESC
          LIMIT 1;
    END IF;

    RETURN def_u_rl;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION openapi.find_ip_addr_endpoint_rate_limit (target_endpoint TEXT, from_ip_addr INET) RETURNS openapi.rate_limit_definition AS $f$
DECLARE
    def_i_rl    openapi.rate_limit_definition%ROWTYPE;
BEGIN
    SELECT  d.* INTO def_i_rl
      FROM  openapi.rate_limit_definition d
            JOIN openapi.endpoint_ip_rate_limit_map e ON (e.rate_limit = d.id)
      WHERE e.endpoint = target_endpoint
            AND e.ip_range && from_ip_addr
       -- For IPs, we order first by the size of the ranges that we
       -- matched (mask length), most specific (smallest block of IPs)
       -- first, then by the restrictiveness of the limit, more restrictive first.
      ORDER BY MASKLEN(e.ip_range) DESC, EXTRACT(EPOCH FROM d.limit_interval) / d.limit_count::NUMERIC DESC
      LIMIT 1;

    IF NOT FOUND THEN
        SELECT  d.* INTO def_i_rl
          FROM  openapi.rate_limit_definition d
                JOIN openapi.endpoint_set_ip_rate_limit_map e ON (e.rate_limit = d.id AND ip_range && from_ip_addr)
                JOIN openapi.endpoint_set_endpoint_map m ON (e.endpoint_set = m.endpoint_set AND m.endpoint = target_endpoint)
          ORDER BY MASKLEN(e.ip_range) DESC, EXTRACT(EPOCH FROM d.limit_interval) / d.limit_count::NUMERIC DESC
          LIMIT 1;
    END IF;

    RETURN def_i_rl;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION openapi.check_generic_endpoint_rate_limit (target_endpoint TEXT, accessing_usr INT DEFAULT NULL, from_ip_addr INET DEFAULT NULL) RETURNS INT AS $f$
DECLARE
    def_rl    openapi.rate_limit_definition%ROWTYPE;
    def_u_rl  openapi.rate_limit_definition%ROWTYPE;
    def_i_rl  openapi.rate_limit_definition%ROWTYPE;
    u_wait    INT;
    i_wait    INT;
BEGIN
    def_rl := openapi.find_default_endpoint_rate_limit(target_endpoint);

    IF accessing_usr IS NOT NULL THEN
        def_u_rl := openapi.find_user_endpoint_rate_limit(target_endpoint, accessing_usr);
    END IF;

    IF from_ip_addr IS NOT NULL THEN
        def_i_rl := openapi.find_ip_addr_endpoint_rate_limit(target_endpoint, from_ip_addr);
    END IF;

    -- Now we test the user-based and IP-based limits in their focused way...
    IF def_u_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO u_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.accessor ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.endpoint_access_attempt_log l
                  WHERE l.endpoint = target_endpoint
                        AND l.accessor = accessing_usr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    IF def_i_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO i_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.endpoint_access_attempt_log l
                  WHERE l.endpoint = target_endpoint
                        AND l.ip_addr = from_ip_addr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    -- If there are no user-specific or IP-based limit
    -- overrides; check endpoint-wide limits for user,
    -- then IP, and if we were passed neither, then limit
    -- endpoint access for all users.  Better to lock it
    -- all down than to set the servers on fire.
    IF COALESCE(u_wait, i_wait) IS NULL AND COALESCE(def_i_rl.id, def_u_rl.id) IS NULL THEN
        IF accessing_usr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.accessor ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.accessor = accessing_usr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSIF from_ip_addr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.ip_addr = from_ip_addr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSE -- we have no user and no IP, global per-endpoint rate limit?
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.endpoint ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        END IF;
    END IF;

    -- Send back the largest required wait time, or NULL for no restriction
    u_wait := GREATEST(u_wait,i_wait);
    IF u_wait > 0 THEN
        RETURN u_wait;
    END IF;

    RETURN NULL;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION openapi.check_auth_endpoint_rate_limit (accessing_usr TEXT DEFAULT NULL, from_ip_addr INET DEFAULT NULL) RETURNS INT AS $f$
DECLARE
    def_rl    openapi.rate_limit_definition%ROWTYPE;
    def_u_rl  openapi.rate_limit_definition%ROWTYPE;
    def_i_rl  openapi.rate_limit_definition%ROWTYPE;
    u_wait    INT;
    i_wait    INT;
BEGIN
    def_rl := openapi.find_default_endpoint_rate_limit('authenticateUser');

    IF accessing_usr IS NOT NULL THEN
        SELECT  (openapi.find_user_endpoint_rate_limit('authenticateUser', u.id)).* INTO def_u_rl
          FROM  actor.usr u
          WHERE u.usrname = accessing_usr;
    END IF;

    IF from_ip_addr IS NOT NULL THEN
        def_i_rl := openapi.find_ip_addr_endpoint_rate_limit('authenticateUser', from_ip_addr);
    END IF;

    -- Now we test the user-based and IP-based limits in their focused way...
    IF def_u_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO u_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.cred_user ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.authen_attempt_log l
                  WHERE l.cred_user = accessing_usr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    IF def_i_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO i_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.authen_attempt_log l
                  WHERE l.ip_addr = from_ip_addr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    -- If there are no user-specific or IP-based limit
    -- overrides; check endpoint-wide limits for user,
    -- then IP, and if we were passed neither, then limit
    -- endpoint access for all users.  Better to lock it
    -- all down than to set the servers on fire.
    IF COALESCE(u_wait, i_wait) IS NULL AND COALESCE(def_i_rl.id, def_u_rl.id) IS NULL THEN
        IF accessing_usr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.cred_user ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.authen_attempt_log l
                      WHERE l.cred_user = accessing_usr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSIF from_ip_addr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.authen_attempt_log l
                      WHERE l.ip_addr = from_ip_addr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSE -- we have no user and no IP, global auth attempt rate limit?
            SELECT  CEIL(EXTRACT(EPOCH FROM (l.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  openapi.authen_attempt_log l
              WHERE l.attempt_time > NOW() - def_rl.limit_interval
              ORDER BY l.attempt_time DESC
              LIMIT 1 OFFSET def_rl.limit_count;
        END IF;
    END IF;

    -- Send back the largest required wait time, or NULL for no restriction
    u_wait := GREATEST(u_wait,i_wait);
    IF u_wait > 0 THEN
        RETURN u_wait;
    END IF;

    RETURN NULL;
END;
$f$ STABLE LANGUAGE PLPGSQL;

--===================================== Seed data ==================================

-- ===== authentication
INSERT INTO openapi.endpoint (operation_id, path, security, http_method, summary, method_source, method_name, method_params, rate_limit) VALUES
-- Builtin auth-related methods, give all users and IPs 100/s of each
  ('authenticateUser', '/self/auth', 'basicAuth', 'get', 'Authenticate API user', 'OpenILS::OpenAPI::Controller', 'authenticateUser', 'param.u param.p param.t', 8),
  ('logoutUser', '/self/auth', 'bearerAuth', 'delete', 'Logout API user', 'open-ils.auth', 'open-ils.auth.session.delete', 'eg_auth_token', 8)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value) VALUES
  ('authenticateUser','u','query','string',NULL,NULL),
  ('authenticateUser','p','query','string','password',NULL),
  ('authenticateUser','t','query','string',NULL,'api')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('authenticateUser','object') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,content_type) VALUES ('authenticateUser','text/plain') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('logoutUser','object') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,content_type) VALUES ('logoutUser','text/plain') ON CONFLICT DO NOTHING;

-- ===== self-service
-- get/update me
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveSelfProfile', '/self/me', 'get', 'Return patron/user record for logged in user', 'OpenILS::OpenAPI::Controller::patron', 'deliver_user', 'eg_auth_token eg_user_id'),
  ('selfUpdateParts', '/self/me', 'patch', 'Update portions of the logged in user''s record', 'OpenILS::OpenAPI::Controller::patron', 'update_user_parts', 'eg_auth_token req.json')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveSelfProfile','au') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('selfUpdateParts','object') ON CONFLICT DO NOTHING;

-- get my standing penalties
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'selfActivePenalties',
    '/self/standing_penalties',
    'get',
    'Produces patron-visible penalty details for the authorized account',
    'OpenILS::OpenAPI::Controller::patron',
    'standing_penalties',
    'eg_auth_token eg_user_id "1"'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('selfActivePenalties','array','object') ON CONFLICT DO NOTHING; -- array of fleshed ausp

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'selfPenalty',
    '/self/standing_penalty/:penaltyid',
    'get',
    'Retrieve one penalty for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'standing_penalties',
    'eg_auth_token eg_user_id "1" param.penaltyid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('selfPenalty','penaltyid','path','integer',TRUE) ON CONFLICT DO NOTHING;



-- manage my holds
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveSelfHolds', '/self/holds', 'get', 'Return unfilled holds for the authorized account', 'OpenILS::OpenAPI::Controller::hold', 'open_holds', 'eg_auth_token eg_user_id'),
  ('requestSelfHold', '/self/holds', 'post', 'Request a hold for the authorized account', 'OpenILS::OpenAPI::Controller::hold', 'request_hold', 'eg_auth_token eg_user_id req.json'),
  ('retrieveSelfHold', '/self/hold/:hold', 'get', 'Retrieve one hold for the logged in user', 'OpenILS::OpenAPI::Controller::hold', 'fetch_user_hold', 'eg_auth_token eg_user_id param.hold'),
  ('updateSelfHold', '/self/hold/:hold', 'patch', 'Update one hold for the logged in user', 'OpenILS::OpenAPI::Controller::hold', 'update_user_hold', 'eg_auth_token eg_user_id param.hold req.json'),
  ('cancelSelfHold', '/self/hold/:hold', 'delete', 'Cancel one hold for the logged in user', 'OpenILS::OpenAPI::Controller::hold', 'cancel_user_hold', 'eg_auth_token eg_user_id param.hold "6"')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES
  ('retrieveSelfHold','hold','path','integer',TRUE),
  ('updateSelfHold','hold','path','integer',TRUE),
  ('cancelSelfHold','hold','path','integer',TRUE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveSelfHolds','array','object') ON CONFLICT DO NOTHING;


-- general xact list
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveSelfXacts',
    '/self/transactions/:state',
    'get',
    'Produces a list of transactions of the logged in user',
    'OpenILS::OpenAPI::Controller::patron',
    'transactions_by_state',
    'eg_auth_token eg_user_id state param.limit param.offset param.sort param.before param.after'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value,required) VALUES
  ('retrieveSelfXacts','state','path','string',NULL,NULL,TRUE),
  ('retrieveSelfXacts','limit','query','integer',NULL,NULL,FALSE),
  ('retrieveSelfXacts','offset','query','integer',NULL,'0',FALSE),
  ('retrieveSelfXacts','sort','query','string',NULL,'desc',FALSE),
  ('retrieveSelfXacts','before','query','string','date-time',NULL,FALSE),
  ('retrieveSelfXacts','after','query','string','date-time',NULL,FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveSelfXacts','array','object') ON CONFLICT DO NOTHING;

-- general xact detail
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveSelfXact',
    '/self/transaction/:id',
    'get',
    'Details of one transaction for the logged in user',
    'open-ils.actor',
    'open-ils.actor.user.transaction.fleshed.retrieve',
    'eg_auth_token param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveSelfXact','id','path','integer',TRUE) ON CONFLICT DO NOTHING;


INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveSelfCircs', '/self/checkouts', 'get', 'Open Circs for the logged in user', 'open-ils.circ', 'open-ils.circ.actor.user.checked_out.atomic', 'eg_auth_token eg_user_id'),
  ('requestSelfCirc', '/self/checkouts', 'post', 'Attempt a circulation for the logged in user', 'OpenILS::OpenAPI::Controller::patron', 'checkout_item', 'eg_auth_token eg_user_id req.json')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveSelfCircs','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveSelfCircHistory',
    '/self/checkouts/history',
    'get',
    'Historical Circs for logged in user',
    'OpenILS::OpenAPI::Controller::patron',
    'circulation_history',
    'eg_auth_token eg_user_id param.limit param.offset param.sort param.before param.after'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value) VALUES
  ('retrieveSelfCircHistory','limit','query','integer',NULL,NULL),
  ('retrieveSelfCircHistory','offset','query','integer',NULL,'0'),
  ('retrieveSelfCircHistory','sort','query','string',NULL,'desc'),
  ('retrieveSelfCircHistory','before','query','string','date-time',NULL),
  ('retrieveSelfCircHistory','after','query','string','date-time',NULL)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveSelfCircHistory','array','object') ON CONFLICT DO NOTHING;


INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveSelfCirc', '/self/checkout/:id', 'get', 'Retrieve one circulation for the logged in user', 'open-ils.actor', 'open-ils.actor.user.transaction.fleshed.retrieve', 'eg_auth_token param.id'),
  ('renewSelfCirc', '/self/checkout/:id', 'put', 'Renew one circulation for the logged in user', 'OpenILS::OpenAPI::Controller::patron', 'renew_circ', 'eg_auth_token param.id eg_user_id'),
  ('checkinSelfCirc', '/self/checkout/:id', 'delete', 'Check in one circulation for the logged in user', 'OpenILS::OpenAPI::Controller::patron', 'checkin_circ', 'eg_auth_token param.id eg_user_id')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES
  ('retrieveSelfCirc','id','path','integer',TRUE),
  ('renewSelfCirc','id','path','integer',TRUE),
  ('checkinSelfCirc','id','path','integer',TRUE)
ON CONFLICT DO NOTHING;

-- bib, item, and org methods
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveOrgList',
    '/org_units',
    'get',
    'List of org units',
    'OpenILS::OpenAPI::Controller::org',
    'flat_org_list',
    'every_param.field every_param.comparison every_param.value'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES
  ('retrieveOrgList','field','query','string'),
  ('retrieveOrgList','comparison','query','string'),
  ('retrieveOrgList','value','query','string')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveOrgList','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveOneOrg',
    '/org_unit/:id',
    'get',
    'One org unit',
    'OpenILS::OpenAPI::Controller::org',
    'one_org',
    'param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveOneOrg','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveOneOrg','aou') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name) VALUES (
    'retrieveFullOrgTree',
    '/org_tree',
    'get',
    'Full hierarchical tree of org units',
    'OpenILS::OpenAPI::Controller::org',
    'full_tree'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveFullOrgTree','aou') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrievePartialOrgTree',
    '/org_tree/:id',
    'get',
    'Partial hierarchical tree of org units starting from a specific org unit',
    'OpenILS::OpenAPI::Controller::org',
    'one_tree',
    'param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrievePartialOrgTree','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrievePartialOrgTree','aou') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'createOneBib',
    '/bibs',
    'post',
    'Attempts to create a bibliographic record using MARCXML passed as the request content',
    'open-ils.cat',
    'open-ils.cat.biblio.record.xml.create',
    'eg_auth_token req.text param.sourcename'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES ('createOneBib','sourcename','query','string') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('createOneBib','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'updateOneBib',
    '/bib/:id',
    'put',
    'Attempts to update a bibliographic record using MARCXML passed as the request content',
    'open-ils.cat',
    'open-ils.cat.biblio.record.marc.replace',
    'eg_auth_token param.id req.text param.sourcename'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('updateOneBib','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES ('updateOneBib','sourcename','query','string') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('updateOneBib','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'deleteOneBib',
    '/bib/:id',
    'delete',
    'Attempts to delete a bibliographic record',
    'open-ils.cat',
    'open-ils.cat.biblio.record_entry.delete',
    'eg_auth_token param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('deleteOneBib','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,validate) VALUES ('deleteOneBib','integer',FALSE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'updateBREParts',
    '/bib/:id',
    'patch',
    'Attempts to update the biblio.record_entry metadata surrounding a bib record',
    'OpenILS::OpenAPI::Controller::bib',
    'update_bre_parts',
    'eg_auth_token param.id req.json'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('updateBREParts','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('updateBREParts','bre') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveOneBib',
    '/bib/:id',
    'get',
    'Retrieve a bibliographic record, either full biblio::record_entry object, or just the MARCXML',
    'OpenILS::OpenAPI::Controller::bib',
    'fetch_one_bib',
    'param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveOneBib','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveOneBib','bre') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,content_type) VALUES ('retrieveOneBib','application/xml') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,content_type) VALUES ('retrieveOneBib','application/octet-stream') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveOneBibHoldings',
    '/bib/:id/holdings',
    'get',
    'Retrieve the holdings data for a bibliographic record',
    'OpenILS::OpenAPI::Controller::bib',
    'fetch_one_bib_holdings',
    'param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,default_value,required) VALUES
  ('retrieveOneBibHoldings','id','path','integer',NULL,TRUE),
  ('retrieveOneBibHoldings','limit','query','integer',NULL,FALSE),
  ('retrieveOneBibHoldings','offset','query','integer','0',FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveOneBibHoldings','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'bibDisplayFields',
    '/bib/:id/display_fields',
    'get',
    'Retrieve display-related data for a bibliographic record',
    'OpenILS::OpenAPI::Controller::bib',
    'fetch_one_bib_display_fields',
    'param.id req.text'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('bibDisplayFields','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('bibDisplayFields','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'newItems',
    '/items/fresh',
    'get',
    'Retrieve a list of newly added items',
    'OpenILS::OpenAPI::Controller::bib',
    'fetch_new_items',
    'param.limit param.offset param.maxage'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,default_value) VALUES ('newItems','limit','query','integer','0') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,default_value) VALUES ('newItems','offset','query','integer','100') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format) VALUES ('newItems','maxage','query','string','interval') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('newItems','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrieveItem',
    '/item/:barcode',
    'get',
    'Retrieve one item by its barcode',
    'OpenILS::OpenAPI::Controller::bib',
    'item_by_barcode',
    'param.barcode'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveItem','barcode','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,description,status,schema_type) VALUES ('retrieveItem','Item Lookup Failed','404','object') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveItem','acp') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'createItem',
    '/items',
    'post',
    'Create an item record',
    'OpenILS::OpenAPI::Controller::bib',
    'create_or_update_one_item',
    'eg_auth_token req.json'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,description,status) VALUES ('createItem','Item Creation Failed','400') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('createItem','acp') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'updateItem',
    '/item/:barcode',
    'patch',
    'Update a restricted set of item record fields',
    'OpenILS::OpenAPI::Controller::bib',
    'create_or_update_one_item',
    'eg_auth_token req.json param.barcode'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('updateItem','barcode','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,description,status) VALUES ('updateItem','Item Update Failed','400') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('updateItem','acp') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'deleteItem',
    '/item/:barcode',
    'delete',
    'Delete one item record',
    'OpenILS::OpenAPI::Controller::bib',
    'delete_one_item',
    'eg_auth_token param.barcode'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('deleteItem','barcode','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,description,status,schema_type) VALUES ('deleteItem','Item Deletion Failed','404','object') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('deleteItem','boolean') ON CONFLICT DO NOTHING;


-- === patron (non-self) methods
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'searchPatrons',
    '/patrons',
    'get',
    'List of patrons matching requested conditions',
    'OpenILS::OpenAPI::Controller::patron',
    'find_users',
    'eg_auth_token every_param.field every_param.comparison every_param.value param.limit param.offset'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES
  ('searchPatrons','field','query','string'),
  ('searchPatrons','comparison','query','string'),
  ('searchPatrons','value','query','string')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value) VALUES
  ('searchPatrons','offset','query','integer',NULL,'0'),
  ('searchPatrons','limit','query','integer',NULL,'100')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('searchPatrons','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'verifyUserCredentials',
    '/patrons/verify',
    'get',
    'Verify the credentials for a user account',
    'open-ils.actor',
    'open-ils.actor.verify_user_password',
    'eg_auth_token param.barcode param.usrname "" param.password'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,required) VALUES
  ('verifyUserCredentials','barcode','query','string',NULL,FALSE),
  ('verifyUserCredentials','usrname','query','string',NULL,FALSE),
  ('verifyUserCredentials','password','query','string','password',TRUE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('verifyUserCredentials','boolean') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrievePatronProfile', '/patron/:userid', 'get', 'Return patron/user record for the requested user', 'OpenILS::OpenAPI::Controller::patron', 'deliver_user', 'eg_auth_token param.userid')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrievePatronProfile','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrievePatronProfile','au') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
  'patronIdByCardBarcode',
  '/patrons/by_barcode/:barcode/id',
  'get',
  'Retrieve patron id by barcode',
  'open-ils.actor',
  'open-ils.actor.user.retrieve_id_by_barcode_or_username',
  'eg_auth_token param.barcode'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronIdByCardBarcode','barcode','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('patronIdByCardBarcode','integer') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
  'patronIdByUsername',
  '/patrons/by_username/:username/id',
  'get',
  'Retrieve patron id by username',
  'open-ils.actor',
  'open-ils.actor.user.retrieve_id_by_barcode_or_username',
  'eg_auth_token "" param.username'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronIdByUsername','username','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('patronIdByUsername','integer') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
  'patronByCardBarcode',
  '/patrons/by_barcode/:barcode',
  'get',
  'Retrieve patron by barcode',
  'OpenILS::OpenAPI::Controller::patron',
  'user_by_identifier_string',
  'eg_auth_token param.barcode'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronByCardBarcode','barcode','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('patronByCardBarcode','au') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
  'patronByUsername',
  '/patrons/by_username/:username',
  'get',
  'Retrieve patron by username',
  'OpenILS::OpenAPI::Controller::patron',
  'user_by_identifier_string',
  'eg_auth_token "" param.username'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronByUsername','username','path','string',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('patronByUsername','au') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrievePatronCircHistory',
    '/patron/:userid/checkouts/history',
    'get',
    'Historical Circs for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'circulation_history',
    'eg_auth_token param.userid param.limit param.offset param.sort param.before param.after'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value,required) VALUES
  ('retrievePatronCircHistory','userid','path','integer',NULL,NULL,TRUE),
  ('retrievePatronCircHistory','limit','query','integer',NULL,NULL,FALSE),
  ('retrievePatronCircHistory','offset','query','integer',NULL,'0',FALSE),
  ('retrievePatronCircHistory','sort','query','string',NULL,'desc',FALSE),
  ('retrievePatronCircHistory','before','query','string','date-time',NULL,FALSE),
  ('retrievePatronCircHistory','after','query','string','date-time',NULL,FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrievePatronCircHistory','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrievePatronHolds', '/patron/:userid/holds', 'get', 'Retrieve unfilled holds for a patron', 'OpenILS::OpenAPI::Controller::hold', 'open_holds', 'eg_auth_token param.userid'),
  ('requestPatronHold', '/patron/:userid/holds', 'post', 'Request a hold for a patron', 'OpenILS::OpenAPI::Controller::hold', 'request_hold', 'eg_auth_token param.userid req.json'),
  ('retrievePatronHold','/patron/:userid/hold/:hold', 'get', 'Retrieve one hold for a patron', 'OpenILS::OpenAPI::Controller::hold', 'fetch_user_hold', 'eg_auth_token param.userid param.hold'),
  ('updatePatronHold', '/patron/:userid/hold/:hold', 'patch', 'Update one hold for a patron', 'OpenILS::OpenAPI::Controller::hold', 'update_user_hold', 'eg_auth_token param.userid param.hold req.json'),
  ('cancelPatronHold', '/patron/:userid/hold/:hold', 'delete', 'Cancel one hold for a patron', 'OpenILS::OpenAPI::Controller::hold', 'cancel_user_hold', 'eg_auth_token param.userid param.hold "6"')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES
  ('retrievePatronHolds','userid','path','integer',TRUE),
  ('retrievePatronHold','userid','path','integer',TRUE),
  ('retrievePatronHold','hold','path','integer',TRUE),
  ('requestPatronHold','userid','path','integer',TRUE),
  ('updatePatronHold','userid','path','integer',TRUE),
  ('updatePatronHold','hold','path','integer',TRUE),
  ('cancelPatronHold','userid','path','integer',TRUE),
  ('cancelPatronHold','hold','path','integer',TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveHoldPickupLocations', '/holds/pickup_locations', 'get', 'Retrieve all valid hold/reserve pickup locations', 'OpenILS::OpenAPI::Controller::hold', 'valid_hold_pickup_locations', '')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveHoldPickupLocations','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveHold', '/hold/:hold', 'get', 'Retrieve one hold object', 'open-ils.circ', 'open-ils.circ.hold.details.retrieve', 'eg_auth_token param.hold')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveHold','hold','path','integer',TRUE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrievePatronXacts',
    '/patron/:userid/transactions/:state',
    'get',
    'Produces a list of transactions of the specified user',
    'OpenILS::OpenAPI::Controller::patron',
    'transactions_by_state',
    'eg_auth_token param.userid state param.limit param.offset param.sort param.before param.after'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value,required) VALUES
  ('retrievePatronXacts','userid','path','integer',NULL,NULL,TRUE),
  ('retrievePatronXacts','state','path','string',NULL,NULL,TRUE),
  ('retrievePatronXacts','limit','query','integer',NULL,NULL,FALSE),
  ('retrievePatronXacts','offset','query','integer',NULL,'0',FALSE),
  ('retrievePatronXacts','sort','query','string',NULL,'desc',FALSE),
  ('retrievePatronXacts','before','query','string','date-time',NULL,FALSE),
  ('retrievePatronXacts','after','query','string','date-time',NULL,FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrievePatronXacts','array','object') ON CONFLICT DO NOTHING;

-- general xact detail
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'retrievePatronXact',
    '/patron/:userid/transaction/:id',
    'get',
    'Details of one transaction for the specified user',
    'open-ils.actor',
    'open-ils.actor.user.transaction.fleshed.retrieve',
    'eg_auth_token param.id'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrievePatronXact','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrievePatronXact','id','path','integer',TRUE) ON CONFLICT DO NOTHING;


INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrievePatronCircs', '/patron/:userid/checkouts', 'get', 'Open Circs for a patron', 'open-ils.circ', 'open-ils.circ.actor.user.checked_out.atomic', 'eg_auth_token param.userid'),
  ('requestPatronCirc', '/patron/:userid/checkouts', 'post', 'Attempt a circulation for a patron', 'OpenILS::OpenAPI::Controller::patron', 'checkout_item', 'eg_auth_token param.userid req.json')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrievePatronCircs','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('requestPatronCirc','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrievePatronCircs','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrievePatronCirc', '/patron/:userid/checkout/:id', 'get', 'Retrieve one circulation for the specified user', 'open-ils.actor', 'open-ils.actor.user.transaction.fleshed.retrieve', 'eg_auth_token param.id'),
  ('renewPatronCirc', '/patron/:userid/checkout/:id', 'put', 'Renew one circulation for the specified user', 'OpenILS::OpenAPI::Controller::patron', 'renew_circ', 'eg_auth_token param.id param.userid'),
  ('checkinPatronCirc', '/patron/:userid/checkout/:id', 'delete', 'Check in one circulation for the specified user', 'OpenILS::OpenAPI::Controller::patron', 'checkin_circ', 'eg_auth_token param.id param.userid')
ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES
  ('retrievePatronCirc','userid','path','integer',TRUE),
  ('retrievePatronCirc','id','path','integer',TRUE),
  ('renewPatronCirc','userid','path','integer',TRUE),
  ('renewPatronCirc','id','path','integer',TRUE),
  ('checkinPatronCirc','userid','path','integer',TRUE),
  ('checkinPatronCirc','id','path','integer',TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronATEvents',
    '/patron/:userid/triggered_events',
    'get',
    'Retrieve a list of A/T events for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'usr_at_events',
    'eg_auth_token param.userid param.limit param.offset param.before param.after every_param.hook'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value,required) VALUES
  ('patronATEvents','userid','path','integer',NULL,NULL,TRUE),
  ('patronATEvents','limit','query','integer',NULL,'100',FALSE),
  ('patronATEvents','offset','query','integer',NULL,'0',FALSE),
  ('patronATEvents','before','query','string','date-time',NULL,FALSE),
  ('patronATEvents','after','query','string','date-time',NULL,FALSE),
  ('patronATEvents','hook','query','string',NULL,NULL,FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('patronATEvents','array','integer') ON CONFLICT DO NOTHING; -- array of ausp ids

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronATEvent',
    '/patron/:userid/triggered_event/:eventid',
    'get',
    'Retrieve one penalty for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'usr_at_events',
    'eg_auth_token param.userid "1" "0" "" "" "" param.eventid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronATEvent','eventid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronATEvent','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronActivePenalties',
    '/patron/:userid/standing_penalties',
    'get',
    'Retrieve all penalty details for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'standing_penalties',
    'eg_auth_token param.userid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronActivePenalties','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('patronActivePenalties','array','integer') ON CONFLICT DO NOTHING; -- array of ausp ids

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronPenalty',
    '/patron/:userid/standing_penalty/:penaltyid',
    'get',
    'Retrieve one penalty for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'standing_penalties',
    'eg_auth_token param.userid "0" param.penaltyid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronPenalty','penaltyid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronPenalty','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronActiveMessages',
    '/patron/:userid/messages',
    'get',
    'Retrieve all active message ids for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'usr_messages',
    'eg_auth_token param.userid "0"'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronActiveMessages','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('patronActiveMessages','array','integer') ON CONFLICT DO NOTHING; -- array of aum ids

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronMessage',
    '/patron/:userid/message/:msgid',
    'get',
    'Retrieve one message for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'usr_messages',
    'eg_auth_token param.userid "0" param.msgid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessage','msgid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessage','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('patronMessage','aum') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronMessageUpdate',
    '/patron/:userid/message/:msgid',
    'patch',
    'Update one message for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'update_usr_message',
    'eg_auth_token eg_user_id param.userid param.msgid req.json'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessageUpdate','msgid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessageUpdate','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('patronMessageUpdate','aum') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronMessageArchive',
    '/patron/:userid/message/:msgid',
    'delete',
    'Archive one message for a patron',
    'OpenILS::OpenAPI::Controller::patron',
    'archive_usr_message',
    'eg_auth_token eg_user_id param.userid param.msgid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessageArchive','msgid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('patronMessageArchive','userid','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type) VALUES ('patronMessageArchive','boolean') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'patronActivityLog',
    '/patron/:userid/activity',
    'get',
    'Retrieve patron activity (authen, authz, etc)',
    'OpenILS::OpenAPI::Controller::patron',
    'usr_activity',
    'eg_auth_token param.userid param.maxage param.limit param.offset param.sort'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,default_value,required) VALUES
  ('patronActivityLog','userid','path','integer',NULL,NULL,TRUE),
  ('patronActivityLog','limit','query','integer',NULL,'100',FALSE),
  ('patronActivityLog','offset','query','integer',NULL,'0',FALSE),
  ('patronActivityLog','sort','query','string',NULL,'desc',FALSE),
  ('patronActivityLog','maxage','query','string','date-time',NULL,FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('patronActivityLog','array','object') ON CONFLICT DO NOTHING;

------- collections
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'collectionsPatronsOfInterest',
    '/collections/:shortname/users_of_interest',
    'get',
    'List of patrons to consider for collections based on the search criteria provided.',
    'open-ils.collections',
    'open-ils.collections.users_of_interest.retrieve',
    'eg_auth_token param.fine_age param.fine_amount param.shortname'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,required) VALUES
  ('collectionsPatronsOfInterest','shortname','path','string',NULL,TRUE),
  ('collectionsPatronsOfInterest','fine_age','query','integer',NULL,TRUE),
  ('collectionsPatronsOfInterest','fine_amount','query','string','money',TRUE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items,validate) VALUES ('collectionsPatronsOfInterest','array','object',FALSE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'collectionsPatronsOfInterestWarning',
    '/collections/:shortname/users_of_interest/warning',
    'get',
    'List of patrons with the PATRON_EXCEEDS_COLLECTIONS_WARNING penalty to consider for collections based on the search criteria provided.',
    'open-ils.collections',
    'open-ils.collections.users_of_interest.warning_penalty.retrieve',
    'eg_auth_token param.shortname param.min_age param.max_age'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,required) VALUES
  ('collectionsPatronsOfInterestWarning','shortname','path','string',NULL,TRUE),
  ('collectionsPatronsOfInterestWarning','min_age','query','string','date-time',FALSE),
  ('collectionsPatronsOfInterestWarning','max_age','query','string','date-time',FALSE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items,validate) VALUES ('collectionsPatronsOfInterestWarning','array','object',FALSE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'collectionsGetPatronDetail',
    '/patron/:usrid/collections/:shortname',
    'get',
    'Get collections-related transaction details for a patron.',
    'open-ils.collections',
    'open-ils.collections.user_transaction_details.retrieve',
    'eg_auth_token param.start param.end param.shortname every_param.usrid'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,required) VALUES
  ('collectionsGetPatronDetail','usrid','path','integer',NULL,TRUE),
  ('collectionsGetPatronDetail','shortname','path','string',NULL,TRUE),
  ('collectionsGetPatronDetail','start','query','string','date-time',TRUE),
  ('collectionsGetPatronDetail','end','query','string','date-time',TRUE)
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items,validate) VALUES ('collectionsGetPatronDetail','array','object',FALSE) ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'collectionsPutPatronInCollections',
    '/patron/:usrid/collections/:shortname',
    'post',
    'Put patron into collections.',
    'open-ils.collections',
    'open-ils.collections.put_into_collections',
    'eg_auth_token param.usrid param.shortname param.fee param.note'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,schema_format,required) VALUES
  ('collectionsPutPatronInCollections','usrid','path','integer',NULL,TRUE),
  ('collectionsPutPatronInCollections','shortname','path','string',NULL,TRUE),
  ('collectionsPutPatronInCollections','fee','query','string','money',FALSE),
  ('collectionsPutPatronInCollections','note','query','string',NULL,FALSE)
ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES (
    'collectionsRemovePatronFromCollections',
    '/patron/:usrid/collections/:shortname',
    'delete',
    'Remove patron from collections.',
    'open-ils.collections',
    'open-ils.collections.remove_from_collections',
    'eg_auth_token param.usrid param.shortname'
) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES
  ('collectionsRemovePatronFromCollections','usrid','path','integer',TRUE),
  ('collectionsRemovePatronFromCollections','shortname','path','string',TRUE)
ON CONFLICT DO NOTHING;


------- courses
INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('activeCourses', '/courses', 'get', 'Retrieve all courses used for course material reservation', 'OpenILS::OpenAPI::Controller::course', 'get_active_courses', 'eg_auth_token every_param.org')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES ('activeCourses','org','query','integer') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('activeCourses','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('activeRoles', '/courses/public_role_users', 'get', 'Retrieve all public roles used for courses', 'OpenILS::OpenAPI::Controller::course', 'get_all_course_public_roles', 'eg_auth_token every_param.org')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type) VALUES ('activeRoles','org','query','integer') ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('activeRoles','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveCourse', '/course/:id', 'get', 'Retrieve one detailed course', 'OpenILS::OpenAPI::Controller::course', 'get_course_detail', 'eg_auth_token param.id')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveCourse','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,fm_type) VALUES ('retrieveCourse','acmc') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveCourseMaterials', '/course/:id/materials', 'get', 'Retrieve detailed materials for one course', 'OpenILS::OpenAPI::Controller::course', 'get_course_materials', 'param.id')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveCourseMaterials','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveCourseMaterials','array','object') ON CONFLICT DO NOTHING;

INSERT INTO openapi.endpoint (operation_id, path, http_method, summary, method_source, method_name, method_params) VALUES
  ('retrieveCourseUsers', '/course/:id/public_role_users', 'get', 'Retrieve detailed user list for one course', 'open-ils.courses', 'open-ils.courses.course_users.retrieve', 'param.id')
ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_param (endpoint,name,in_part,schema_type,required) VALUES ('retrieveCourseUsers','id','path','integer',TRUE) ON CONFLICT DO NOTHING;
INSERT INTO openapi.endpoint_response (endpoint,schema_type,array_items) VALUES ('retrieveCourseUsers','array','object') ON CONFLICT DO NOTHING;

--------- put likely stock endpoints into sets --------

INSERT INTO openapi.endpoint_set_endpoint_map (endpoint, endpoint_set)
  SELECT e.operation_id, s.name FROM openapi.endpoint e JOIN openapi.endpoint_set s ON (e.path LIKE '/'||RTRIM(s.name,'s')||'%')
ON CONFLICT DO NOTHING;

-- Check that all endpoints are in sets -- should return 0 rows
SELECT * FROM openapi.endpoint e WHERE NOT EXISTS (SELECT 1 FROM openapi.endpoint_set_endpoint_map WHERE endpoint = e.operation_id);

-- Global Fieldmapper property-filtering org and user settings
INSERT INTO config.settings_group (name,label) VALUES ('openapi','OpenAPI data access control');

INSERT INTO config.org_unit_setting_type (name,label,grp) VALUES ('REST.api.blacklist_properties','Globally filtered Fieldmapper properties','openapi');
INSERT INTO config.org_unit_setting_type (name,label,grp) VALUES ('REST.api.whitelist_properties','Globally whitelisted Fieldmapper properties','openapi');

UPDATE config.org_unit_setting_type
    SET update_perm = (SELECT id FROM permission.perm_list WHERE code = 'ADMIN_OPENAPI' LIMIT 1)
    WHERE name IN ('REST.api.blacklist_properties','REST.api.whitelist_properties');

INSERT INTO config.usr_setting_type (name,label,grp) VALUES ('REST.api.whitelist_properties','Globally whitelisted Fieldmapper properties','openapi');
INSERT INTO config.usr_setting_type (name,label,grp) VALUES ('REST.api.blacklist_properties','Globally filtered Fieldmapper properties','openapi');

COMMIT;

/* -- Some extra example permission setup, to allow (basically) readonly patron retrieve

INSERT INTO permission.perm_list (code,description) VALUES ('REST.api.patrons.detail.read','Permission meant to facilitate read-only patron-related API access');
INSERT INTO openapi.perm_set (name) values ('Patron Detail, Readonly');
INSERT INTO openapi.perm_set_perm_map (perm_set,perm) SELECT s.id, p.id FROM openapi.perm_set s, permission.perm_list p WHERE p.code IN ('REST.api', 'REST.api.patrons.detail.read') AND s.name='Patron RO';
INSERT INTO openapi.endpoint_perm_set_map (endpoint,perm_set) SELECT 'retrievePatronProfile', s.id FROM openapi.perm_set s WHERE s.name='Patron RO';

*/
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1469', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES ('eg.circ.in_house.do_inventory_update', 'circ', 'bool',
    oils_i18n_gettext (
        'eg.circ.in_house.do_inventory_update',
        'In-House Use: Update Inventory',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1470', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 688, 'UPDATE_HARD_DUE_DATE', oils_i18n_gettext(688,
     'Allow update hard due dates', 'ppl', 'description')),
 ( 689, 'CREATE_HARD_DUE_DATE', oils_i18n_gettext(689,
     'Allow create hard due dates', 'ppl', 'description')),
 ( 690, 'DELETE_HARD_DUE_DATE', oils_i18n_gettext(690,
     'Allow delete hard due dates', 'ppl', 'description')),
 ( 691, 'UPDATE_HARD_DUE_DATE_VALUE', oils_i18n_gettext(691,
     'Allow update hard due date values', 'ppl', 'description')),
 ( 692, 'CREATE_HARD_DUE_DATE_VALUE', oils_i18n_gettext(692,
     'Allow create hard due date values', 'ppl', 'description')),
 ( 693, 'DELETE_HARD_DUE_DATE_VALUE', oils_i18n_gettext(693,
     'Allow delete hard due date values', 'ppl', 'description'));

INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
	SELECT
		pgt.id, perm.id, aout.depth, TRUE
	FROM
		permission.grp_tree pgt,
		permission.perm_list perm,
		actor.org_unit_type aout
	WHERE
		pgt.name = 'Circulation Administrator' AND
		aout.name = 'System' AND
		perm.code IN (
			'CREATE_HARD_DUE_DATE',
			'DELETE_HARD_DUE_DATE',
			'UPDATE_HARD_DUE_DATE',
			'CREATE_HARD_DUE_DATE_VALUE',
			'DELETE_HARD_DUE_DATE_VALUE',
			'UPDATE_HARD_DUE_DATE_VALUE'
		);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1471', :eg_version);

CREATE OR REPLACE FUNCTION evergreen.oils_xpath_string(text, text, text, anyarray) RETURNS text
AS $F$
    SELECT  ARRAY_TO_STRING(
                oils_xpath(
                    $1 ||
                        CASE WHEN $1 ~ $re$/[^/[]*@[^]]+$$re$ OR $1 ~ $re$\)$$re$ THEN '' ELSE '//text()' END,
                    $2,
                    $4
                ),
                $3
            );
$F$ LANGUAGE SQL IMMUTABLE;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1472', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.config.coded_value_map', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.config.coded_value_map',
        'Grid Config: eg.grid.admin.config.coded_value_map',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1473', :eg_version);

-- Basically the same thing as using cascade update, but the stat_cat_entry isn't a foreign key as it can be freetext
CREATE OR REPLACE FUNCTION actor.stat_cat_entry_usr_map_cascade_update() RETURNS TRIGGER AS $$
BEGIN
    UPDATE actor.stat_cat_entry_usr_map
    SET stat_cat_entry = NEW.value
    WHERE stat_cat_entry = OLD.value
        AND stat_cat = OLD.stat_cat;
        
    RETURN NEW;
END;
$$ LANGUAGE PLPGSQL;


DROP TRIGGER IF EXISTS actor_stat_cat_entry_update_trigger ON actor.stat_cat_entry;
CREATE TRIGGER actor_stat_cat_entry_update_trigger
    BEFORE UPDATE ON actor.stat_cat_entry FOR EACH ROW
    EXECUTE FUNCTION actor.stat_cat_entry_usr_map_cascade_update();


-- Basically the same thing as using cascade delete, but the stat_cat_entry isn't a foreign key as it can be freetext
CREATE OR REPLACE FUNCTION actor.stat_cat_entry_usr_map_cascade_delete() RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM actor.stat_cat_entry_usr_map
    WHERE stat_cat_entry = OLD.value
        AND stat_cat = OLD.stat_cat;

    RETURN NEW;
END;
$$ LANGUAGE PLPGSQL;

DROP TRIGGER IF EXISTS actor_stat_cat_entry_delete_trigger ON actor.stat_cat_entry;
CREATE TRIGGER actor_stat_cat_entry_delete_trigger
    AFTER DELETE ON actor.stat_cat_entry FOR EACH ROW
    EXECUTE FUNCTION actor.stat_cat_entry_usr_map_cascade_delete();


COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1474', :eg_version);

CREATE OR REPLACE FUNCTION vandelay.auto_overlay_org_unit_copies ( import_id BIGINT, merge_profile_id INT, lwm_ratio_value_p NUMERIC ) RETURNS BOOL AS $$
DECLARE
    eg_id           BIGINT;
    match_count     INT;
    rec             vandelay.bib_match%ROWTYPE;
    v_owning_lib    INT;
    scope_org       INT;
    scope_orgs      INT[];
    copy_count      INT := 0;
    max_copy_count  INT := 0;
BEGIN

    PERFORM * FROM vandelay.queued_bib_record WHERE import_time IS NOT NULL AND id = import_id;

    IF FOUND THEN
        -- RAISE NOTICE 'already imported, cannot auto-overlay'
        RETURN FALSE;
    END IF;

    -- Gather all the owning libs for our import items.
    -- These are our initial scope_orgs.
    SELECT ARRAY_AGG(DISTINCT owning_lib) INTO scope_orgs
        FROM vandelay.import_item
        WHERE record = import_id;

    WHILE CARDINALITY(scope_orgs) IS NOT NULL LOOP
        EXIT WHEN CARDINALITY(scope_orgs) = 0;
        FOR scope_org IN SELECT * FROM UNNEST(scope_orgs) LOOP
            -- For each match, get a count of all copies at descendants of our scope org.
            FOR rec IN SELECT * FROM vandelay.bib_match AS vbm
                WHERE queued_record = import_id
                ORDER BY vbm.eg_record DESC
            LOOP
                SELECT COUNT(acp.id) INTO copy_count
                    FROM asset.copy AS acp
                    INNER JOIN asset.call_number AS acn
                        ON acp.call_number = acn.id
                    WHERE acn.owning_lib IN (SELECT id FROM
                        actor.org_unit_descendants(scope_org))
                    AND acn.record = rec.eg_record
                    AND acp.deleted = FALSE;
                IF copy_count > max_copy_count THEN
                    max_copy_count := copy_count;
                    eg_id := rec.eg_record;
                END IF;
            END LOOP;
        END LOOP;

        EXIT WHEN eg_id IS NOT NULL;

        -- If no matching bibs had holdings, gather our next set of orgs to check, and iterate.
        IF max_copy_count = 0 THEN 
            SELECT ARRAY_AGG(DISTINCT parent_ou) INTO scope_orgs
                FROM actor.org_unit
                WHERE id IN (SELECT * FROM UNNEST(scope_orgs))
                AND parent_ou IS NOT NULL;
            EXIT WHEN CARDINALITY(scope_orgs) IS NULL;
        END IF;
    END LOOP;

    IF eg_id IS NULL THEN
        -- Could not determine best match via copy count
        -- fall back to default best match
        IF (SELECT * FROM vandelay.auto_overlay_bib_record_with_best( import_id, merge_profile_id, lwm_ratio_value_p )) THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END IF;

    RETURN vandelay.overlay_bib_record( import_id, eg_id, merge_profile_id );
END;
$$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1475', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.config.standing_penalty', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.config.standing_penalty',
        'Grid Config: admin.local.config.standing_penalty',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1476', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, label, description, datatype, fm_class)
VALUES (
    'eg.circ.patron.search.ou',
    'circ',
    oils_i18n_gettext(
        'eg.circ.patron.search.ou',
        'Staff Client patron search: home organization unit',
        'cwst', 'label'),
    oils_i18n_gettext(
        'eg.circ.patron.search.ou',
        'Specifies the home organization unit for patron search',
        'cwst', 'description'),
    'link',
    'aou'
    );

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1477', :eg_version);

ALTER TABLE config.hold_matrix_matchpoint ADD COLUMN copy_location INT REFERENCES asset.copy_location (id) DEFERRABLE INITIALLY DEFERRED;

DROP INDEX IF EXISTS config.chmm_once_per_paramset;

CREATE UNIQUE INDEX chmm_once_per_paramset ON config.hold_matrix_matchpoint (COALESCE(user_home_ou::TEXT, ''), COALESCE(request_ou::TEXT, ''), COALESCE(pickup_ou::TEXT, ''), COALESCE(item_owning_ou::TEXT, ''), COALESCE(item_circ_ou::TEXT, ''), COALESCE(usr_grp::TEXT, ''), COALESCE(requestor_grp::TEXT, ''), COALESCE(circ_modifier, ''), COALESCE(copy_location::TEXT, ''), COALESCE(marc_type, ''), COALESCE(marc_form, ''), COALESCE(marc_bib_level, ''), COALESCE(marc_vr_format, ''), COALESCE(juvenile_flag::TEXT, ''), COALESCE(ref_flag::TEXT, ''), COALESCE(item_age, '0 seconds')) WHERE active;

CREATE OR REPLACE FUNCTION action.find_hold_matrix_matchpoint(pickup_ou integer, request_ou integer, match_item bigint, match_user integer, match_requestor integer)
  RETURNS integer AS
$func$
DECLARE
    requestor_object    actor.usr%ROWTYPE;
    user_object         actor.usr%ROWTYPE;
    item_object         asset.copy%ROWTYPE;
    item_cn_object      asset.call_number%ROWTYPE;
    my_item_age         INTERVAL;
    rec_descriptor      metabib.rec_descriptor%ROWTYPE;
    matchpoint          config.hold_matrix_matchpoint%ROWTYPE;
    weights             config.hold_matrix_weights%ROWTYPE;
    denominator         NUMERIC(6,2);
    v_pickup_ou         ALIAS FOR pickup_ou;
    v_request_ou         ALIAS FOR request_ou;
BEGIN
    SELECT INTO user_object         * FROM actor.usr                WHERE id = match_user;
    SELECT INTO requestor_object    * FROM actor.usr                WHERE id = match_requestor;
    SELECT INTO item_object         * FROM asset.copy               WHERE id = match_item;
    SELECT INTO item_cn_object      * FROM asset.call_number        WHERE id = item_object.call_number;
    SELECT INTO rec_descriptor      * FROM metabib.rec_descriptor   WHERE record = item_cn_object.record;

    SELECT INTO my_item_age age(coalesce(item_object.active_date, now()));

    -- The item's owner should probably be the one determining if the item is holdable
    -- How to decide that is debatable. Decided to default to the circ library (where the item lives)
    -- This flag will allow for setting it to the owning library (where the call number "lives")
    PERFORM * FROM config.internal_flag WHERE name = 'circ.holds.weight_owner_not_circ' AND enabled;

    -- Grab the closest set circ weight setting.
    IF NOT FOUND THEN
        -- Default to circ library
        SELECT INTO weights hw.*
          FROM config.weight_assoc wa
               JOIN config.hold_matrix_weights hw ON (hw.id = wa.hold_weights)
               JOIN actor.org_unit_ancestors_distance( item_object.circ_lib ) d ON (wa.org_unit = d.id)
          WHERE active
          ORDER BY d.distance
          LIMIT 1;
    ELSE
        -- Flag is set, use owning library
        SELECT INTO weights hw.*
          FROM config.weight_assoc wa
               JOIN config.hold_matrix_weights hw ON (hw.id = wa.hold_weights)
               JOIN actor.org_unit_ancestors_distance( item_cn_object.owning_lib ) d ON (wa.org_unit = d.id)
          WHERE active
          ORDER BY d.distance
          LIMIT 1;
    END IF;

    -- No weights? Bad admin! Defaults to handle that anyway.
    IF weights.id IS NULL THEN
        weights.user_home_ou    := 5.0;
        weights.request_ou      := 5.0;
        weights.pickup_ou       := 5.0;
        weights.item_owning_ou  := 5.0;
        weights.item_circ_ou    := 5.0;
        weights.usr_grp         := 7.0;
        weights.requestor_grp   := 8.0;
        weights.circ_modifier   := 4.0;
        weights.copy_location   := 4.0;
        weights.marc_type       := 3.0;
        weights.marc_form       := 2.0;
        weights.marc_bib_level  := 1.0;
        weights.marc_vr_format  := 1.0;
        weights.juvenile_flag   := 4.0;
        weights.ref_flag        := 0.0;
        weights.item_age        := 0.0;
    END IF;

    -- Determine the max (expected) depth (+1) of the org tree and max depth of the permisson tree
    -- If you break your org tree with funky parenting this may be wrong
    -- Note: This CTE is duplicated in the find_circ_matrix_matchpoint function, and it may be a good idea to split it off to a function
    -- We use one denominator for all tree-based checks for when permission groups and org units have the same weighting
    WITH all_distance(distance) AS (
            SELECT depth AS distance FROM actor.org_unit_type
        UNION
            SELECT distance AS distance FROM permission.grp_ancestors_distance((SELECT id FROM permission.grp_tree WHERE parent IS NULL))
	)
    SELECT INTO denominator MAX(distance) + 1 FROM all_distance;

    -- To ATTEMPT to make this work like it used to, make it reverse the user/requestor profile ids.
    -- This may be better implemented as part of the upgrade script?
    -- Set usr_grp = requestor_grp, requestor_grp = 1 or something when this flag is already set
    -- Then remove this flag, of course.
    PERFORM * FROM config.internal_flag WHERE name = 'circ.holds.usr_not_requestor' AND enabled;

    IF FOUND THEN
        -- Note: This, to me, is REALLY hacky. I put it in anyway.
        -- If you can't tell, this is a single call swap on two variables.
        SELECT INTO user_object.profile, requestor_object.profile
                    requestor_object.profile, user_object.profile;
    END IF;

    -- Select the winning matchpoint into the matchpoint variable for returning
    SELECT INTO matchpoint m.*
      FROM  config.hold_matrix_matchpoint m
            /*LEFT*/ JOIN permission.grp_ancestors_distance( requestor_object.profile ) rpgad ON m.requestor_grp = rpgad.id
            LEFT JOIN permission.grp_ancestors_distance( user_object.profile ) upgad ON m.usr_grp = upgad.id
            LEFT JOIN actor.org_unit_ancestors_distance( v_pickup_ou ) puoua ON m.pickup_ou = puoua.id
            LEFT JOIN actor.org_unit_ancestors_distance( v_request_ou ) rqoua ON m.request_ou = rqoua.id
            LEFT JOIN actor.org_unit_ancestors_distance( item_cn_object.owning_lib ) cnoua ON m.item_owning_ou = cnoua.id
            LEFT JOIN actor.org_unit_ancestors_distance( item_object.circ_lib ) iooua ON m.item_circ_ou = iooua.id
            LEFT JOIN actor.org_unit_ancestors_distance( user_object.home_ou  ) uhoua ON m.user_home_ou = uhoua.id
      WHERE m.active
            -- Permission Groups
         -- AND (m.requestor_grp        IS NULL OR upgad.id IS NOT NULL) -- Optional Requestor Group?
            AND (m.usr_grp              IS NULL OR upgad.id IS NOT NULL)
            -- Org Units
            AND (m.pickup_ou            IS NULL OR (puoua.id IS NOT NULL AND (puoua.distance = 0 OR NOT m.strict_ou_match)))
            AND (m.request_ou           IS NULL OR (rqoua.id IS NOT NULL AND (rqoua.distance = 0 OR NOT m.strict_ou_match)))
            AND (m.item_owning_ou       IS NULL OR (cnoua.id IS NOT NULL AND (cnoua.distance = 0 OR NOT m.strict_ou_match)))
            AND (m.item_circ_ou         IS NULL OR (iooua.id IS NOT NULL AND (iooua.distance = 0 OR NOT m.strict_ou_match)))
            AND (m.user_home_ou         IS NULL OR (uhoua.id IS NOT NULL AND (uhoua.distance = 0 OR NOT m.strict_ou_match)))
            -- Static User Checks
            AND (m.juvenile_flag        IS NULL OR m.juvenile_flag = user_object.juvenile)
            -- Static Item Checks
            AND (m.circ_modifier        IS NULL OR m.circ_modifier = item_object.circ_modifier)
            AND (m.copy_location        IS NULL OR m.copy_location = item_object.location)
            AND (m.marc_type            IS NULL OR m.marc_type = COALESCE(item_object.circ_as_type, rec_descriptor.item_type))
            AND (m.marc_form            IS NULL OR m.marc_form = rec_descriptor.item_form)
            AND (m.marc_bib_level       IS NULL OR m.marc_bib_level = rec_descriptor.bib_level)
            AND (m.marc_vr_format       IS NULL OR m.marc_vr_format = rec_descriptor.vr_format)
            AND (m.ref_flag             IS NULL OR m.ref_flag = item_object.ref)
            AND (m.item_age             IS NULL OR (my_item_age IS NOT NULL AND m.item_age > my_item_age))
      ORDER BY
            -- Permission Groups
            CASE WHEN rpgad.distance    IS NOT NULL THEN 2^(2*weights.requestor_grp - (rpgad.distance/denominator)) ELSE 0.0 END +
            CASE WHEN upgad.distance    IS NOT NULL THEN 2^(2*weights.usr_grp - (upgad.distance/denominator)) ELSE 0.0 END +
            -- Org Units
            CASE WHEN puoua.distance    IS NOT NULL THEN 2^(2*weights.pickup_ou - (puoua.distance/denominator)) ELSE 0.0 END +
            CASE WHEN rqoua.distance    IS NOT NULL THEN 2^(2*weights.request_ou - (rqoua.distance/denominator)) ELSE 0.0 END +
            CASE WHEN cnoua.distance    IS NOT NULL THEN 2^(2*weights.item_owning_ou - (cnoua.distance/denominator)) ELSE 0.0 END +
            CASE WHEN iooua.distance    IS NOT NULL THEN 2^(2*weights.item_circ_ou - (iooua.distance/denominator)) ELSE 0.0 END +
            CASE WHEN uhoua.distance    IS NOT NULL THEN 2^(2*weights.user_home_ou - (uhoua.distance/denominator)) ELSE 0.0 END +
            -- Static User Checks       -- Note: 4^x is equiv to 2^(2*x)
            CASE WHEN m.juvenile_flag   IS NOT NULL THEN 4^weights.juvenile_flag ELSE 0.0 END +
            -- Static Item Checks
            CASE WHEN m.circ_modifier   IS NOT NULL THEN 4^weights.circ_modifier ELSE 0.0 END +
            CASE WHEN m.copy_location   IS NOT NULL THEN 4^weights.copy_location ELSE 0.0 END +
            CASE WHEN m.marc_type       IS NOT NULL THEN 4^weights.marc_type ELSE 0.0 END +
            CASE WHEN m.marc_form       IS NOT NULL THEN 4^weights.marc_form ELSE 0.0 END +
            CASE WHEN m.marc_vr_format  IS NOT NULL THEN 4^weights.marc_vr_format ELSE 0.0 END +
            CASE WHEN m.ref_flag        IS NOT NULL THEN 4^weights.ref_flag ELSE 0.0 END +
            -- Item age has a slight adjustment to weight based on value.
            -- This should ensure that a shorter age limit comes first when all else is equal.
            -- NOTE: This assumes that intervals will normally be in days.
            CASE WHEN m.item_age            IS NOT NULL THEN 4^weights.item_age - 86400/EXTRACT(EPOCH FROM m.item_age) ELSE 0.0 END DESC,
            -- Final sort on id, so that if two rules have the same sorting in the previous sort they have a defined order
            -- This prevents "we changed the table order by updating a rule, and we started getting different results"
            m.id;

    -- Return just the ID for now
    RETURN matchpoint.id;
END;
$func$ LANGUAGE 'plpgsql';

ALTER TABLE config.hold_matrix_weights ADD COLUMN copy_location NUMERIC(6,2);
-- we need to set some values, so initially, match whatever the weight for circ_modifier is
UPDATE config.hold_matrix_weights SET copy_location = circ_modifier;
ALTER TABLE config.hold_matrix_weights ALTER COLUMN copy_location SET NOT NULL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1478', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.server.actor.org_unit_proximity_adjustment', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.server.actor.org_unit_proximity_adjustment',
        'Grid Config: eg.grid.admin.server.actor.org_unit_proximity_adjustment',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1479', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.acq.edi_attr_set', 'gui', 'object', 
    oils_i18n_gettext(
        'eg.grid.admin.acq.edi_attr_set',
        'EDI Attribute Sets Grid Settings',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1480', :eg_version);

CREATE OR REPLACE FUNCTION vandelay.add_field ( target_xml TEXT, source_xml TEXT, field TEXT, force_add INT ) RETURNS TEXT AS $_$

    use MARC::Record;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;
    use strict;

    MARC::Charset->assume_unicode(1);

    my $target_xml = shift;
    my $source_xml = shift;
    my $field_spec = shift;
    my $force_add = shift || 0;

    my $target_r = MARC::Record->new_from_xml( $target_xml );
    my $source_r = MARC::Record->new_from_xml( $source_xml );

    return $target_xml unless ($target_r && $source_r);

    my @field_list = split(',', $field_spec);

    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                }
            }
        }
    }

    for my $f ( keys %fields) {
        if ( @{$fields{$f}{sf}} ) {
            for my $from_field ($source_r->field( $f )) {
                my @tos = $target_r->field( $f );
                if (!@tos) {
                    next if (exists($fields{$f}{match}) and !$force_add);
                    my @new_fields = map { $_->clone } $source_r->field( $f );
                    $target_r->insert_fields_ordered( @new_fields );
                } else {
                    for my $to_field (@tos) {
                        if (exists($fields{$f}{match})) {
                            my @match_list;
                            for my $match_key_sf_code ( keys %{$fields{$f}{match}} ) {
                                # We loop here because there might be multiple SFs, such as multiple
                                # $0s in an authority controlled datafield, where one has the EG-special
                                # format, and others are links to external heading data.
                                for my $sf_content ($to_field->subfield($match_key_sf_code)) {
                                    if ($sf_content =~ $fields{$f}{match}{$match_key_sf_code}) {
                                        push @match_list, $sf_content;
                                    }
                                }
                            }
                            next unless (scalar(@match_list) >= scalar(keys %{$fields{$f}{match}}));
                        }
                        for my $old_sf ($from_field->subfields) {
                            $to_field->add_subfields( @$old_sf ) if grep(/$$old_sf[0]/,@{$fields{$f}{sf}});
                        }
                    }
                }
            }
        } else {
            my @new_fields = map { $_->clone } $source_r->field( $f );
            $target_r->insert_fields_ordered( @new_fields );
        }
    }

    $target_xml = $target_r->as_xml_record;
    $target_xml =~ s/^<\?.+?\?>$//mo;
    $target_xml =~ s/\n//sgo;
    $target_xml =~ s/>\s+</></sgo;

    return $target_xml;

$_$ LANGUAGE PLPERLU;

CREATE OR REPLACE FUNCTION vandelay.strip_field(xml text, field text) RETURNS text AS $f$

    use MARC::Record;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;
    use strict;

    MARC::Charset->assume_unicode(1);

    my $xml = shift;
    my $r = MARC::Record->new_from_xml( $xml );

    return $xml unless ($r);

    my $field_spec = shift;
    my @field_list = split(',', $field_spec);

    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                }
            }
        }
    }

    for my $f ( keys %fields) {
        for my $to_field ($r->field( $f )) {
            if (exists($fields{$f}{match})) {
                my @match_list;
                for my $match_key_sf_code ( keys %{$fields{$f}{match}} ) {
                    # We loop here because there might be multiple SFs, such as multiple
                    # $0s in an authority controlled datafield, where one has the EG-special
                    # format, and others are links to external heading data.
                    for my $sf_content ($to_field->subfield($match_key_sf_code)) {
                        if ($sf_content =~ $fields{$f}{match}{$match_key_sf_code}) {
                            push @match_list, $sf_content;
                        }
                    }
                }
                next unless (scalar(@match_list) >= scalar(keys %{$fields{$f}{match}}));
            }

            if ( @{$fields{$f}{sf}} ) {
                $to_field->delete_subfield(code => $fields{$f}{sf});
            } else {
                $r->delete_field( $to_field );
            }
        }
    }

    $xml = $r->as_xml_record;
    $xml =~ s/^<\?.+?\?>$//mo;
    $xml =~ s/\n//sgo;
    $xml =~ s/>\s+</></sgo;

    return $xml;

$f$ LANGUAGE plperlu;

CREATE OR REPLACE FUNCTION vandelay.replace_field 
    (target_xml TEXT, source_xml TEXT, field TEXT) RETURNS TEXT AS $_$

    use strict;
    use MARC::Record;
    use MARC::Field;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;

    MARC::Charset->assume_unicode(1);

    my $target_xml = shift;
    my $source_xml = shift;
    my $field_spec = shift;

    my $target_r = MARC::Record->new_from_xml($target_xml);
    my $source_r = MARC::Record->new_from_xml($source_xml);

    return $target_xml unless $target_r && $source_r;

    # Extract the field_spec components into MARC tags, subfields, 
    # and regex matches.  Copied wholesale from vandelay.strip_field()

    my @field_list = split(',', $field_spec);
    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                 }
            }
        }
    }

    # Returns a flat list of subfield (code, value, code, value, ...)
    # suitable for adding to a MARC::Field.
    sub generate_replacement_subfields {
        my ($source_field, $target_field, @controlled_subfields) = @_;

        # Performing a wholesale field replacment.  
        # Use the entire source field as-is.
        return map {$_->[0], $_->[1]} $source_field->subfields
            unless @controlled_subfields;

        my @new_subfields;

        # Iterate over all target field subfields:
        # 1. Keep uncontrolled subfields as is.
        # 2. Replace values for controlled subfields when a
        #    replacement value exists on the source record.
        # 3. Delete values for controlled subfields when no 
        #    replacement value exists on the source record.

        for my $target_sf ($target_field->subfields) {
            my $subfield = $target_sf->[0];
            my $target_val = $target_sf->[1];

            if (grep {$_ eq $subfield} @controlled_subfields) {
                if (my $source_val = $source_field->subfield($subfield)) {
                    # We have a replacement value
                    push(@new_subfields, $subfield, $source_val);
                } else {
                    # no replacement value for controlled subfield, drop it.
                }
            } else {
                # Field is not controlled.  Copy it over as-is.
                push(@new_subfields, $subfield, $target_val);
            }
        }

        # Iterate over all subfields in the source field and back-fill
        # any values that exist only in the source field.  Insert these
        # subfields in the same relative position they exist in the
        # source field.
                
        my @seen_subfields;
        for my $source_sf ($source_field->subfields) {
            my $subfield = $source_sf->[0];
            my $source_val = $source_sf->[1];
            push(@seen_subfields, $subfield);

            # target field already contains this subfield, 
            # so it would have been addressed above.
            next if $target_field->subfield($subfield);

            # Ignore uncontrolled subfields.
            next unless grep {$_ eq $subfield} @controlled_subfields;

            # Adding a new subfield.  Find its relative position and add
            # it to the list under construction.  Work backwards from
            # the list of already seen subfields to find the best slot.

            my $done = 0;
            for my $seen_sf (reverse(@seen_subfields)) {
                my $idx = @new_subfields;
                for my $new_sf (reverse(@new_subfields)) {
                    $idx--;
                    next if $idx % 2 == 1; # sf codes are in the even slots

                    if ($new_subfields[$idx] eq $seen_sf) {
                        splice(@new_subfields, $idx + 2, 0, $subfield, $source_val);
                        $done = 1;
                        last;
                    }
                }
                last if $done;
            }

            # if no slot was found, add to the end of the list.
            push(@new_subfields, $subfield, $source_val) unless $done;
        }

        return @new_subfields;
    }

    # MARC tag loop
    for my $f (keys %fields) {
        my $tag_idx = -1;
        my @target_fields = $target_r->field($f);

        if (!@target_fields and !defined($fields{$f}{match})) {
            # we will just add the source fields
            # unless they require a target match.
            my @add_these = map { $_->clone } $source_r->field($f);
            $target_r->insert_fields_ordered( @add_these );
        }

        for my $target_field (@target_fields) { # This will not run when the above "if" does.

            # field spec contains a regex for this field.  Confirm field on 
            # target record matches the specified regex before replacing.
            if (exists($fields{$f}{match})) {
                my @match_list;
                for my $match_key_sf_code ( keys %{$fields{$f}{match}} ) {
                    # We loop here because there might be multiple SFs, such as multiple
                    # $0s in an authority controlled datafield, where one has the EG-special
                    # format, and others are links to external heading data.
                    for my $sf_content ($target_field->subfield($match_key_sf_code)) {
                        if ($sf_content =~ $fields{$f}{match}{$match_key_sf_code}) {
                            push @match_list, $sf_content;
                        }
                    }
                }
                next unless (scalar(@match_list) >= scalar(keys %{$fields{$f}{match}}));
            }

            my @new_subfields;
            my @controlled_subfields = @{$fields{$f}{sf}};

            # If the target record has multiple matching bib fields,
            # replace them from matching fields on the source record
            # in a predictable order to avoid replacing with them with
            # same source field repeatedly.
            my @source_fields = $source_r->field($f);
            my $source_field = $source_fields[++$tag_idx];

            if (!$source_field && @controlled_subfields) {
                # When there are more target fields than source fields
                # and we are replacing values for subfields and not
                # performing wholesale field replacment, use the last
                # available source field as the input for all remaining
                # target fields.
                $source_field = $source_fields[$#source_fields];
            }

            if (!$source_field) {
                # No source field exists.  Delete all affected target
                # data.  This is a little bit counterintuitive, but is
                # backwards compatible with the previous version of this
                # function which first deleted all affected data, then
                # replaced values where possible.
                if (@controlled_subfields) {
                    $target_field->delete_subfield($_) for @controlled_subfields;
                } else {
                    $target_r->delete_field($target_field);
                }
                next;
            }

            my @new_subfields = generate_replacement_subfields(
                $source_field, $target_field, @controlled_subfields);

            # Build the replacement field from scratch.  
            my $replacement_field = MARC::Field->new(
                $target_field->tag,
                $target_field->indicator(1),
                $target_field->indicator(2),
                @new_subfields
            );

            $target_field->replace_with($replacement_field);
        }
    }

    $target_xml = $target_r->as_xml_record;
    $target_xml =~ s/^<\?.+?\?>$//mo;
    $target_xml =~ s/\n//sgo;
    $target_xml =~ s/>\s+</></sgo;

    return $target_xml;

$_$ LANGUAGE PLPERLU;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1481', :eg_version);


INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.config.search_filter_group', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.config.search_filter_group',
        'Grid Config: admin.local.config.search_filter_group',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1482', :eg_version);


INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.config.survey', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.config.survey',
        'Grid Config: admin.local.config.survey',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1483', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.config.copy_alert_type', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.config.copy_alert_type',
        'Grid Config: eg.grid.admin.local.config.copy_alert_type',
        'cwst', 'label'
    )
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1484', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.cat.vandelay.queue.bib.record_matches', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.vandelay.queue.bib.record_matches',
        'Grid Config: cat.vandelay.queue.bib.record_matches',
        'cwst', 'label'
    )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1485', :eg_version);

UPDATE config.org_unit_setting_type 
        SET description = oils_i18n_gettext(
            'auth.opac_timeout',
            'Number of seconds of inactivity before the patron is logged out of the OPAC. The minimum value that can be entered is 240 seconds. At the 180 second mark a countdown will appear and patrons can choose to end the session, continue the session, or allow it to time out.',
            'cwst', 'description') 
        WHERE name = 'auth.opac_timeout';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1486', :eg_version);

ALTER TABLE action.hold_request_reset_reason_entry DROP CONSTRAINT hold_request_reset_reason_entry_previous_copy_fkey;

CREATE TRIGGER action_hold_request_reset_reason_entry_previous_copy_trig
    AFTER INSERT OR UPDATE ON action.hold_request_reset_reason_entry
    FOR EACH ROW EXECUTE FUNCTION fake_fkey_tgr('previous_copy');

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1487', :eg_version);

ALTER TABLE actor.usr ALTER COLUMN passwd DROP NOT NULL;
ALTER TABLE IF EXISTS auditor.actor_usr_history ALTER COLUMN passwd DROP NOT NULL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1488', :eg_version);

INSERT INTO config.org_unit_setting_type (
name, grp, label, description, datatype
) VALUES (
  'ui.hide_clear_these_holds_button',
  'gui',
  oils_i18n_gettext(
    'ui.hide_clear_these_holds_button',
    'Hide the Clear These Holds button',
    'coust',
    'label'
  ),
  oils_i18n_gettext(
    'ui.hide_clear_these_holds_button',
    'Hide the Clear These Holds button from the Holds Shelf interface.',
    'coust',
    'description'
  ),
  'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1489', :eg_version);

UPDATE config.xml_transform SET xslt=$$<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet xmlns="http://www.loc.gov/mods/v3" xmlns:marc="http://www.loc.gov/MARC21/slim" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" exclude-result-prefixes="xlink marc" version="1.0">
	<xsl:output encoding="UTF-8" indent="yes" method="xml"/>
<!--
Revision 1.14 - Fixed template isValid and fields 010, 020, 022, 024, 028, and 037 to output additional identifier elements 
  with corresponding @type and @invalid eq 'yes' when subfields z or y (in the case of 022) exist in the MARCXML ::: 2007/01/04 17:35:20 cred

Revision 1.13 - Changed order of output under cartographics to reflect schema  2006/11/28 tmee
	
Revision 1.12 - Updated to reflect MODS 3.2 Mapping  2006/10/11 tmee
		
Revision 1.11 - The attribute objectPart moved from <languageTerm> to <language>
      2006/04/08  jrad

Revision 1.10 MODS 3.1 revisions to language and classification elements  
				(plus ability to find marc:collection embedded in wrapper elements such as SRU zs: wrappers)
				2006/02/06  ggar

Revision 1.9 subfield $y was added to field 242 2004/09/02 10:57 jrad

Revision 1.8 Subject chopPunctuation expanded and attribute fixes 2004/08/12 jrad

Revision 1.7 2004/03/25 08:29 jrad

Revision 1.6 various validation fixes 2004/02/20 ntra

Revision 1.5  2003/10/02 16:18:58  ntra
MODS2 to MODS3 updates, language unstacking and 
de-duping, chopPunctuation expanded

Revision 1.3  2003/04/03 00:07:19  ntra
Revision 1.3 Additional Changes not related to MODS Version 2.0 by ntra

Revision 1.2  2003/03/24 19:37:42  ckeith
Added Log Comment

-->
	<xsl:template match="/">
		<xsl:choose>
			<xsl:when test="//marc:collection">
				<modsCollection xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.loc.gov/mods/v3 http://www.loc.gov/standards/mods/v3/mods-3-2.xsd">
					<xsl:for-each select="//marc:collection/marc:record">
						<mods version="3.2">
							<xsl:call-template name="marcRecord"/>
						</mods>
					</xsl:for-each>
				</modsCollection>
			</xsl:when>
			<xsl:otherwise>
				<mods xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="3.2" xsi:schemaLocation="http://www.loc.gov/mods/v3 http://www.loc.gov/standards/mods/v3/mods-3-2.xsd">
					<xsl:for-each select="//marc:record">
						<xsl:call-template name="marcRecord"/>
					</xsl:for-each>
				</mods>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	<xsl:template name="marcRecord">
		<xsl:variable name="leader" select="marc:leader"/>
		<xsl:variable name="leader6" select="substring($leader,7,1)"/>
		<xsl:variable name="leader7" select="substring($leader,8,1)"/>
		<xsl:variable name="controlField008" select="marc:controlfield[@tag='008']"/>
		<xsl:variable name="typeOf008">
			<xsl:choose>
				<xsl:when test="$leader6='a'">
					<xsl:choose>
						<xsl:when test="$leader7='a' or $leader7='c' or $leader7='d' or $leader7='m'">BK</xsl:when>
						<xsl:when test="$leader7='b' or $leader7='i' or $leader7='s'">SE</xsl:when>
					</xsl:choose>
				</xsl:when>
				<xsl:when test="$leader6='t'">BK</xsl:when>
				<xsl:when test="$leader6='p'">MM</xsl:when>
				<xsl:when test="$leader6='m'">CF</xsl:when>
				<xsl:when test="$leader6='e' or $leader6='f'">MP</xsl:when>
				<xsl:when test="$leader6='g' or $leader6='k' or $leader6='o' or $leader6='r'">VM</xsl:when>
				<xsl:when test="$leader6='c' or $leader6='d' or $leader6='i' or $leader6='j'">MU</xsl:when>
			</xsl:choose>
		</xsl:variable>
		<xsl:for-each select="marc:datafield[@tag='245']">
			<titleInfo>
				<xsl:variable name="title">
					<xsl:choose>
						<xsl:when test="marc:subfield[@code='b']">
							<xsl:call-template name="specialSubfieldSelect">
								<xsl:with-param name="axis">b</xsl:with-param>
								<xsl:with-param name="beforeCodes">afgk</xsl:with-param>
							</xsl:call-template>
						</xsl:when>
						<xsl:otherwise>
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">abfgk</xsl:with-param>
							</xsl:call-template>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:variable>
				<xsl:variable name="titleChop">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="$title"/>
						</xsl:with-param>
                        <xsl:with-param name="punctuation">
                          <xsl:text>,;/ </xsl:text>
                        </xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<xsl:choose>
					<xsl:when test="@ind2>0">
						<nonSort>
							<xsl:value-of select="substring($titleChop,1,@ind2)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleChop,@ind2+1)"/>
						</title>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleChop"/>
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:if test="marc:subfield[@code='b']">
					<subTitle>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="axis">b</xsl:with-param>
									<xsl:with-param name="anyCodes">b</xsl:with-param>
									<xsl:with-param name="afterCodes">afgk</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</subTitle>
				</xsl:if>
				<xsl:call-template name="part"></xsl:call-template>
			</titleInfo>
			<!-- A form of title that ignores non-filing characters; useful
				 for not converting "L'Oreal" into "L' Oreal" at index time -->
			<titleNonfiling>
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">abfgknp</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</title>
			</titleNonfiling>
			<!-- hybrid of titleInfo and titleNonfiling which will give us a preformatted string (for punctuation)
				 but also keep the nonSort stuff in a separate field (for sorting) -->
			<titleBrowse>
				<xsl:variable name="titleBrowseChop">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">abfgk</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<xsl:choose>
					<xsl:when test="@ind2>0">
						<nonSort>
							<xsl:value-of select="substring($titleBrowseChop,1,@ind2)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleBrowseChop,@ind2+1)"/>
						</title>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleBrowseChop"/>
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:call-template name="part"></xsl:call-template>
			</titleBrowse>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='210']">
			<titleInfo type="abbreviated">
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">a</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</title>
				<xsl:call-template name="subtitle"/>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='242']">
			<xsl:variable name="titleChop">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<!-- 1/04 removed $h, b -->
							<xsl:with-param name="codes">a</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:variable>
			<titleInfo type="translated">
				<!--09/01/04 Added subfield $y-->
				<xsl:for-each select="marc:subfield[@code='y']">
					<xsl:attribute name="lang">
						<xsl:value-of select="text()"/>
					</xsl:attribute>
				</xsl:for-each>
				<title>
					<xsl:value-of select="$titleChop" />
				</title>
				<!-- 1/04 fix -->
				<xsl:call-template name="subtitle"/>
				<xsl:call-template name="part"/>
			</titleInfo>
			<titleInfo type="translated-nfi">
				<xsl:for-each select="marc:subfield[@code='y']">
					<xsl:attribute name="lang">
						<xsl:value-of select="text()"/>
					</xsl:attribute>
				</xsl:for-each>
				<xsl:choose>
					<xsl:when test="@ind2>0">
						<nonSort>
							<xsl:value-of select="substring($titleChop,1,@ind2)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleChop,@ind2+1)"/>
						</title>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleChop" />
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:call-template name="subtitle"/>
				<xsl:call-template name="part"/>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='246']">
			<titleInfo type="alternative">
				<xsl:for-each select="marc:subfield[@code='i']">
					<xsl:attribute name="displayLabel">
						<xsl:value-of select="text()"/>
					</xsl:attribute>
				</xsl:for-each>
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<!-- 1/04 removed $h, $b -->
								<xsl:with-param name="codes">af</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</title>
				<xsl:call-template name="subtitle"/>
				<xsl:call-template name="part"/>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='130']|marc:datafield[@tag='240']|marc:datafield[@tag='730'][@ind2!='2']">
			<xsl:variable name="nfi">
				<xsl:choose>
					<xsl:when test="@tag='240'">
						<xsl:value-of select="@ind2"/>
					</xsl:when>
					<xsl:otherwise>
						<xsl:value-of select="@ind1"/>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:variable>
			<xsl:variable name="titleChop">
				<xsl:call-template name="uri" />
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield">
						<xsl:if test="(contains('adfklmor',@code) and (not(../marc:subfield[@code='n' or @code='p']) or (following-sibling::marc:subfield[@code='n' or @code='p'])))">
							<xsl:value-of select="text()"/>
							<xsl:text> </xsl:text>
						</xsl:if>
					</xsl:for-each>
				</xsl:variable>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:value-of select="substring($str,1,string-length($str)-1)"/>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:variable>
			<titleInfo type="uniform">
				<title>
					<xsl:value-of select="$titleChop"/>
				</title>
				<xsl:call-template name="part"/>
			</titleInfo>
			<titleInfo type="uniform-nfi">
				<xsl:choose>
					<xsl:when test="$nfi>0">
						<nonSort>
							<xsl:value-of select="substring($titleChop,1,$nfi)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleChop,$nfi+1)"/>
						</title>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleChop"/>
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:call-template name="part"/>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='740'][@ind2!='2']">
			<xsl:variable name="titleChop">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">ah</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:variable>
			<titleInfo type="alternative">
				<title>
					<xsl:value-of select="$titleChop" />
				</title>
				<xsl:call-template name="part"/>
			</titleInfo>
			<titleInfo type="alternative-nfi">
				<xsl:choose>
					<xsl:when test="@ind1>0">
						<nonSort>
							<xsl:value-of select="substring($titleChop,1,@ind1)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleChop,@ind1+1)"/>
						</title>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleChop" />
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:call-template name="part"/>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='100']">
			<name type="personal">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameABCDQ"/>
				<xsl:call-template name="affiliation"/>
				<role>
					<roleTerm authority="marcrelator" type="text">creator</roleTerm>
				</role>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='110']">
			<name type="corporate">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameABCDN"/>
				<role>
					<roleTerm authority="marcrelator" type="text">creator</roleTerm>
				</role>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='111']">
			<name type="conference">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameACDEQ"/>
				<role>
					<roleTerm authority="marcrelator" type="text">creator</roleTerm>
				</role>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='700'][not(marc:subfield[@code='t'])]">
			<name type="personal">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameABCDQ"/>
				<xsl:call-template name="affiliation"/>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='710'][not(marc:subfield[@code='t'])]">
			<name type="corporate">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameABCDN"/>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='711'][not(marc:subfield[@code='t'])]">
			<name type="conference">
				<xsl:call-template name="uri" />
				<xsl:call-template name="nameACDEQ"/>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='720'][not(marc:subfield[@code='t'])]">
			<name>
				<xsl:if test="@ind1=1">
					<xsl:attribute name="type">
						<xsl:text>personal</xsl:text>
					</xsl:attribute>
				</xsl:if>
				<namePart>
					<xsl:value-of select="marc:subfield[@code='a']"/>
				</namePart>
				<xsl:call-template name="role"/>
			</name>
		</xsl:for-each>
		<typeOfResource>
			<xsl:if test="$leader7='c'">
				<xsl:attribute name="collection">yes</xsl:attribute>
			</xsl:if>
			<xsl:if test="$leader6='d' or $leader6='f' or $leader6='p' or $leader6='t'">
				<xsl:attribute name="manuscript">yes</xsl:attribute>
			</xsl:if>
			<xsl:choose>
				<xsl:when test="$leader6='a' or $leader6='t'">text</xsl:when>
				<xsl:when test="$leader6='e' or $leader6='f'">cartographic</xsl:when>
				<xsl:when test="$leader6='c' or $leader6='d'">notated music</xsl:when>
				<xsl:when test="$leader6='i'">sound recording-nonmusical</xsl:when>
				<xsl:when test="$leader6='j'">sound recording-musical</xsl:when>
				<xsl:when test="$leader6='k'">still image</xsl:when>
				<xsl:when test="$leader6='g'">moving image</xsl:when>
				<xsl:when test="$leader6='r'">three dimensional object</xsl:when>
				<xsl:when test="$leader6='m'">software, multimedia</xsl:when>
				<xsl:when test="$leader6='p'">mixed material</xsl:when>
			</xsl:choose>
		</typeOfResource>
		<xsl:if test="substring($controlField008,26,1)='d'">
			<genre authority="marc">globe</genre>
		</xsl:if>
		<xsl:if test="marc:controlfield[@tag='007'][substring(text(),1,1)='a'][substring(text(),2,1)='r']">
			<genre authority="marc">remote sensing image</genre>
		</xsl:if>
		<xsl:if test="$typeOf008='MP'">
			<xsl:variable name="controlField008-25" select="substring($controlField008,26,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-25='a' or $controlField008-25='b' or $controlField008-25='c' or marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='j']">
					<genre authority="marc">map</genre>
				</xsl:when>
				<xsl:when test="$controlField008-25='e' or marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='d']">
					<genre authority="marc">atlas</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:if test="$typeOf008='SE'">
			<xsl:variable name="controlField008-21" select="substring($controlField008,22,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-21='d'">
					<genre authority="marc">database</genre>
				</xsl:when>
				<xsl:when test="$controlField008-21='l'">
					<genre authority="marc">loose-leaf</genre>
				</xsl:when>
				<xsl:when test="$controlField008-21='m'">
					<genre authority="marc">series</genre>
				</xsl:when>
				<xsl:when test="$controlField008-21='n'">
					<genre authority="marc">newspaper</genre>
				</xsl:when>
				<xsl:when test="$controlField008-21='p'">
					<genre authority="marc">periodical</genre>
				</xsl:when>
				<xsl:when test="$controlField008-21='w'">
					<genre authority="marc">web site</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:if test="$typeOf008='BK' or $typeOf008='SE'">
			<xsl:variable name="controlField008-24" select="substring($controlField008,25,4)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="contains($controlField008-24,'a')">
					<genre authority="marc">abstract or summary</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'b')">
					<genre authority="marc">bibliography</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'c')">
					<genre authority="marc">catalog</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'d')">
					<genre authority="marc">dictionary</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'e')">
					<genre authority="marc">encyclopedia</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'f')">
					<genre authority="marc">handbook</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'g')">
					<genre authority="marc">legal article</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'i')">
					<genre authority="marc">index</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'k')">
					<genre authority="marc">discography</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'l')">
					<genre authority="marc">legislation</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'m')">
					<genre authority="marc">theses</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'n')">
					<genre authority="marc">survey of literature</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'o')">
					<genre authority="marc">review</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'p')">
					<genre authority="marc">programmed text</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'q')">
					<genre authority="marc">filmography</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'r')">
					<genre authority="marc">directory</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'s')">
					<genre authority="marc">statistics</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'t')">
					<genre authority="marc">technical report</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'v')">
					<genre authority="marc">legal case and case notes</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'w')">
					<genre authority="marc">law report or digest</genre>
				</xsl:when>
				<xsl:when test="contains($controlField008-24,'z')">
					<genre authority="marc">treaty</genre>
				</xsl:when>
			</xsl:choose>
			<xsl:variable name="controlField008-29" select="substring($controlField008,30,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-29='1'">
					<genre authority="marc">conference publication</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:if test="$typeOf008='CF'">
			<xsl:variable name="controlField008-26" select="substring($controlField008,27,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-26='a'">
					<genre authority="marc">numeric data</genre>
				</xsl:when>
				<xsl:when test="$controlField008-26='e'">
					<genre authority="marc">database</genre>
				</xsl:when>
				<xsl:when test="$controlField008-26='f'">
					<genre authority="marc">font</genre>
				</xsl:when>
				<xsl:when test="$controlField008-26='g'">
					<genre authority="marc">game</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:if test="$typeOf008='BK'">
			<xsl:if test="substring($controlField008,25,1)='j'">
				<genre authority="marc">patent</genre>
			</xsl:if>
			<xsl:if test="substring($controlField008,31,1)='1'">
				<genre authority="marc">festschrift</genre>
			</xsl:if>
			<xsl:variable name="controlField008-34" select="substring($controlField008,35,1)"></xsl:variable>
			<xsl:if test="$controlField008-34='a' or $controlField008-34='b' or $controlField008-34='c' or $controlField008-34='d'">
				<genre authority="marc">biography</genre>
			</xsl:if>
			<xsl:variable name="controlField008-33" select="substring($controlField008,34,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-33='e'">
					<genre authority="marc">essay</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='d'">
					<genre authority="marc">drama</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='c'">
					<genre authority="marc">comic strip</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='l'">
					<genre authority="marc">fiction</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='h'">
					<genre authority="marc">humor, satire</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='i'">
					<genre authority="marc">letter</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='f'">
					<genre authority="marc">novel</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='j'">
					<genre authority="marc">short story</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='s'">
					<genre authority="marc">speech</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:if test="$typeOf008='MU'">
			<xsl:variable name="controlField008-30-31" select="substring($controlField008,31,2)"></xsl:variable>
			<xsl:if test="contains($controlField008-30-31,'b')">
				<genre authority="marc">biography</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'c')">
				<genre authority="marc">conference publication</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'d')">
				<genre authority="marc">drama</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'e')">
				<genre authority="marc">essay</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'f')">
				<genre authority="marc">fiction</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'o')">
				<genre authority="marc">folktale</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'h')">
				<genre authority="marc">history</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'k')">
				<genre authority="marc">humor, satire</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'m')">
				<genre authority="marc">memoir</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'p')">
				<genre authority="marc">poetry</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'r')">
				<genre authority="marc">rehearsal</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'g')">
				<genre authority="marc">reporting</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'s')">
				<genre authority="marc">sound</genre>
			</xsl:if>
			<xsl:if test="contains($controlField008-30-31,'l')">
				<genre authority="marc">speech</genre>
			</xsl:if>
		</xsl:if>
		<xsl:if test="$typeOf008='VM'">
			<xsl:variable name="controlField008-33" select="substring($controlField008,34,1)"></xsl:variable>
			<xsl:choose>
				<xsl:when test="$controlField008-33='a'">
					<genre authority="marc">art original</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='b'">
					<genre authority="marc">kit</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='c'">
					<genre authority="marc">art reproduction</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='d'">
					<genre authority="marc">diorama</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='f'">
					<genre authority="marc">filmstrip</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='g'">
					<genre authority="marc">legal article</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='i'">
					<genre authority="marc">picture</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='k'">
					<genre authority="marc">graphic</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='l'">
					<genre authority="marc">technical drawing</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='m'">
					<genre authority="marc">motion picture</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='n'">
					<genre authority="marc">chart</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='o'">
					<genre authority="marc">flash card</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='p'">
					<genre authority="marc">microscope slide</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='q' or marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='q']">
					<genre authority="marc">model</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='r'">
					<genre authority="marc">realia</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='s'">
					<genre authority="marc">slide</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='t'">
					<genre authority="marc">transparency</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='v'">
					<genre authority="marc">videorecording</genre>
				</xsl:when>
				<xsl:when test="$controlField008-33='w'">
					<genre authority="marc">toy</genre>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:for-each select="marc:datafield[@tag=655]">
			<genre authority="marc">
				<xsl:attribute name="authority">
					<xsl:value-of select="marc:subfield[@code='2']"/>
				</xsl:attribute>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">abvxyz</xsl:with-param>
					<xsl:with-param name="delimeter">-</xsl:with-param>
				</xsl:call-template>
			</genre>
		</xsl:for-each>
		<originInfo>
			<xsl:variable name="MARCpublicationCode" select="normalize-space(substring($controlField008,16,3))"></xsl:variable>
			<xsl:if test="translate($MARCpublicationCode,'|','')">
				<place>
					<placeTerm>
						<xsl:attribute name="type">code</xsl:attribute>
						<xsl:attribute name="authority">marccountry</xsl:attribute>
						<xsl:value-of select="$MARCpublicationCode"/>
					</placeTerm>
				</place>
			</xsl:if>
			<xsl:for-each select="marc:datafield[@tag=044]/marc:subfield[@code='c']">
				<place>
					<placeTerm>
						<xsl:attribute name="type">code</xsl:attribute>
						<xsl:attribute name="authority">iso3166</xsl:attribute>
						<xsl:value-of select="."/>
					</placeTerm>
				</place>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=260]/marc:subfield[@code='a']">
				<place>
					<placeTerm>
						<xsl:attribute name="type">text</xsl:attribute>
						<xsl:call-template name="chopPunctuationFront">
							<xsl:with-param name="chopString">
								<xsl:call-template name="chopPunctuation">
									<xsl:with-param name="chopString" select="."/>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</placeTerm>
				</place>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=046]/marc:subfield[@code='m']">
				<dateValid point="start">
					<xsl:value-of select="."/>
				</dateValid>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=046]/marc:subfield[@code='n']">
				<dateValid point="end">
					<xsl:value-of select="."/>
				</dateValid>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=046]/marc:subfield[@code='j']">
				<dateModified>
					<xsl:value-of select="."/>
				</dateModified>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=260]/marc:subfield[@code='b' or @code='c' or @code='g']">
				<xsl:choose>
					<xsl:when test="@code='b'">
						<publisher>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."/>
								<xsl:with-param name="punctuation">
									<xsl:text>:,;/ </xsl:text>
								</xsl:with-param>
							</xsl:call-template>
						</publisher>
					</xsl:when>
					<xsl:when test="@code='c'">
						<dateIssued>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."/>
							</xsl:call-template>
						</dateIssued>
					</xsl:when>
					<xsl:when test="@code='g'">
						<dateCreated>
							<xsl:value-of select="."/>
						</dateCreated>
					</xsl:when>
				</xsl:choose>
			</xsl:for-each>
			<xsl:variable name="dataField260c">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="marc:datafield[@tag=260]/marc:subfield[@code='c']"></xsl:with-param>
				</xsl:call-template>
			</xsl:variable>
			<xsl:variable name="controlField008-7-10" select="normalize-space(substring($controlField008, 8, 4))"></xsl:variable>
			<xsl:variable name="controlField008-11-14" select="normalize-space(substring($controlField008, 12, 4))"></xsl:variable>
			<xsl:variable name="controlField008-6" select="normalize-space(substring($controlField008, 7, 1))"></xsl:variable>
			<xsl:if test="$controlField008-6='e' or $controlField008-6='p' or $controlField008-6='r' or $controlField008-6='t' or $controlField008-6='s'">
				<xsl:if test="$controlField008-7-10 and ($controlField008-7-10 != $dataField260c)">
					<dateIssued encoding="marc">
						<xsl:value-of select="$controlField008-7-10"/>
					</dateIssued>
				</xsl:if>
			</xsl:if>
			<xsl:if test="$controlField008-6='c' or $controlField008-6='d' or $controlField008-6='i' or $controlField008-6='k' or $controlField008-6='m' or $controlField008-6='q' or $controlField008-6='u'">
				<xsl:if test="$controlField008-7-10">
					<dateIssued encoding="marc" point="start">
						<xsl:value-of select="$controlField008-7-10"/>
					</dateIssued>
				</xsl:if>
			</xsl:if>
			<xsl:if test="$controlField008-6='c' or $controlField008-6='d' or $controlField008-6='i' or $controlField008-6='k' or $controlField008-6='m' or $controlField008-6='q' or $controlField008-6='u'">
				<xsl:if test="$controlField008-11-14">
					<dateIssued encoding="marc" point="end">
						<xsl:value-of select="$controlField008-11-14"/>
					</dateIssued>
				</xsl:if>
			</xsl:if>
			<xsl:if test="$controlField008-6='q'">
				<xsl:if test="$controlField008-7-10">
					<dateIssued encoding="marc" point="start" qualifier="questionable">
						<xsl:value-of select="$controlField008-7-10"/>
					</dateIssued>
				</xsl:if>
			</xsl:if>
			<xsl:if test="$controlField008-6='q'">
				<xsl:if test="$controlField008-11-14">
					<dateIssued encoding="marc" point="end" qualifier="questionable">
						<xsl:value-of select="$controlField008-11-14"/>
					</dateIssued>
				</xsl:if>
			</xsl:if>
			<xsl:if test="$controlField008-6='t'">
				<xsl:if test="$controlField008-11-14">
					<copyrightDate encoding="marc">
						<xsl:value-of select="$controlField008-11-14"/>
					</copyrightDate>
				</xsl:if>
			</xsl:if>
			<xsl:for-each select="marc:datafield[@tag=033][@ind1=0 or @ind1=1]/marc:subfield[@code='a']">
				<dateCaptured encoding="iso8601">
					<xsl:value-of select="."/>
				</dateCaptured>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=033][@ind1=2]/marc:subfield[@code='a'][1]">
				<dateCaptured encoding="iso8601" point="start">
					<xsl:value-of select="."/>
				</dateCaptured>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=033][@ind1=2]/marc:subfield[@code='a'][2]">
				<dateCaptured encoding="iso8601" point="end">
					<xsl:value-of select="."/>
				</dateCaptured>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=250]/marc:subfield[@code='a']">
				<edition>
					<xsl:value-of select="."/>
				</edition>
			</xsl:for-each>
			<xsl:for-each select="marc:leader">
				<issuance>
					<xsl:choose>
						<xsl:when test="$leader7='a' or $leader7='c' or $leader7='d' or $leader7='m'">monographic</xsl:when>
						<xsl:when test="$leader7='b' or $leader7='i' or $leader7='s'">continuing</xsl:when>
					</xsl:choose>
				</issuance>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=310]|marc:datafield[@tag=321]">
				<frequency>
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">ab</xsl:with-param>
					</xsl:call-template>
				</frequency>
			</xsl:for-each>
		</originInfo>
		<xsl:variable name="controlField008-35-37" select="normalize-space(translate(substring($controlField008,36,3),'|#',''))"></xsl:variable>
		<xsl:if test="$controlField008-35-37">
			<language>
				<languageTerm authority="iso639-2b" type="code">
					<xsl:value-of select="substring($controlField008,36,3)"/>
				</languageTerm>
			</language>
		</xsl:if>
		<xsl:for-each select="marc:datafield[@tag=041]">
			<xsl:for-each select="marc:subfield[@code='a' or @code='b' or @code='d' or @code='e' or @code='f' or @code='g' or @code='h']">
				<xsl:variable name="langCodes" select="."/>
				<xsl:choose>
					<xsl:when test="../marc:subfield[@code='2']='rfc3066'">
						<!-- not stacked but could be repeated -->
						<xsl:call-template name="rfcLanguages">
							<xsl:with-param name="nodeNum">
								<xsl:value-of select="1"/>
							</xsl:with-param>
							<xsl:with-param name="usedLanguages">
								<xsl:text></xsl:text>
							</xsl:with-param>
							<xsl:with-param name="controlField008-35-37">
								<xsl:value-of select="$controlField008-35-37"></xsl:value-of>
							</xsl:with-param>
						</xsl:call-template>
					</xsl:when>
					<xsl:otherwise>
						<!-- iso -->
						<xsl:variable name="allLanguages">
							<xsl:copy-of select="$langCodes"></xsl:copy-of>
						</xsl:variable>
						<xsl:variable name="currentLanguage">
							<xsl:value-of select="substring($allLanguages,1,3)"></xsl:value-of>
						</xsl:variable>
						<xsl:call-template name="isoLanguage">
							<xsl:with-param name="currentLanguage">
								<xsl:value-of select="substring($allLanguages,1,3)"></xsl:value-of>
							</xsl:with-param>
							<xsl:with-param name="remainingLanguages">
								<xsl:value-of select="substring($allLanguages,4,string-length($allLanguages)-3)"></xsl:value-of>
							</xsl:with-param>
							<xsl:with-param name="usedLanguages">
								<xsl:if test="$controlField008-35-37">
									<xsl:value-of select="$controlField008-35-37"></xsl:value-of>
								</xsl:if>
							</xsl:with-param>
						</xsl:call-template>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:for-each>
		</xsl:for-each>
		<xsl:variable name="physicalDescription">
			<!--3.2 change tmee 007/11 -->
			<xsl:if test="$typeOf008='CF' and marc:controlfield[@tag=007][substring(.,12,1)='a']">
				<digitalOrigin>reformatted digital</digitalOrigin>
			</xsl:if>
			<xsl:if test="$typeOf008='CF' and marc:controlfield[@tag=007][substring(.,12,1)='b']">
				<digitalOrigin>digitized microfilm</digitalOrigin>
			</xsl:if>
			<xsl:if test="$typeOf008='CF' and marc:controlfield[@tag=007][substring(.,12,1)='d']">
				<digitalOrigin>digitized other analog</digitalOrigin>
			</xsl:if>
			<xsl:variable name="controlField008-23" select="substring($controlField008,24,1)"></xsl:variable>
			<xsl:variable name="controlField008-29" select="substring($controlField008,30,1)"></xsl:variable>
			<xsl:variable name="check008-23">
				<xsl:if test="$typeOf008='BK' or $typeOf008='MU' or $typeOf008='SE' or $typeOf008='MM'">
					<xsl:value-of select="true()"></xsl:value-of>
				</xsl:if>
			</xsl:variable>
			<xsl:variable name="check008-29">
				<xsl:if test="$typeOf008='MP' or $typeOf008='VM'">
					<xsl:value-of select="true()"></xsl:value-of>
				</xsl:if>
			</xsl:variable>
			<xsl:choose>
				<xsl:when test="($check008-23 and $controlField008-23='f') or ($check008-29 and $controlField008-29='f')">
					<form authority="marcform">braille</form>
				</xsl:when>
				<xsl:when test="($controlField008-23=' ' and ($leader6='c' or $leader6='d')) or (($typeOf008='BK' or $typeOf008='SE') and ($controlField008-23=' ' or $controlField008='r'))">
					<form authority="marcform">print</form>
				</xsl:when>
				<xsl:when test="$leader6 = 'm' or ($check008-23 and $controlField008-23='s') or ($check008-29 and $controlField008-29='s')">
					<form authority="marcform">electronic</form>
				</xsl:when>
				<xsl:when test="($check008-23 and $controlField008-23='b') or ($check008-29 and $controlField008-29='b')">
					<form authority="marcform">microfiche</form>
				</xsl:when>
				<xsl:when test="($check008-23 and $controlField008-23='a') or ($check008-29 and $controlField008-29='a')">
					<form authority="marcform">microfilm</form>
				</xsl:when>
			</xsl:choose>
			<!-- 1/04 fix -->
			<xsl:if test="marc:datafield[@tag=130]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=130]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:if test="marc:datafield[@tag=240]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=240]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:if test="marc:datafield[@tag=242]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=242]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:if test="marc:datafield[@tag=245]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=245]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:if test="marc:datafield[@tag=246]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=246]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:if test="marc:datafield[@tag=730]/marc:subfield[@code='h']">
				<form authority="gmd">
					<xsl:call-template name="chopBrackets">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:datafield[@tag=730]/marc:subfield[@code='h']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</form>
			</xsl:if>
			<xsl:for-each select="marc:datafield[@tag=256]/marc:subfield[@code='a']">
				<form>
					<xsl:value-of select="."></xsl:value-of>
				</form>
			</xsl:for-each>
			<xsl:for-each select="marc:controlfield[@tag=007][substring(text(),1,1)='c']">
				<xsl:choose>
					<xsl:when test="substring(text(),14,1)='a'">
						<reformattingQuality>access</reformattingQuality>
					</xsl:when>
					<xsl:when test="substring(text(),14,1)='p'">
						<reformattingQuality>preservation</reformattingQuality>
					</xsl:when>
					<xsl:when test="substring(text(),14,1)='r'">
						<reformattingQuality>replacement</reformattingQuality>
					</xsl:when>
				</xsl:choose>
			</xsl:for-each>
			<!--3.2 change tmee 007/01 -->
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='b']">
				<form authority="smd">chip cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='c']">
				<form authority="smd">computer optical disc cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='j']">
				<form authority="smd">magnetic disc</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='m']">
				<form authority="smd">magneto-optical disc</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='o']">
				<form authority="smd">optical disc</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='r']">
				<form authority="smd">remote</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='a']">
				<form authority="smd">tape cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='f']">
				<form authority="smd">tape cassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='c'][substring(text(),2,1)='h']">
				<form authority="smd">tape reel</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='d'][substring(text(),2,1)='a']">
				<form authority="smd">celestial globe</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='d'][substring(text(),2,1)='e']">
				<form authority="smd">earth moon globe</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='d'][substring(text(),2,1)='b']">
				<form authority="smd">planetary or lunar globe</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='d'][substring(text(),2,1)='c']">
				<form authority="smd">terrestrial globe</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='o'][substring(text(),2,1)='o']">
				<form authority="smd">kit</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='d']">
				<form authority="smd">atlas</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='g']">
				<form authority="smd">diagram</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='j']">
				<form authority="smd">map</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='q']">
				<form authority="smd">model</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='k']">
				<form authority="smd">profile</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='r']">
				<form authority="smd">remote-sensing image</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='s']">
				<form authority="smd">section</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='a'][substring(text(),2,1)='y']">
				<form authority="smd">view</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='a']">
				<form authority="smd">aperture card</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='e']">
				<form authority="smd">microfiche</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='f']">
				<form authority="smd">microfiche cassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='b']">
				<form authority="smd">microfilm cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='c']">
				<form authority="smd">microfilm cassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='d']">
				<form authority="smd">microfilm reel</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='h'][substring(text(),2,1)='g']">
				<form authority="smd">microopaque</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='m'][substring(text(),2,1)='c']">
				<form authority="smd">film cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='m'][substring(text(),2,1)='f']">
				<form authority="smd">film cassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='m'][substring(text(),2,1)='r']">
				<form authority="smd">film reel</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='n']">
				<form authority="smd">chart</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='c']">
				<form authority="smd">collage</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='d']">
				<form authority="smd">drawing</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='o']">
				<form authority="smd">flash card</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='e']">
				<form authority="smd">painting</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='f']">
				<form authority="smd">photomechanical print</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='g']">
				<form authority="smd">photonegative</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='h']">
				<form authority="smd">photoprint</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='i']">
				<form authority="smd">picture</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='j']">
				<form authority="smd">print</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='k'][substring(text(),2,1)='l']">
				<form authority="smd">technical drawing</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='q'][substring(text(),2,1)='q']">
				<form authority="smd">notated music</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='d']">
				<form authority="smd">filmslip</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='c']">
				<form authority="smd">filmstrip cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='o']">
				<form authority="smd">filmstrip roll</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='f']">
				<form authority="smd">other filmstrip type</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='s']">
				<form authority="smd">slide</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='g'][substring(text(),2,1)='t']">
				<form authority="smd">transparency</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='r'][substring(text(),2,1)='r']">
				<form authority="smd">remote-sensing image</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='e']">
				<form authority="smd">cylinder</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='q']">
				<form authority="smd">roll</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='g']">
				<form authority="smd">sound cartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='s']">
				<form authority="smd">sound cassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='d']">
				<form authority="smd">sound disc</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='t']">
				<form authority="smd">sound-tape reel</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='i']">
				<form authority="smd">sound-track film</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='s'][substring(text(),2,1)='w']">
				<form authority="smd">wire recording</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='f'][substring(text(),2,1)='c']">
				<form authority="smd">braille</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='f'][substring(text(),2,1)='b']">
				<form authority="smd">combination</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='f'][substring(text(),2,1)='a']">
				<form authority="smd">moon</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='f'][substring(text(),2,1)='d']">
				<form authority="smd">tactile, with no writing system</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='t'][substring(text(),2,1)='c']">
				<form authority="smd">braille</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='t'][substring(text(),2,1)='b']">
				<form authority="smd">large print</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='t'][substring(text(),2,1)='a']">
				<form authority="smd">regular print</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='t'][substring(text(),2,1)='d']">
				<form authority="smd">text in looseleaf binder</form>
			</xsl:if>
			
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='v'][substring(text(),2,1)='c']">
				<form authority="smd">videocartridge</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='v'][substring(text(),2,1)='f']">
				<form authority="smd">videocassette</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='v'][substring(text(),2,1)='d']">
				<form authority="smd">videodisc</form>
			</xsl:if>
			<xsl:if test="marc:controlfield[@tag=007][substring(text(),1,1)='v'][substring(text(),2,1)='r']">
				<form authority="smd">videoreel</form>
			</xsl:if>
			
			<xsl:for-each select="marc:datafield[@tag=856]/marc:subfield[@code='q'][string-length(.)>1]">
				<internetMediaType>
					<xsl:value-of select="."></xsl:value-of>
				</internetMediaType>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=300]">
				<extent>
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">abce</xsl:with-param>
					</xsl:call-template>
				</extent>
			</xsl:for-each>
		</xsl:variable>
		<xsl:if test="string-length(normalize-space($physicalDescription))">
			<physicalDescription>
				<xsl:copy-of select="$physicalDescription"></xsl:copy-of>
			</physicalDescription>
		</xsl:if>
		<xsl:for-each select="marc:datafield[@tag=520]">
			<abstract>
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</abstract>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=505]">
			<tableOfContents>
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">agrt</xsl:with-param>
				</xsl:call-template>
			</tableOfContents>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=521]">
			<targetAudience>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</targetAudience>
		</xsl:for-each>
		<xsl:if test="$typeOf008='BK' or $typeOf008='CF' or $typeOf008='MU' or $typeOf008='VM'">
			<xsl:variable name="controlField008-22" select="substring($controlField008,23,1)"></xsl:variable>
			<xsl:choose>
				<!-- 01/04 fix -->
				<xsl:when test="$controlField008-22='d'">
					<targetAudience authority="marctarget">adolescent</targetAudience>
				</xsl:when>
				<xsl:when test="$controlField008-22='e'">
					<targetAudience authority="marctarget">adult</targetAudience>
				</xsl:when>
				<xsl:when test="$controlField008-22='g'">
					<targetAudience authority="marctarget">general</targetAudience>
				</xsl:when>
				<xsl:when test="$controlField008-22='b' or $controlField008-22='c' or $controlField008-22='j'">
					<targetAudience authority="marctarget">juvenile</targetAudience>
				</xsl:when>
				<xsl:when test="$controlField008-22='a'">
					<targetAudience authority="marctarget">preschool</targetAudience>
				</xsl:when>
				<xsl:when test="$controlField008-22='f'">
					<targetAudience authority="marctarget">specialized</targetAudience>
				</xsl:when>
			</xsl:choose>
		</xsl:if>
		<xsl:for-each select="marc:datafield[@tag=245]/marc:subfield[@code='c']">
			<note type="statement of responsibility">
				<xsl:value-of select="."></xsl:value-of>
			</note>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=500]">
			<note>
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
				<xsl:call-template name="uri"></xsl:call-template>
			</note>
		</xsl:for-each>
		
		<!--3.2 change tmee additional note fields-->
		
        <xsl:for-each select="marc:datafield[@tag=502]">
            <note type="thesis">
                <xsl:call-template name="uri"/>
                <xsl:variable name="str">
                    <xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
                        <xsl:value-of select="."/>
                        <xsl:text> </xsl:text>
                    </xsl:for-each>
                </xsl:variable>
                <xsl:value-of select="substring($str,1,string-length($str)-1)"/>
            </note>
        </xsl:for-each>

        <xsl:for-each select="marc:datafield[@tag=504]">
            <note type="bibliography">
                <xsl:call-template name="uri"/>
                <xsl:variable name="str">
                    <xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
                        <xsl:value-of select="."/>
                        <xsl:text> </xsl:text>
                    </xsl:for-each>
                </xsl:variable>
                <xsl:value-of select="substring($str,1,string-length($str)-1)"/>
            </note>
        </xsl:for-each>

        <xsl:for-each select="marc:datafield[@tag=508]">
            <note type="creation/production credits">
                <xsl:call-template name="uri"/>
                <xsl:variable name="str">
                    <xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
                        <xsl:value-of select="."/>
                        <xsl:text> </xsl:text>
                    </xsl:for-each>
                </xsl:variable>
                <xsl:value-of select="substring($str,1,string-length($str)-1)"/>
            </note>
        </xsl:for-each>

		<xsl:for-each select="marc:datafield[@tag=506]">
			<note type="restrictions">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=510]">
			<note  type="citation/reference">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
			
		<xsl:for-each select="marc:datafield[@tag=511]">
			<note type="performers">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
			</note>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=518]">
			<note type="venue">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=530]">
			<note  type="additional physical form">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=533]">
			<note  type="reproduction">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=534]">
			<note  type="original version">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=538]">
			<note  type="system details">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		
		<xsl:for-each select="marc:datafield[@tag=583]">
			<note type="action">
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		

		
        <xsl:for-each select="marc:datafield[@tag=501 or @tag=507 or @tag=513 or @tag=514 or @tag=515 or @tag=516 or @tag=522 or @tag=524 or @tag=525 or @tag=526 or @tag=535 or @tag=536 or @tag=540 or @tag=541 or @tag=544 or @tag=545 or @tag=546 or @tag=547 or @tag=550 or @tag=552 or @tag=555 or @tag=556 or @tag=561 or @tag=562 or @tag=565 or @tag=567 or @tag=580 or @tag=581 or @tag=584 or @tag=585 or @tag=586]">
			<note>
				<xsl:call-template name="uri"></xsl:call-template>
				<xsl:variable name="str">
					<xsl:for-each select="marc:subfield[@code!='6' or @code!='8']">
						<xsl:value-of select="."></xsl:value-of>
						<xsl:text> </xsl:text>
					</xsl:for-each>
				</xsl:variable>
				<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
			</note>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=034][marc:subfield[@code='d' or @code='e' or @code='f' or @code='g']]">
			<subject>
				<cartographics>
					<coordinates>
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">defg</xsl:with-param>
						</xsl:call-template>
					</coordinates>
				</cartographics>
			</subject>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=043]">
			<subject>
				<xsl:for-each select="marc:subfield[@code='a' or @code='b' or @code='c']">
					<geographicCode>
						<xsl:attribute name="authority">
							<xsl:if test="@code='a'">
								<xsl:text>marcgac</xsl:text>
							</xsl:if>
							<xsl:if test="@code='b'">
								<xsl:value-of select="following-sibling::marc:subfield[@code=2]"></xsl:value-of>
							</xsl:if>
							<xsl:if test="@code='c'">
								<xsl:text>iso3166</xsl:text>
							</xsl:if>
						</xsl:attribute>
						<xsl:value-of select="self::marc:subfield"></xsl:value-of>
					</geographicCode>
				</xsl:for-each>
			</subject>
		</xsl:for-each>
		<!-- tmee 2006/11/27 -->
		<xsl:for-each select="marc:datafield[@tag=255]">
			<subject>
				<xsl:for-each select="marc:subfield[@code='a' or @code='b' or @code='c']">
				<cartographics>
					<xsl:if test="@code='a'">
						<scale>
							<xsl:value-of select="."></xsl:value-of>
						</scale>
					</xsl:if>
					<xsl:if test="@code='b'">
						<projection>
							<xsl:value-of select="."></xsl:value-of>
						</projection>
					</xsl:if>
					<xsl:if test="@code='c'">
						<coordinates>
							<xsl:value-of select="."></xsl:value-of>
						</coordinates>
					</xsl:if>
				</cartographics>
				</xsl:for-each>
			</subject>
		</xsl:for-each>
				
		<xsl:apply-templates select="marc:datafield[653 >= @tag and @tag >= 600]"></xsl:apply-templates>
		<xsl:apply-templates select="marc:datafield[@tag=656]"></xsl:apply-templates>
		<xsl:for-each select="marc:datafield[@tag=752]">
			<subject>
				<hierarchicalGeographic>
					<xsl:for-each select="marc:subfield[@code='a']">
						<country>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."></xsl:with-param>
							</xsl:call-template>
						</country>
					</xsl:for-each>
					<xsl:for-each select="marc:subfield[@code='b']">
						<state>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."></xsl:with-param>
							</xsl:call-template>
						</state>
					</xsl:for-each>
					<xsl:for-each select="marc:subfield[@code='c']">
						<county>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."></xsl:with-param>
							</xsl:call-template>
						</county>
					</xsl:for-each>
					<xsl:for-each select="marc:subfield[@code='d']">
						<city>
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString" select="."></xsl:with-param>
							</xsl:call-template>
						</city>
					</xsl:for-each>
				</hierarchicalGeographic>
			</subject>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=045][marc:subfield[@code='b']]">
			<subject>
				<xsl:choose>
					<xsl:when test="@ind1=2">
						<temporal encoding="iso8601" point="start">
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString">
									<xsl:value-of select="marc:subfield[@code='b'][1]"></xsl:value-of>
								</xsl:with-param>
							</xsl:call-template>
						</temporal>
						<temporal encoding="iso8601" point="end">
							<xsl:call-template name="chopPunctuation">
								<xsl:with-param name="chopString">
									<xsl:value-of select="marc:subfield[@code='b'][2]"></xsl:value-of>
								</xsl:with-param>
							</xsl:call-template>
						</temporal>
					</xsl:when>
					<xsl:otherwise>
						<xsl:for-each select="marc:subfield[@code='b']">
							<temporal encoding="iso8601">
								<xsl:call-template name="chopPunctuation">
									<xsl:with-param name="chopString" select="."></xsl:with-param>
								</xsl:call-template>
							</temporal>
						</xsl:for-each>
					</xsl:otherwise>
				</xsl:choose>
			</subject>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=050]">
			<xsl:for-each select="marc:subfield[@code='b']">
				<classification authority="lcc">
					<xsl:if test="../marc:subfield[@code='3']">
						<xsl:attribute name="displayLabel">
							<xsl:value-of select="../marc:subfield[@code='3']"></xsl:value-of>
						</xsl:attribute>
					</xsl:if>
					<xsl:value-of select="preceding-sibling::marc:subfield[@code='a'][1]"></xsl:value-of>
					<xsl:text> </xsl:text>
					<xsl:value-of select="text()"></xsl:value-of>
				</classification>
			</xsl:for-each>
			<xsl:for-each select="marc:subfield[@code='a'][not(following-sibling::marc:subfield[@code='b'])]">
				<classification authority="lcc">
					<xsl:if test="../marc:subfield[@code='3']">
						<xsl:attribute name="displayLabel">
							<xsl:value-of select="../marc:subfield[@code='3']"></xsl:value-of>
						</xsl:attribute>
					</xsl:if>
					<xsl:value-of select="text()"></xsl:value-of>
				</classification>
			</xsl:for-each>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=082]">
			<classification authority="ddc">
				<xsl:if test="marc:subfield[@code='2']">
					<xsl:attribute name="edition">
						<xsl:value-of select="marc:subfield[@code='2']"></xsl:value-of>
					</xsl:attribute>
				</xsl:if>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=080]">
			<classification authority="udc">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">abx</xsl:with-param>
				</xsl:call-template>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=060]">
			<classification authority="nlm">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=086][@ind1=0]">
			<classification authority="sudocs">
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=086][@ind1=1]">
			<classification authority="candoc">
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=086]">
			<classification>
				<xsl:attribute name="authority">
					<xsl:value-of select="marc:subfield[@code='2']"></xsl:value-of>
				</xsl:attribute>
				<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=084]">
			<classification>
				<xsl:attribute name="authority">
					<xsl:value-of select="marc:subfield[@code='2']"></xsl:value-of>
				</xsl:attribute>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</classification>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=440]">
			<relatedItem type="series">
				<xsl:variable name="titleChop">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">av</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<titleInfo>
					<title>
						<xsl:value-of select="$titleChop" />
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<titleInfo type="nfi">
					<xsl:choose>
						<xsl:when test="@ind2>0">
							<nonSort>
								<xsl:value-of select="substring($titleChop,1,@ind2)"/>
							</nonSort>
							<title>
								<xsl:value-of select="substring($titleChop,@ind2+1)"/>
							</title>
							<xsl:call-template name="part"/>
						</xsl:when>
						<xsl:otherwise>
							<title>
								<xsl:value-of select="$titleChop" />
							</title>
						</xsl:otherwise>
					</xsl:choose>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=490][@ind1=0]">
			<relatedItem type="series">
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="subfieldSelect">
									<xsl:with-param name="codes">av</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=510]">
			<relatedItem type="isReferencedBy">
				<note>
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">abcx3</xsl:with-param>
					</xsl:call-template>
				</note>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=534]">
			<relatedItem type="original">
				<xsl:call-template name="relatedTitle"></xsl:call-template>
				<xsl:call-template name="relatedName"></xsl:call-template>
				<xsl:if test="marc:subfield[@code='b' or @code='c']">
					<originInfo>
						<xsl:for-each select="marc:subfield[@code='c']">
							<publisher>
								<xsl:value-of select="."></xsl:value-of>
							</publisher>
						</xsl:for-each>
						<xsl:for-each select="marc:subfield[@code='b']">
							<edition>
								<xsl:value-of select="."></xsl:value-of>
							</edition>
						</xsl:for-each>
					</originInfo>
				</xsl:if>
				<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
				<xsl:for-each select="marc:subfield[@code='z']">
					<identifier type="isbn">
						<xsl:value-of select="."></xsl:value-of>
					</identifier>
				</xsl:for-each>
				<xsl:call-template name="relatedNote"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=700][marc:subfield[@code='t']]">
			<relatedItem>
				<xsl:call-template name="constituentOrRelatedType"></xsl:call-template>
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklmorsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">g</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<name type="personal">
					<namePart>
						<xsl:call-template name="specialSubfieldSelect">
							<xsl:with-param name="anyCodes">aq</xsl:with-param>
							<xsl:with-param name="axis">t</xsl:with-param>
							<xsl:with-param name="beforeCodes">g</xsl:with-param>
						</xsl:call-template>
					</namePart>
					<xsl:call-template name="termsOfAddress"></xsl:call-template>
					<xsl:call-template name="nameDate"></xsl:call-template>
					<xsl:call-template name="role"></xsl:call-template>
				</name>
				<xsl:call-template name="relatedForm"></xsl:call-template>
				<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=710][marc:subfield[@code='t']]">
			<relatedItem>
				<xsl:call-template name="constituentOrRelatedType"></xsl:call-template>
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklmorsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">dg</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</titleInfo>
				<name type="corporate">
					<xsl:for-each select="marc:subfield[@code='a']">
						<namePart>
							<xsl:value-of select="."></xsl:value-of>
						</namePart>
					</xsl:for-each>
					<xsl:for-each select="marc:subfield[@code='b']">
						<namePart>
							<xsl:value-of select="."></xsl:value-of>
						</namePart>
					</xsl:for-each>
					<xsl:variable name="tempNamePart">
						<xsl:call-template name="specialSubfieldSelect">
							<xsl:with-param name="anyCodes">c</xsl:with-param>
							<xsl:with-param name="axis">t</xsl:with-param>
							<xsl:with-param name="beforeCodes">dgn</xsl:with-param>
						</xsl:call-template>
					</xsl:variable>
					<xsl:if test="normalize-space($tempNamePart)">
						<namePart>
							<xsl:value-of select="$tempNamePart"></xsl:value-of>
						</namePart>
					</xsl:if>
					<xsl:call-template name="role"></xsl:call-template>
				</name>
				<xsl:call-template name="relatedForm"></xsl:call-template>
				<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=711][marc:subfield[@code='t']]">
			<relatedItem>
				<xsl:call-template name="constituentOrRelatedType"></xsl:call-template>
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">g</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</titleInfo>
				<name type="conference">
					<namePart>
						<xsl:call-template name="specialSubfieldSelect">
							<xsl:with-param name="anyCodes">aqdc</xsl:with-param>
							<xsl:with-param name="axis">t</xsl:with-param>
							<xsl:with-param name="beforeCodes">gn</xsl:with-param>
						</xsl:call-template>
					</namePart>
				</name>
				<xsl:call-template name="relatedForm"></xsl:call-template>
				<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=730][@ind2=2]">
			<relatedItem>
				<xsl:call-template name="constituentOrRelatedType"></xsl:call-template>
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="subfieldSelect">
									<xsl:with-param name="codes">adfgklmorsv</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<xsl:call-template name="relatedForm"></xsl:call-template>
				<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=740][@ind2=2]">
			<relatedItem>
				<xsl:call-template name="constituentOrRelatedType"></xsl:call-template>
				<xsl:variable name="titleChop">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<titleInfo>
					<title>
						<xsl:value-of select="$titleChop" />
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<titleInfo type="nfi">
					<xsl:choose>
						<xsl:when test="@ind1>0">
							<nonSort>
								<xsl:value-of select="substring($titleChop,1,@ind1)"/>
							</nonSort>
							<title>
								<xsl:value-of select="substring($titleChop,@ind1+1)"/>
							</title>
						</xsl:when>
						<xsl:otherwise>
							<title>
								<xsl:value-of select="$titleChop" />
							</title>
						</xsl:otherwise>
					</xsl:choose>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<xsl:call-template name="relatedForm"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=760]|marc:datafield[@tag=762]">
			<relatedItem type="series">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=765]|marc:datafield[@tag=767]|marc:datafield[@tag=777]|marc:datafield[@tag=787]">
			<relatedItem>
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=775]">
			<relatedItem type="otherVersion">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=770]|marc:datafield[@tag=774]">
			<relatedItem type="constituent">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=772]|marc:datafield[@tag=773]">
			<relatedItem type="host">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=776]">
			<relatedItem type="otherFormat">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=780]">
			<relatedItem type="preceding">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=785]">
			<relatedItem type="succeeding">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=786]">
			<relatedItem type="original">
				<xsl:call-template name="relatedItem76X-78X"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=800]">
			<relatedItem type="series">
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklmorsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">g</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="part"></xsl:call-template>
				</titleInfo>
				<name type="personal">
					<namePart>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">aq</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="beforeCodes">g</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</namePart>
					<xsl:call-template name="termsOfAddress"></xsl:call-template>
					<xsl:call-template name="nameDate"></xsl:call-template>
					<xsl:call-template name="role"></xsl:call-template>
				</name>
				<xsl:call-template name="relatedForm"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=810]">
			<relatedItem type="series">
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklmorsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">dg</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</titleInfo>
				<name type="corporate">
					<xsl:for-each select="marc:subfield[@code='a']">
						<namePart>
							<xsl:value-of select="."></xsl:value-of>
						</namePart>
					</xsl:for-each>
					<xsl:for-each select="marc:subfield[@code='b']">
						<namePart>
							<xsl:value-of select="."></xsl:value-of>
						</namePart>
					</xsl:for-each>
					<namePart>
						<xsl:call-template name="specialSubfieldSelect">
							<xsl:with-param name="anyCodes">c</xsl:with-param>
							<xsl:with-param name="axis">t</xsl:with-param>
							<xsl:with-param name="beforeCodes">dgn</xsl:with-param>
						</xsl:call-template>
					</namePart>
					<xsl:call-template name="role"></xsl:call-template>
				</name>
				<xsl:call-template name="relatedForm"></xsl:call-template>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=811]">
			<relatedItem type="series">
				<titleInfo>
					<title>
						<xsl:call-template name="chopPunctuation">
							<xsl:with-param name="chopString">
								<xsl:call-template name="specialSubfieldSelect">
									<xsl:with-param name="anyCodes">tfklsv</xsl:with-param>
									<xsl:with-param name="axis">t</xsl:with-param>
									<xsl:with-param name="afterCodes">g</xsl:with-param>
								</xsl:call-template>
							</xsl:with-param>
						</xsl:call-template>
					</title>
					<xsl:call-template name="relatedPartNumName"/>
				</titleInfo>
				<name type="conference">
					<namePart>
						<xsl:call-template name="specialSubfieldSelect">
							<xsl:with-param name="anyCodes">aqdc</xsl:with-param>
							<xsl:with-param name="axis">t</xsl:with-param>
							<xsl:with-param name="beforeCodes">gn</xsl:with-param>
						</xsl:call-template>
					</namePart>
					<xsl:call-template name="role"/>
				</name>
				<xsl:call-template name="relatedForm"/>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='830']">
			<relatedItem type="series">
				<xsl:variable name="titleChop">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">adfgklmorsv</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<titleInfo>
					<title>
						<xsl:value-of select="$titleChop" />
					</title>
					<xsl:call-template name="part"/>
				</titleInfo>
				<titleInfo type="nfi">
					<xsl:choose>
						<xsl:when test="@ind2>0">
							<nonSort>
								<xsl:value-of select="substring($titleChop,1,@ind2)"/>
							</nonSort>
							<title>
								<xsl:value-of select="substring($titleChop,@ind2+1)"/>
							</title>
						</xsl:when>
						<xsl:otherwise>
							<title>
								<xsl:value-of select="$titleChop" />
							</title>
						</xsl:otherwise>
					</xsl:choose>
					<xsl:call-template name="part"/>
				</titleInfo>
				<xsl:call-template name="relatedForm"/>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='856'][@ind2='2']/marc:subfield[@code='q']">
			<relatedItem>
				<internetMediaType>
					<xsl:value-of select="."/>
				</internetMediaType>
			</relatedItem>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='020']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">isbn</xsl:with-param>
			</xsl:call-template>
			<xsl:if test="marc:subfield[@code='a']">
				<identifier type="isbn">
					<xsl:value-of select="marc:subfield[@code='a']"/>
				</identifier>
			</xsl:if>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='024'][@ind1='0']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">isrc</xsl:with-param>
			</xsl:call-template>
			<xsl:if test="marc:subfield[@code='a']">
				<identifier type="isrc">
					<xsl:value-of select="marc:subfield[@code='a']"/>
				</identifier>
			</xsl:if>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='024'][@ind1='2']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">ismn</xsl:with-param>
			</xsl:call-template>
			<xsl:if test="marc:subfield[@code='a']">
				<identifier type="ismn">
					<xsl:value-of select="marc:subfield[@code='a']"/>
				</identifier>
			</xsl:if>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='024'][@ind1='4']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">sici</xsl:with-param>
			</xsl:call-template>
			<identifier type="sici">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</identifier>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='022']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">issn</xsl:with-param>
			</xsl:call-template>
			<identifier type="issn">
				<xsl:value-of select="marc:subfield[@code='a']"/>
			</identifier>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='010']">
			<xsl:call-template name="isInvalid">
				<xsl:with-param name="type">lccn</xsl:with-param>
			</xsl:call-template>
			<identifier type="lccn">
				<xsl:value-of select="normalize-space(marc:subfield[@code='a'])"/>
			</identifier>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='028']">
			<identifier>
				<xsl:attribute name="type">
					<xsl:choose>
						<xsl:when test="@ind1='0'">issue number</xsl:when>
						<xsl:when test="@ind1='1'">matrix number</xsl:when>
						<xsl:when test="@ind1='2'">music plate</xsl:when>
						<xsl:when test="@ind1='3'">music publisher</xsl:when>
						<xsl:when test="@ind1='4'">videorecording identifier</xsl:when>
					</xsl:choose>
				</xsl:attribute>
				<!--<xsl:call-template name="isInvalid"/>--> <!-- no $z in 028 -->
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">
						<xsl:choose>
							<xsl:when test="@ind1='0'">ba</xsl:when>
							<xsl:otherwise>ab</xsl:otherwise>
						</xsl:choose>
					</xsl:with-param>
				</xsl:call-template>
			</identifier>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='037']">
			<identifier type="stock number">
				<!--<xsl:call-template name="isInvalid"/>--> <!-- no $z in 037 -->
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">ab</xsl:with-param>
				</xsl:call-template>
			</identifier>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag='856'][marc:subfield[@code='u']]">
			<identifier>
				<xsl:attribute name="type">
					<xsl:choose>
						<xsl:when test="starts-with(marc:subfield[@code='u'],'urn:doi') or starts-with(marc:subfield[@code='u'],'doi')">doi</xsl:when>
						<xsl:when test="starts-with(marc:subfield[@code='u'],'urn:hdl') or starts-with(marc:subfield[@code='u'],'hdl') or starts-with(marc:subfield[@code='u'],'http://hdl.loc.gov')">hdl</xsl:when>
						<xsl:otherwise>uri</xsl:otherwise>
					</xsl:choose>
				</xsl:attribute>
				<xsl:choose>
					<xsl:when test="starts-with(marc:subfield[@code='u'],'urn:hdl') or starts-with(marc:subfield[@code='u'],'hdl') or starts-with(marc:subfield[@code='u'],'http://hdl.loc.gov') ">
						<xsl:value-of select="concat('hdl:',substring-after(marc:subfield[@code='u'],'http://hdl.loc.gov/'))"></xsl:value-of>
					</xsl:when>
					<xsl:otherwise>
						<xsl:value-of select="marc:subfield[@code='u']"></xsl:value-of>
					</xsl:otherwise>
				</xsl:choose>
			</identifier>
			<xsl:if test="starts-with(marc:subfield[@code='u'],'urn:hdl') or starts-with(marc:subfield[@code='u'],'hdl')">
				<identifier type="hdl">
					<xsl:if test="marc:subfield[@code='y' or @code='3' or @code='z']">
						<xsl:attribute name="displayLabel">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">y3z</xsl:with-param>
							</xsl:call-template>
						</xsl:attribute>
					</xsl:if>
					<xsl:value-of select="concat('hdl:',substring-after(marc:subfield[@code='u'],'http://hdl.loc.gov/'))"></xsl:value-of>
				</identifier>
			</xsl:if>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=024][@ind1=1]">
			<identifier type="upc">
				<xsl:call-template name="isInvalid"/>
				<xsl:value-of select="marc:subfield[@code='a']"/>
			</identifier>
		</xsl:for-each>
		<!-- 1/04 fix added $y -->
		<xsl:for-each select="marc:datafield[@tag=856][marc:subfield[@code='u']]">
			<location>
				<url>
					<xsl:if test="marc:subfield[@code='y' or @code='3']">
						<xsl:attribute name="displayLabel">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">y3</xsl:with-param>
							</xsl:call-template>
						</xsl:attribute>
					</xsl:if>
					<xsl:if test="marc:subfield[@code='z' ]">
						<xsl:attribute name="note">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">z</xsl:with-param>
							</xsl:call-template>
						</xsl:attribute>
					</xsl:if>
					<xsl:value-of select="marc:subfield[@code='u']"></xsl:value-of>

				</url>
			</location>
		</xsl:for-each>
			
			<!-- 3.2 change tmee 856z  -->

		
		<xsl:for-each select="marc:datafield[@tag=852]">
			<location>
				<physicalLocation>
					<xsl:call-template name="displayLabel"></xsl:call-template>
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">abje</xsl:with-param>
					</xsl:call-template>
				</physicalLocation>
			</location>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=506]">
			<accessCondition type="restrictionOnAccess">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">abcd35</xsl:with-param>
				</xsl:call-template>
			</accessCondition>
		</xsl:for-each>
		<xsl:for-each select="marc:datafield[@tag=540]">
			<accessCondition type="useAndReproduction">
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">abcde35</xsl:with-param>
				</xsl:call-template>
			</accessCondition>
		</xsl:for-each>
		<recordInfo>
			<xsl:for-each select="marc:datafield[@tag=040]">
				<recordContentSource authority="marcorg">
					<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
				</recordContentSource>
			</xsl:for-each>
			<xsl:for-each select="marc:controlfield[@tag=008]">
				<recordCreationDate encoding="marc">
					<xsl:value-of select="substring(.,1,6)"></xsl:value-of>
				</recordCreationDate>
			</xsl:for-each>
			<xsl:for-each select="marc:controlfield[@tag=005]">
				<recordChangeDate encoding="iso8601">
					<xsl:value-of select="."></xsl:value-of>
				</recordChangeDate>
			</xsl:for-each>
			<xsl:for-each select="marc:controlfield[@tag=001]">
				<recordIdentifier>
					<xsl:if test="../marc:controlfield[@tag=003]">
						<xsl:attribute name="source">
							<xsl:value-of select="../marc:controlfield[@tag=003]"></xsl:value-of>
						</xsl:attribute>
					</xsl:if>
					<xsl:value-of select="."></xsl:value-of>
				</recordIdentifier>
			</xsl:for-each>
			<xsl:for-each select="marc:datafield[@tag=040]/marc:subfield[@code='b']">
				<languageOfCataloging>
					<languageTerm authority="iso639-2b" type="code">
						<xsl:value-of select="."></xsl:value-of>
					</languageTerm>
				</languageOfCataloging>
			</xsl:for-each>
		</recordInfo>
	</xsl:template>
	<xsl:template name="displayForm">
		<xsl:for-each select="marc:subfield[@code='c']">
			<displayForm>
				<xsl:value-of select="."></xsl:value-of>
			</displayForm>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="affiliation">
		<xsl:for-each select="marc:subfield[@code='u']">
			<affiliation>
				<xsl:value-of select="."></xsl:value-of>
			</affiliation>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="uri">
		<xsl:for-each select="marc:subfield[@code='u']">
			<xsl:attribute name="xlink:href">
				<xsl:value-of select="."></xsl:value-of>
			</xsl:attribute>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='0']">
			<xsl:choose>
				<xsl:when test="contains(text(), ')')">
					<xsl:attribute name="xlink:href">
						<xsl:value-of select="substring-after(text(), ')')"></xsl:value-of>
					</xsl:attribute>
				</xsl:when>
				<xsl:otherwise>
					<xsl:attribute name="xlink:href">
						<xsl:value-of select="."></xsl:value-of>
					</xsl:attribute>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="role">
		<xsl:for-each select="marc:subfield[@code='e']">
			<role>
				<roleTerm type="text">
					<xsl:value-of select="."></xsl:value-of>
				</roleTerm>
			</role>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='4']">
			<role>
				<roleTerm authority="marcrelator" type="code">
					<xsl:value-of select="."></xsl:value-of>
				</roleTerm>
			</role>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="part">
		<xsl:variable name="partNumber">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">n</xsl:with-param>
				<xsl:with-param name="anyCodes">n</xsl:with-param>
				<xsl:with-param name="afterCodes">fgkdlmor</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:variable name="partName">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">p</xsl:with-param>
				<xsl:with-param name="anyCodes">p</xsl:with-param>
				<xsl:with-param name="afterCodes">fgkdlmor</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:if test="string-length(normalize-space($partNumber))">
			<partNumber>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="$partNumber"></xsl:with-param>
				</xsl:call-template>
			</partNumber>
		</xsl:if>
		<xsl:if test="string-length(normalize-space($partName))">
			<partName>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="$partName"></xsl:with-param>
				</xsl:call-template>
			</partName>
		</xsl:if>
	</xsl:template>
	<xsl:template name="relatedPart">
		<xsl:if test="@tag=773">
			<xsl:for-each select="marc:subfield[@code='g']">
				<part>
					<text>
						<xsl:value-of select="."></xsl:value-of>
					</text>
				</part>
			</xsl:for-each>
			<xsl:for-each select="marc:subfield[@code='q']">
				<part>
					<xsl:call-template name="parsePart"></xsl:call-template>
				</part>
			</xsl:for-each>
		</xsl:if>
	</xsl:template>
	<xsl:template name="relatedPartNumName">
		<xsl:variable name="partNumber">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">g</xsl:with-param>
				<xsl:with-param name="anyCodes">g</xsl:with-param>
				<xsl:with-param name="afterCodes">pst</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:variable name="partName">
			<xsl:call-template name="specialSubfieldSelect">
				<xsl:with-param name="axis">p</xsl:with-param>
				<xsl:with-param name="anyCodes">p</xsl:with-param>
				<xsl:with-param name="afterCodes">fgkdlmor</xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:if test="string-length(normalize-space($partNumber))">
			<partNumber>
				<xsl:value-of select="$partNumber"></xsl:value-of>
			</partNumber>
		</xsl:if>
		<xsl:if test="string-length(normalize-space($partName))">
			<partName>
				<xsl:value-of select="$partName"></xsl:value-of>
			</partName>
		</xsl:if>
	</xsl:template>
	<xsl:template name="relatedName">
		<xsl:for-each select="marc:subfield[@code='a']">
			<name>
				<namePart>
					<xsl:value-of select="."></xsl:value-of>
				</namePart>
			</name>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedForm">
		<xsl:for-each select="marc:subfield[@code='h']">
			<physicalDescription>
				<form>
					<xsl:value-of select="."></xsl:value-of>
				</form>
			</physicalDescription>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedExtent">
		<xsl:for-each select="marc:subfield[@code='h']">
			<physicalDescription>
				<extent>
					<xsl:value-of select="."></xsl:value-of>
				</extent>
			</physicalDescription>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedNote">
		<xsl:for-each select="marc:subfield[@code='n']">
			<note>
				<xsl:value-of select="."></xsl:value-of>
			</note>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedSubject">
		<xsl:for-each select="marc:subfield[@code='j']">
			<subject>
				<temporal encoding="iso8601">
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString" select="."></xsl:with-param>
					</xsl:call-template>
				</temporal>
			</subject>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedIdentifierISSN">
		<xsl:for-each select="marc:subfield[@code='x']">
			<identifier type="issn">
				<xsl:value-of select="."></xsl:value-of>
			</identifier>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedIdentifierLocal">
		<xsl:for-each select="marc:subfield[@code='w']">
			<identifier type="local">
				<xsl:value-of select="."></xsl:value-of>
			</identifier>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedIdentifier">
		<xsl:for-each select="marc:subfield[@code='o']">
			<identifier>
				<xsl:value-of select="."></xsl:value-of>
			</identifier>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedItem76X-78X">
		<xsl:call-template name="displayLabel"></xsl:call-template>
		<xsl:call-template name="relatedTitle76X-78X"></xsl:call-template>
		<xsl:call-template name="relatedName"></xsl:call-template>
		<xsl:call-template name="relatedOriginInfo"></xsl:call-template>
		<xsl:call-template name="relatedLanguage"></xsl:call-template>
		<xsl:call-template name="relatedExtent"></xsl:call-template>
		<xsl:call-template name="relatedNote"></xsl:call-template>
		<xsl:call-template name="relatedSubject"></xsl:call-template>
		<xsl:call-template name="relatedIdentifier"></xsl:call-template>
		<xsl:call-template name="relatedIdentifierISSN"></xsl:call-template>
		<xsl:call-template name="relatedIdentifierLocal"></xsl:call-template>
		<xsl:call-template name="relatedPart"></xsl:call-template>
	</xsl:template>
	<xsl:template name="subjectGeographicZ">
		<geographic>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString" select="."></xsl:with-param>
			</xsl:call-template>
		</geographic>
	</xsl:template>
	<xsl:template name="subjectTemporalY">
		<temporal>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString" select="."></xsl:with-param>
			</xsl:call-template>
		</temporal>
	</xsl:template>
	<xsl:template name="subjectTopic">
		<topic>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString" select="."></xsl:with-param>
			</xsl:call-template>
		</topic>
	</xsl:template>	
	<!-- 3.2 change tmee 6xx $v genre -->
	<xsl:template name="subjectGenre">
		<genre>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString" select="."></xsl:with-param>
			</xsl:call-template>
		</genre>
	</xsl:template>
	
	<xsl:template name="nameABCDN">
		<xsl:for-each select="marc:subfield[@code='a']">
			<namePart>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="."></xsl:with-param>
				</xsl:call-template>
			</namePart>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='b']">
			<namePart>
				<xsl:value-of select="."></xsl:value-of>
			</namePart>
		</xsl:for-each>
		<xsl:if test="marc:subfield[@code='c'] or marc:subfield[@code='d'] or marc:subfield[@code='n']">
			<namePart>
				<xsl:call-template name="subfieldSelect">
					<xsl:with-param name="codes">cdn</xsl:with-param>
				</xsl:call-template>
			</namePart>
		</xsl:if>
	</xsl:template>
	<xsl:template name="nameABCDQ">
		<namePart>
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString">
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">aq</xsl:with-param>
					</xsl:call-template>
				</xsl:with-param>
				<xsl:with-param name="punctuation">
					<xsl:text>:,;/ </xsl:text>
				</xsl:with-param>
			</xsl:call-template>
		</namePart>
		<xsl:call-template name="termsOfAddress"></xsl:call-template>
		<xsl:call-template name="nameDate"></xsl:call-template>
	</xsl:template>
	<xsl:template name="nameACDEQ">
		<namePart>
			<xsl:call-template name="subfieldSelect">
				<xsl:with-param name="codes">acdeq</xsl:with-param>
			</xsl:call-template>
		</namePart>
	</xsl:template>
	<xsl:template name="constituentOrRelatedType">
		<xsl:if test="@ind2=2">
			<xsl:attribute name="type">constituent</xsl:attribute>
		</xsl:if>
	</xsl:template>
	<xsl:template name="relatedTitle">
		<xsl:for-each select="marc:subfield[@code='t']">
			<titleInfo>
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="."></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</title>
			</titleInfo>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedTitle76X-78X">
		<xsl:for-each select="marc:subfield[@code='t']">
			<titleInfo>
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="."></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</title>
				<xsl:if test="marc:datafield[@tag!=773]and marc:subfield[@code='g']">
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</xsl:if>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='p']">
			<titleInfo type="abbreviated">
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="."></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</title>
				<xsl:if test="marc:datafield[@tag!=773]and marc:subfield[@code='g']">
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</xsl:if>
			</titleInfo>
		</xsl:for-each>
		<xsl:for-each select="marc:subfield[@code='s']">
			<titleInfo type="uniform">
				<title>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:value-of select="."></xsl:value-of>
						</xsl:with-param>
					</xsl:call-template>
				</title>
				<xsl:if test="marc:datafield[@tag!=773]and marc:subfield[@code='g']">
					<xsl:call-template name="relatedPartNumName"></xsl:call-template>
				</xsl:if>
			</titleInfo>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="relatedOriginInfo">
		<xsl:if test="marc:subfield[@code='b' or @code='d'] or marc:subfield[@code='f']">
			<originInfo>
				<xsl:if test="@tag=775">
					<xsl:for-each select="marc:subfield[@code='f']">
						<place>
							<placeTerm>
								<xsl:attribute name="type">code</xsl:attribute>
								<xsl:attribute name="authority">marcgac</xsl:attribute>
								<xsl:value-of select="."></xsl:value-of>
							</placeTerm>
						</place>
					</xsl:for-each>
				</xsl:if>
				<xsl:for-each select="marc:subfield[@code='d']">
					<publisher>
						<xsl:value-of select="."></xsl:value-of>
					</publisher>
				</xsl:for-each>
				<xsl:for-each select="marc:subfield[@code='b']">
					<edition>
						<xsl:value-of select="."></xsl:value-of>
					</edition>
				</xsl:for-each>
			</originInfo>
		</xsl:if>
	</xsl:template>
	<xsl:template name="relatedLanguage">
		<xsl:for-each select="marc:subfield[@code='e']">
			<xsl:call-template name="getLanguage">
				<xsl:with-param name="langString">
					<xsl:value-of select="."></xsl:value-of>
				</xsl:with-param>
			</xsl:call-template>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="nameDate">
		<xsl:for-each select="marc:subfield[@code='d']">
			<namePart type="date">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="."></xsl:with-param>
				</xsl:call-template>
			</namePart>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="subjectAuthority">
		<xsl:if test="@ind2!=4">
			<xsl:if test="@ind2!=' '">
				<xsl:if test="@ind2!=8">
					<xsl:if test="@ind2!=9">
						<xsl:attribute name="authority">
							<xsl:choose>
								<xsl:when test="@ind2=0">lcsh</xsl:when>
								<xsl:when test="@ind2=1">lcshac</xsl:when>
								<xsl:when test="@ind2=2">mesh</xsl:when>
								<!-- 1/04 fix -->
								<xsl:when test="@ind2=3">nal</xsl:when>
								<xsl:when test="@ind2=5">csh</xsl:when>
								<xsl:when test="@ind2=6">rvm</xsl:when>
								<xsl:when test="@ind2=7">
									<xsl:value-of select="marc:subfield[@code='2']"></xsl:value-of>
								</xsl:when>
							</xsl:choose>
						</xsl:attribute>
					</xsl:if>
				</xsl:if>
			</xsl:if>
		</xsl:if>
	</xsl:template>
	<xsl:template name="subjectAnyOrder">
		<xsl:for-each select="marc:subfield[@code='v' or @code='x' or @code='y' or @code='z']">
			<xsl:choose>
				<xsl:when test="@code='v'">
					<xsl:call-template name="subjectGenre"></xsl:call-template>
				</xsl:when>
				<xsl:when test="@code='x'">
					<xsl:call-template name="subjectTopic"></xsl:call-template>
				</xsl:when>
				<xsl:when test="@code='y'">
					<xsl:call-template name="subjectTemporalY"></xsl:call-template>
				</xsl:when>
				<xsl:when test="@code='z'">
					<xsl:call-template name="subjectGeographicZ"></xsl:call-template>
				</xsl:when>
			</xsl:choose>
		</xsl:for-each>
	</xsl:template>
	<xsl:template name="specialSubfieldSelect">
		<xsl:param name="anyCodes"></xsl:param>
		<xsl:param name="axis"></xsl:param>
		<xsl:param name="beforeCodes"></xsl:param>
		<xsl:param name="afterCodes"></xsl:param>
		<xsl:variable name="str">
			<xsl:for-each select="marc:subfield">
				<xsl:if test="contains($anyCodes, @code)      or (contains($beforeCodes,@code) and following-sibling::marc:subfield[@code=$axis])      or (contains($afterCodes,@code) and preceding-sibling::marc:subfield[@code=$axis])">
					<xsl:value-of select="text()"></xsl:value-of>
					<xsl:text> </xsl:text>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:value-of select="substring($str,1,string-length($str)-1)"></xsl:value-of>
	</xsl:template>
	
	<!-- 3.2 change tmee 6xx $v genre -->
	<xsl:template match="marc:datafield[@tag=600]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<name type="personal">
				<xsl:call-template name="uri" />
				<namePart>
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString">
							<xsl:call-template name="subfieldSelect">
								<xsl:with-param name="codes">aq</xsl:with-param>
							</xsl:call-template>
						</xsl:with-param>
					</xsl:call-template>
				</namePart>
				<xsl:call-template name="termsOfAddress"></xsl:call-template>
				<xsl:call-template name="nameDate"></xsl:call-template>
				<xsl:call-template name="affiliation"></xsl:call-template>
				<xsl:call-template name="role"></xsl:call-template>
			</name>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=610]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<name type="corporate">
				<xsl:call-template name="uri" />
				<xsl:for-each select="marc:subfield[@code='a']">
					<namePart>
						<xsl:value-of select="."></xsl:value-of>
					</namePart>
				</xsl:for-each>
				<xsl:for-each select="marc:subfield[@code='b']">
					<namePart>
						<xsl:value-of select="."></xsl:value-of>
					</namePart>
				</xsl:for-each>
				<xsl:if test="marc:subfield[@code='c' or @code='d' or @code='n' or @code='p']">
					<namePart>
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">cdnp</xsl:with-param>
						</xsl:call-template>
					</namePart>
				</xsl:if>
				<xsl:call-template name="role"></xsl:call-template>
			</name>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=611]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<name type="conference">
				<xsl:call-template name="uri" />
				<namePart>
					<xsl:call-template name="subfieldSelect">
						<xsl:with-param name="codes">abcdeqnp</xsl:with-param>
					</xsl:call-template>
				</namePart>
				<xsl:for-each select="marc:subfield[@code='4']">
					<role>
						<roleTerm authority="marcrelator" type="code">
							<xsl:value-of select="."></xsl:value-of>
						</roleTerm>
					</role>
				</xsl:for-each>
			</name>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=630]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<xsl:variable name="titleChop">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">adfhklor</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:variable>
			<titleInfo>
				<title>
					<xsl:value-of select="$titleChop" />
				</title>
				<xsl:call-template name="part"></xsl:call-template>
			</titleInfo>
			<titleInfo type="nfi">
				<xsl:choose>
					<xsl:when test="@ind1>0">
						<nonSort>
							<xsl:value-of select="substring($titleChop,1,@ind1)"/>
						</nonSort>
						<title>
							<xsl:value-of select="substring($titleChop,@ind1+1)"/>
						</title>
						<xsl:call-template name="part"/>
					</xsl:when>
					<xsl:otherwise>
						<title>
							<xsl:value-of select="$titleChop" />
						</title>
					</xsl:otherwise>
				</xsl:choose>
				<xsl:call-template name="part"></xsl:call-template>
			</titleInfo>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=650]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<topic>
				<xsl:call-template name="uri" />
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">abcd</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</topic>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=651]">
		<subject>
			<xsl:call-template name="subjectAuthority"></xsl:call-template>
			<xsl:for-each select="marc:subfield[@code='a']">
				<geographic>
					<xsl:call-template name="uri" />
					<xsl:call-template name="chopPunctuation">
						<xsl:with-param name="chopString" select="."></xsl:with-param>
					</xsl:call-template>
				</geographic>
			</xsl:for-each>
			<xsl:call-template name="subjectAnyOrder"></xsl:call-template>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=653]">
		<subject>
			<xsl:for-each select="marc:subfield[@code='a']">
				<topic>
					<xsl:call-template name="uri" />
					<xsl:value-of select="."></xsl:value-of>
				</topic>
			</xsl:for-each>
		</subject>
	</xsl:template>
	<xsl:template match="marc:datafield[@tag=656]">
		<subject>
			<xsl:if test="marc:subfield[@code=2]">
				<xsl:attribute name="authority">
					<xsl:value-of select="marc:subfield[@code=2]"></xsl:value-of>
				</xsl:attribute>
			</xsl:if>
			<occupation>
				<xsl:call-template name="uri" />
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:value-of select="marc:subfield[@code='a']"></xsl:value-of>
					</xsl:with-param>
				</xsl:call-template>
			</occupation>
		</subject>
	</xsl:template>
	<xsl:template name="termsOfAddress">
		<xsl:if test="marc:subfield[@code='b' or @code='c']">
			<namePart type="termsOfAddress">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">bc</xsl:with-param>
						</xsl:call-template>
					</xsl:with-param>
				</xsl:call-template>
			</namePart>
		</xsl:if>
	</xsl:template>
	<xsl:template name="displayLabel">
		<xsl:if test="marc:subfield[@code='i']">
			<xsl:attribute name="displayLabel">
				<xsl:value-of select="marc:subfield[@code='i']"></xsl:value-of>
			</xsl:attribute>
		</xsl:if>
		<xsl:if test="marc:subfield[@code='3']">
			<xsl:attribute name="displayLabel">
				<xsl:value-of select="marc:subfield[@code='3']"></xsl:value-of>
			</xsl:attribute>
		</xsl:if>
	</xsl:template>
	<xsl:template name="isInvalid">
		<xsl:param name="type"/>
		<xsl:if test="marc:subfield[@code='z'] or marc:subfield[@code='y']">
			<identifier>
				<xsl:attribute name="type">
					<xsl:value-of select="$type"/>
				</xsl:attribute>
				<xsl:attribute name="invalid">
					<xsl:text>yes</xsl:text>
				</xsl:attribute>
				<xsl:if test="marc:subfield[@code='z']">
					<xsl:value-of select="marc:subfield[@code='z']"/>
				</xsl:if>
				<xsl:if test="marc:subfield[@code='y']">
					<xsl:value-of select="marc:subfield[@code='y']"/>
				</xsl:if>
			</identifier>
		</xsl:if>
	</xsl:template>
	<xsl:template name="subtitle">
		<xsl:if test="marc:subfield[@code='b']">
			<subTitle>
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString">
						<xsl:value-of select="marc:subfield[@code='b']"/>
						<!--<xsl:call-template name="subfieldSelect">
							<xsl:with-param name="codes">b</xsl:with-param>									
						</xsl:call-template>-->
					</xsl:with-param>
				</xsl:call-template>
			</subTitle>
		</xsl:if>
	</xsl:template>
	<xsl:template name="script">
		<xsl:param name="scriptCode"></xsl:param>
		<xsl:attribute name="script">
			<xsl:choose>
				<xsl:when test="$scriptCode='(3'">Arabic</xsl:when>
				<xsl:when test="$scriptCode='(B'">Latin</xsl:when>
				<xsl:when test="$scriptCode='$1'">Chinese, Japanese, Korean</xsl:when>
				<xsl:when test="$scriptCode='(N'">Cyrillic</xsl:when>
				<xsl:when test="$scriptCode='(2'">Hebrew</xsl:when>
				<xsl:when test="$scriptCode='(S'">Greek</xsl:when>
			</xsl:choose>
		</xsl:attribute>
	</xsl:template>
	<xsl:template name="parsePart">
		<!-- assumes 773$q= 1:2:3<4
		     with up to 3 levels and one optional start page
		-->
		<xsl:variable name="level1">
			<xsl:choose>
				<xsl:when test="contains(text(),':')">
					<!-- 1:2 -->
					<xsl:value-of select="substring-before(text(),':')"></xsl:value-of>
				</xsl:when>
				<xsl:when test="not(contains(text(),':'))">
					<!-- 1 or 1<3 -->
					<xsl:if test="contains(text(),'&lt;')">
						<!-- 1<3 -->
						<xsl:value-of select="substring-before(text(),'&lt;')"></xsl:value-of>
					</xsl:if>
					<xsl:if test="not(contains(text(),'&lt;'))">
						<!-- 1 -->
						<xsl:value-of select="text()"></xsl:value-of>
					</xsl:if>
				</xsl:when>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="sici2">
			<xsl:choose>
				<xsl:when test="starts-with(substring-after(text(),$level1),':')">
					<xsl:value-of select="substring(substring-after(text(),$level1),2)"></xsl:value-of>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="substring-after(text(),$level1)"></xsl:value-of>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="level2">
			<xsl:choose>
				<xsl:when test="contains($sici2,':')">
					<!--  2:3<4  -->
					<xsl:value-of select="substring-before($sici2,':')"></xsl:value-of>
				</xsl:when>
				<xsl:when test="contains($sici2,'&lt;')">
					<!-- 1: 2<4 -->
					<xsl:value-of select="substring-before($sici2,'&lt;')"></xsl:value-of>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="$sici2"></xsl:value-of>
					<!-- 1:2 -->
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="sici3">
			<xsl:choose>
				<xsl:when test="starts-with(substring-after($sici2,$level2),':')">
					<xsl:value-of select="substring(substring-after($sici2,$level2),2)"></xsl:value-of>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="substring-after($sici2,$level2)"></xsl:value-of>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="level3">
			<xsl:choose>
				<xsl:when test="contains($sici3,'&lt;')">
					<!-- 2<4 -->
					<xsl:value-of select="substring-before($sici3,'&lt;')"></xsl:value-of>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="$sici3"></xsl:value-of>
					<!-- 3 -->
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="page">
			<xsl:if test="contains(text(),'&lt;')">
				<xsl:value-of select="substring-after(text(),'&lt;')"></xsl:value-of>
			</xsl:if>
		</xsl:variable>
		<xsl:if test="$level1">
			<detail level="1">
				<number>
					<xsl:value-of select="$level1"></xsl:value-of>
				</number>
			</detail>
		</xsl:if>
		<xsl:if test="$level2">
			<detail level="2">
				<number>
					<xsl:value-of select="$level2"></xsl:value-of>
				</number>
			</detail>
		</xsl:if>
		<xsl:if test="$level3">
			<detail level="3">
				<number>
					<xsl:value-of select="$level3"></xsl:value-of>
				</number>
			</detail>
		</xsl:if>
		<xsl:if test="$page">
			<extent unit="page">
				<start>
					<xsl:value-of select="$page"></xsl:value-of>
				</start>
			</extent>
		</xsl:if>
	</xsl:template>
	<xsl:template name="getLanguage">
		<xsl:param name="langString"></xsl:param>
		<xsl:param name="controlField008-35-37"></xsl:param>
		<xsl:variable name="length" select="string-length($langString)"></xsl:variable>
		<xsl:choose>
			<xsl:when test="$length=0"></xsl:when>
			<xsl:when test="$controlField008-35-37=substring($langString,1,3)">
				<xsl:call-template name="getLanguage">
					<xsl:with-param name="langString" select="substring($langString,4,$length)"></xsl:with-param>
					<xsl:with-param name="controlField008-35-37" select="$controlField008-35-37"></xsl:with-param>
				</xsl:call-template>
			</xsl:when>
			<xsl:otherwise>
				<language>
					<languageTerm authority="iso639-2b" type="code">
						<xsl:value-of select="substring($langString,1,3)"></xsl:value-of>
					</languageTerm>
				</language>
				<xsl:call-template name="getLanguage">
					<xsl:with-param name="langString" select="substring($langString,4,$length)"></xsl:with-param>
					<xsl:with-param name="controlField008-35-37" select="$controlField008-35-37"></xsl:with-param>
				</xsl:call-template>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	<xsl:template name="isoLanguage">
		<xsl:param name="currentLanguage"></xsl:param>
		<xsl:param name="usedLanguages"></xsl:param>
		<xsl:param name="remainingLanguages"></xsl:param>
		<xsl:choose>
			<xsl:when test="string-length($currentLanguage)=0"></xsl:when>
			<xsl:when test="not(contains($usedLanguages, $currentLanguage))">
				<language>
					<xsl:if test="@code!='a'">
						<xsl:attribute name="objectPart">
							<xsl:choose>
								<xsl:when test="@code='b'">summary or subtitle</xsl:when>
								<xsl:when test="@code='d'">sung or spoken text</xsl:when>
								<xsl:when test="@code='e'">libretto</xsl:when>
								<xsl:when test="@code='f'">table of contents</xsl:when>
								<xsl:when test="@code='g'">accompanying material</xsl:when>
								<xsl:when test="@code='h'">translation</xsl:when>
							</xsl:choose>
						</xsl:attribute>
					</xsl:if>
					<languageTerm authority="iso639-2b" type="code">
						<xsl:value-of select="$currentLanguage"></xsl:value-of>
					</languageTerm>
				</language>
				<xsl:call-template name="isoLanguage">
					<xsl:with-param name="currentLanguage">
						<xsl:value-of select="substring($remainingLanguages,1,3)"></xsl:value-of>
					</xsl:with-param>
					<xsl:with-param name="usedLanguages">
						<xsl:value-of select="concat($usedLanguages,$currentLanguage)"></xsl:value-of>
					</xsl:with-param>
					<xsl:with-param name="remainingLanguages">
						<xsl:value-of select="substring($remainingLanguages,4,string-length($remainingLanguages))"></xsl:value-of>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:when>
			<xsl:otherwise>
				<xsl:call-template name="isoLanguage">
					<xsl:with-param name="currentLanguage">
						<xsl:value-of select="substring($remainingLanguages,1,3)"></xsl:value-of>
					</xsl:with-param>
					<xsl:with-param name="usedLanguages">
						<xsl:value-of select="concat($usedLanguages,$currentLanguage)"></xsl:value-of>
					</xsl:with-param>
					<xsl:with-param name="remainingLanguages">
						<xsl:value-of select="substring($remainingLanguages,4,string-length($remainingLanguages))"></xsl:value-of>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	<xsl:template name="chopBrackets">
		<xsl:param name="chopString"></xsl:param>
		<xsl:variable name="string">
			<xsl:call-template name="chopPunctuation">
				<xsl:with-param name="chopString" select="$chopString"></xsl:with-param>
			</xsl:call-template>
		</xsl:variable>
		<xsl:if test="substring($string, 1,1)='['">
			<xsl:value-of select="substring($string,2, string-length($string)-2)"></xsl:value-of>
		</xsl:if>
		<xsl:if test="substring($string, 1,1)!='['">
			<xsl:value-of select="$string"></xsl:value-of>
		</xsl:if>
	</xsl:template>
	<xsl:template name="rfcLanguages">
		<xsl:param name="nodeNum"></xsl:param>
		<xsl:param name="usedLanguages"></xsl:param>
		<xsl:param name="controlField008-35-37"></xsl:param>
		<xsl:variable name="currentLanguage" select="."></xsl:variable>
		<xsl:choose>
			<xsl:when test="not($currentLanguage)"></xsl:when>
			<xsl:when test="$currentLanguage!=$controlField008-35-37 and $currentLanguage!='rfc3066'">
				<xsl:if test="not(contains($usedLanguages,$currentLanguage))">
					<language>
						<xsl:if test="@code!='a'">
							<xsl:attribute name="objectPart">
								<xsl:choose>
									<xsl:when test="@code='b'">summary or subtitle</xsl:when>
									<xsl:when test="@code='d'">sung or spoken text</xsl:when>
									<xsl:when test="@code='e'">libretto</xsl:when>
									<xsl:when test="@code='f'">table of contents</xsl:when>
									<xsl:when test="@code='g'">accompanying material</xsl:when>
									<xsl:when test="@code='h'">translation</xsl:when>
								</xsl:choose>
							</xsl:attribute>
						</xsl:if>
						<languageTerm authority="rfc3066" type="code">
							<xsl:value-of select="$currentLanguage"/>
						</languageTerm>
					</language>
				</xsl:if>
			</xsl:when>
			<xsl:otherwise>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	<xsl:template name="datafield">
		<xsl:param name="tag"/>
		<xsl:param name="ind1"><xsl:text> </xsl:text></xsl:param>
		<xsl:param name="ind2"><xsl:text> </xsl:text></xsl:param>
		<xsl:param name="subfields"/>
		<xsl:element name="marc:datafield">
			<xsl:attribute name="tag">
				<xsl:value-of select="$tag"/>
			</xsl:attribute>
			<xsl:attribute name="ind1">
				<xsl:value-of select="$ind1"/>
			</xsl:attribute>
			<xsl:attribute name="ind2">
				<xsl:value-of select="$ind2"/>
			</xsl:attribute>
			<xsl:copy-of select="$subfields"/>
		</xsl:element>
	</xsl:template>

	<xsl:template name="subfieldSelect">
		<xsl:param name="codes"/>
		<xsl:param name="delimeter"><xsl:text> </xsl:text></xsl:param>
		<xsl:variable name="str">
			<xsl:for-each select="marc:subfield">
				<xsl:if test="contains($codes, @code)">
					<xsl:value-of select="text()"/><xsl:value-of select="$delimeter"/>
				</xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:value-of select="substring($str,1,string-length($str)-string-length($delimeter))"/>
	</xsl:template>

	<xsl:template name="buildSpaces">
		<xsl:param name="spaces"/>
		<xsl:param name="char"><xsl:text> </xsl:text></xsl:param>
		<xsl:if test="$spaces>0">
			<xsl:value-of select="$char"/>
			<xsl:call-template name="buildSpaces">
				<xsl:with-param name="spaces" select="$spaces - 1"/>
				<xsl:with-param name="char" select="$char"/>
			</xsl:call-template>
		</xsl:if>
	</xsl:template>

	<xsl:template name="chopPunctuation">
		<xsl:param name="chopString"/>
		<xsl:param name="punctuation"><xsl:text>.:,;/ </xsl:text></xsl:param>
		<xsl:variable name="length" select="string-length($chopString)"/>
		<xsl:choose>
			<xsl:when test="$length=0"/>
			<xsl:when test="contains($punctuation, substring($chopString,$length,1))">
				<xsl:call-template name="chopPunctuation">
					<xsl:with-param name="chopString" select="substring($chopString,1,$length - 1)"/>
					<xsl:with-param name="punctuation" select="$punctuation"/>
				</xsl:call-template>
			</xsl:when>
			<xsl:when test="not($chopString)"/>
			<xsl:otherwise><xsl:value-of select="$chopString"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="chopPunctuationFront">
		<xsl:param name="chopString"/>
		<xsl:variable name="length" select="string-length($chopString)"/>
		<xsl:choose>
			<xsl:when test="$length=0"/>
			<xsl:when test="contains('.:,;/[ ', substring($chopString,1,1))">
				<xsl:call-template name="chopPunctuationFront">
					<xsl:with-param name="chopString" select="substring($chopString,2,$length - 1)"/>
				</xsl:call-template>
			</xsl:when>
			<xsl:when test="not($chopString)"/>
			<xsl:otherwise><xsl:value-of select="$chopString"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>
</xsl:stylesheet>$$ WHERE name = 'mods32' AND md5(xslt) = 'c69307123585414b4a98f9719fdd2a34';

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1490', :eg_version);

CREATE TYPE asset.holdable_part_count AS (id INT, label TEXT, holdable_count BIGINT);
CREATE OR REPLACE FUNCTION asset.count_holdable_parts_on_record (record_id BIGINT, pickup_lib INT DEFAULT NULL) RETURNS SETOF asset.holdable_part_count AS $func$
DECLARE 
    hard_boundary                   INT;
    orgs_within_hard_boundary       INT[];
BEGIN

    SELECT value INTO hard_boundary 
    FROM actor.org_unit_ancestor_setting('circ.hold_boundary.hard', pickup_lib)
    LIMIT 1;

    IF hard_boundary IS NOT NULL THEN
        SELECT ARRAY_AGG(id) INTO orgs_within_hard_boundary
        FROM actor.org_unit_descendants(pickup_lib, hard_boundary);
    END IF;

    RETURN QUERY 
    SELECT 
        bmp.id, 
        bmp.label, 
        COUNT(DISTINCT acp.id) AS holdable_count
    FROM asset.copy_part_map acpm
        JOIN biblio.monograph_part bmp ON acpm.part = bmp.id
        JOIN asset.copy acp ON acpm.target_copy = acp.id
        JOIN asset.call_number acn ON acp.call_number = acn.id
        JOIN biblio.record_entry bre ON acn.record = bre.id
        JOIN config.copy_status ccs ON acp.status = ccs.id
        JOIN asset.copy_location acpl ON acp.location = acpl.id
    WHERE
        NOT bmp.deleted
        AND (NOT acp.deleted AND acp.holdable)
        AND bre.id = record_id
        AND ccs.holdable
        AND acpl.holdable
        -- Check the circ_lib, but only when given a pickup lib for our hold AND we have hard boundary restrictions
        AND CASE WHEN orgs_within_hard_boundary IS NOT NULL THEN 
                acp.circ_lib = ANY(orgs_within_hard_boundary)
            ELSE TRUE 
            END
    GROUP BY 1, 2
    ORDER BY bmp.label_sortkey ASC;
END;
$func$ LANGUAGE plpgsql;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1491', :eg_version);

ALTER TABLE money.aged_payment ADD COLUMN refundable BOOL;

CREATE OR REPLACE VIEW money.payment_view AS
    SELECT  p.*,
            c.relname AS payment_type,
            COALESCE(f.enabled, TRUE) AS refundable
      FROM  money.payment p
            JOIN pg_class c ON (p.tableoid = c.oid)
            LEFT JOIN config.global_flag f ON ( f.name = p.tableoid::regclass||'.is_refundable');

CREATE OR REPLACE VIEW money.non_drawer_payment_view AS
    SELECT  p.*, c.relname AS payment_type, COALESCE(f.enabled, TRUE) AS refundable
      FROM  money.bnm_payment p
            JOIN pg_class c ON p.tableoid = c.oid
            LEFT JOIN config.global_flag f ON ( f.name = p.tableoid::regclass||'.is_refundable')
      WHERE c.relname NOT IN ('cash_payment','check_payment','credit_card_payment','debit_card_payment');

CREATE OR REPLACE VIEW money.cashdrawer_payment_view AS
    SELECT  ou.id AS org_unit,
        ws.id AS cashdrawer,
        t.payment_type AS payment_type,
        p.payment_ts AS payment_ts,
        p.amount AS amount,
        p.voided AS voided,
        p.note AS note,
        t.refundable AS refundable
      FROM  actor.org_unit ou
        JOIN actor.workstation ws ON (ou.id = ws.owning_lib)
        LEFT JOIN money.bnm_desk_payment p ON (ws.id = p.cash_drawer)
        LEFT JOIN money.payment_view t ON (p.id = t.id);

CREATE OR REPLACE VIEW money.desk_payment_view AS
    SELECT  p.*,c.relname AS payment_type,COALESCE(f.enabled, TRUE) AS refundable
      FROM  money.bnm_desk_payment p
        JOIN pg_class c ON (p.tableoid = c.oid)
        LEFT JOIN config.global_flag f ON ( f.name = p.tableoid::regclass||'.is_refundable');

CREATE OR REPLACE VIEW money.bnm_payment_view AS
    SELECT  p.*,c.relname AS payment_type,COALESCE(f.enabled, TRUE) AS refundable
      FROM  money.bnm_payment p
        JOIN pg_class c ON (p.tableoid = c.oid)
        LEFT JOIN config.global_flag f ON ( f.name = p.tableoid::regclass||'.is_refundable');

CREATE OR REPLACE VIEW money.payment_view_for_aging AS
    SELECT p.id,
        p.xact,
        p.payment_ts,
        p.voided,
        p.amount,
        p.note,
        p.payment_type,
        bnm.accepting_usr,
        bnmd.cash_drawer,
        maa.billing,
        p.refundable
    FROM money.payment_view p
    LEFT JOIN money.bnm_payment bnm ON bnm.id = p.id
    LEFT JOIN money.bnm_desk_payment bnmd ON bnmd.id = p.id
    LEFT JOIN money.account_adjustment maa ON maa.id = p.id;

CREATE OR REPLACE FUNCTION money.mbts_refundable_balance_check () RETURNS TRIGGER AS $$
BEGIN
    -- Check if the raw xact balance has gone negative (balance_owed may be adjusted by this very trigger!)
    IF NEW.total_owed - NEW.total_paid < 0.0 THEN

        -- If negative (a refund), we increase it by the non-refundable payment total, but only up to 0.0
        SELECT  LEAST(
                    COALESCE(SUM(amount),0.0) -- non-refundable payment total
                      + (NEW.total_owed - NEW.total_paid), -- raw balance
                    0.0
                ) INTO NEW.balance_owed -- update the NEW record
          FROM  money.payment_view
          WHERE NOT refundable
                AND xact = NEW.id
                AND NOT voided;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE PLPGSQL;

CREATE TRIGGER mat_summary_refund_balance_check_tgr BEFORE UPDATE ON money.materialized_billable_xact_summary FOR EACH ROW EXECUTE PROCEDURE money.mbts_refundable_balance_check ();

INSERT INTO config.global_flag (name, label, enabled) VALUES
( 'money.account_adjustment.is_refundable',
  oils_i18n_gettext( 'money.account_adjustment.is_refundable', 'Money: Enable to allow account adjustments to be refundable to patrons', 'cgf', 'label'),
  FALSE ),
( 'money.forgive_payment.is_refundable',
  oils_i18n_gettext( 'money.forgive_payment.is_refundable', 'Money: Enable to allow forgive payments to be refundable to patrons', 'cgf', 'label'),
  FALSE ),
( 'money.work_payment.is_refundable',
  oils_i18n_gettext( 'money.work_payment.is_refundable', 'Money: Enable to allow work payments to be refundable to patrons', 'cgf', 'label'),
  FALSE ),
( 'money.credit_payment.is_refundable',
  oils_i18n_gettext( 'money.credit_payment.is_refundable', 'Money: Enable to allow credit payments to be refundable to patrons', 'cgf', 'label'),
  FALSE ),
( 'money.goods_payment.is_refundable',
  oils_i18n_gettext( 'money.goods_payment.is_refundable', 'Money: Enable to allow goods payments to be refundable to patrons', 'cgf', 'label'),
  FALSE ),
( 'money.credit_card_payment.is_refundable',
  oils_i18n_gettext( 'money.credit_card_payment.is_refundable', 'Money: Enable to allow credit card payments to be refundable to patrons', 'cgf', 'label'),
  TRUE ),
( 'money.cash_payment.is_refundable',
  oils_i18n_gettext( 'money.cash_payment.is_refundable', 'Money: Enable to allow cash payments to be refundable to patrons', 'cgf', 'label'),
  TRUE ),
( 'money.check_payment.is_refundable',
  oils_i18n_gettext( 'money.check_payment.is_refundable', 'Money: Enable to allow check payments to be refundable to patrons', 'cgf', 'label'),
  TRUE ),
( 'money.debit_card_payment.is_refundable',
  oils_i18n_gettext( 'money.debit_card_payment.is_refundable', 'Money: Enable to allow debit card payments to be refundable to patrons', 'cgf', 'label'),
  TRUE )
;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1492', :eg_version);

CREATE OR REPLACE FUNCTION asset.merge_record_assets( target_record BIGINT, source_record BIGINT ) RETURNS INT AS $func$
DECLARE
    moved_objects INT := 0;
    source_cn     asset.call_number%ROWTYPE;
    target_cn     asset.call_number%ROWTYPE;
    metarec       metabib.metarecord%ROWTYPE;
    hold          action.hold_request%ROWTYPE;
    ser_rec       serial.record_entry%ROWTYPE;
    ser_sub       serial.subscription%ROWTYPE;
    acq_lineitem  acq.lineitem%ROWTYPE;
    acq_request   acq.user_request%ROWTYPE;
    booking       booking.resource_type%ROWTYPE;
    source_part   biblio.monograph_part%ROWTYPE;
    target_part   biblio.monograph_part%ROWTYPE;
    multi_home    biblio.peer_bib_copy_map%ROWTYPE;
    uri_count     INT := 0;
    counter       INT := 0;
    uri_datafield TEXT;
    uri_text      TEXT := '';
BEGIN

    -- we don't merge bib -1
    IF target_record = -1 OR source_record = -1 THEN
       RETURN 0;
    END IF;

    -- move any 856 entries on records that have at least one MARC-mapped URI entry
    SELECT  INTO uri_count COUNT(*)
      FROM  asset.uri_call_number_map m
            JOIN asset.call_number cn ON (m.call_number = cn.id)
      WHERE cn.record = source_record;

    IF uri_count > 0 THEN
        
        -- This returns more nodes than you might expect:
        -- 7 instead of 1 for an 856 with $u $y $9
        SELECT  COUNT(*) INTO counter
          FROM  oils_xpath_table(
                    'id',
                    'marc',
                    'biblio.record_entry',
                    '//*[@tag="856"]',
                    'id=' || source_record
                ) as t(i int,c text);
    
        FOR i IN 1 .. counter LOOP
            SELECT  '<datafield xmlns="http://www.loc.gov/MARC21/slim"' || 
			' tag="856"' ||
			' ind1="' || FIRST(ind1) || '"'  ||
			' ind2="' || FIRST(ind2) || '">' ||
                        STRING_AGG(
                            '<subfield code="' || subfield || '">' ||
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(data,'&','&amp;','g'),
                                    '>', '&gt;', 'g'
                                ),
                                '<', '&lt;', 'g'
                            ) || '</subfield>', ''
                        ) || '</datafield>' INTO uri_datafield
              FROM  oils_xpath_table(
                        'id',
                        'marc',
                        'biblio.record_entry',
                        '//*[@tag="856"][position()=' || i || ']/@ind1|' ||
                        '//*[@tag="856"][position()=' || i || ']/@ind2|' ||
                        '//*[@tag="856"][position()=' || i || ']/*/@code|' ||
                        '//*[@tag="856"][position()=' || i || ']/*[@code]',
                        'id=' || source_record
                    ) as t(id int,ind1 text, ind2 text,subfield text,data text);

            -- As most of the results will be NULL, protect against NULLifying
            -- the valid content that we do generate
            uri_text := uri_text || COALESCE(uri_datafield, '');
        END LOOP;

        IF uri_text <> '' THEN
            UPDATE  biblio.record_entry
              SET   marc = regexp_replace(marc,'(</[^>]*record>)', uri_text || E'\\1')
              WHERE id = target_record;
        END IF;

    END IF;

	-- Find and move metarecords to the target record
	SELECT	INTO metarec *
	  FROM	metabib.metarecord
	  WHERE	master_record = source_record;

	IF FOUND THEN
		UPDATE	metabib.metarecord
		  SET	master_record = target_record,
			mods = NULL
		  WHERE	id = metarec.id;

		moved_objects := moved_objects + 1;
	END IF;

	-- Find call numbers attached to the source ...
	FOR source_cn IN SELECT * FROM asset.call_number WHERE record = source_record LOOP

		SELECT	INTO target_cn *
		  FROM	asset.call_number
		  WHERE	label = source_cn.label
            AND prefix = source_cn.prefix
            AND suffix = source_cn.suffix
			AND owning_lib = source_cn.owning_lib
			AND record = target_record
			AND NOT deleted;

		-- ... and if there's a conflicting one on the target ...
		IF FOUND THEN

			-- ... move the copies to that, and ...
			UPDATE	asset.copy
			  SET	call_number = target_cn.id
			  WHERE	call_number = source_cn.id;

			-- ... move V holds to the move-target call number
			FOR hold IN SELECT * FROM action.hold_request WHERE target = source_cn.id AND hold_type = 'V' LOOP
		
				UPDATE	action.hold_request
				  SET	target = target_cn.id
				  WHERE	id = hold.id;
		
				moved_objects := moved_objects + 1;
			END LOOP;
        
            UPDATE asset.call_number SET deleted = TRUE WHERE id = source_cn.id;

		-- ... if not ...
		ELSE
			-- ... just move the call number to the target record
			UPDATE	asset.call_number
			  SET	record = target_record
			  WHERE	id = source_cn.id;
		END IF;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find T holds targeting the source record ...
	FOR hold IN SELECT * FROM action.hold_request WHERE target = source_record AND hold_type = 'T' LOOP

		-- ... and move them to the target record
		UPDATE	action.hold_request
		  SET	target = target_record
		  WHERE	id = hold.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find serial records targeting the source record ...
	FOR ser_rec IN SELECT * FROM serial.record_entry WHERE record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	serial.record_entry
		  SET	record = target_record
		  WHERE	id = ser_rec.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find serial subscriptions targeting the source record ...
	FOR ser_sub IN SELECT * FROM serial.subscription WHERE record_entry = source_record LOOP
		-- ... and move them to the target record
		UPDATE	serial.subscription
		  SET	record_entry = target_record
		  WHERE	id = ser_sub.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find booking resource types targeting the source record ...
	FOR booking IN SELECT * FROM booking.resource_type WHERE record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	booking.resource_type
		  SET	record = target_record
		  WHERE	id = booking.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find acq lineitems targeting the source record ...
	FOR acq_lineitem IN SELECT * FROM acq.lineitem WHERE eg_bib_id = source_record LOOP
		-- ... and move them to the target record
		UPDATE	acq.lineitem
		  SET	eg_bib_id = target_record
		  WHERE	id = acq_lineitem.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find acq user purchase requests targeting the source record ...
	FOR acq_request IN SELECT * FROM acq.user_request WHERE eg_bib = source_record LOOP
		-- ... and move them to the target record
		UPDATE	acq.user_request
		  SET	eg_bib = target_record
		  WHERE	id = acq_request.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find active parts attached to the source ...
	FOR source_part IN SELECT * FROM biblio.monograph_part WHERE record = source_record AND deleted = false LOOP

		SELECT	INTO target_part *
		  FROM	biblio.monograph_part
		  WHERE	label = source_part.label
			AND record = target_record
			AND NOT deleted;

		-- ... and if there's a conflicting one on the target ...
		IF FOUND THEN

			-- ... move the copy-part maps to that, and ...
			UPDATE	asset.copy_part_map
			  SET	part = target_part.id
			  WHERE	part = source_part.id;

			-- ... move P holds to the move-target part
			FOR hold IN SELECT * FROM action.hold_request WHERE target = source_part.id AND hold_type = 'P' LOOP
		
				UPDATE	action.hold_request
				  SET	target = target_part.id
				  WHERE	id = hold.id;
		
				moved_objects := moved_objects + 1;
			END LOOP;

		-- ... if not ...
		ELSE
			-- ... just move the part to the target record
			UPDATE	biblio.monograph_part
			  SET	record = target_record
			  WHERE	id = source_part.id;
		END IF;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find multi_home items attached to the source ...
	FOR multi_home IN SELECT * FROM biblio.peer_bib_copy_map WHERE peer_record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	biblio.peer_bib_copy_map
		  SET	peer_record = target_record
		  WHERE	id = multi_home.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- And delete mappings where the item's home bib was merged with the peer bib
	DELETE FROM biblio.peer_bib_copy_map WHERE peer_record = (
		SELECT (SELECT record FROM asset.call_number WHERE id = call_number)
		FROM asset.copy WHERE id = target_copy
	);

    -- Apply merge tracking
    UPDATE biblio.record_entry 
        SET merge_date = NOW() WHERE id = target_record;

    UPDATE biblio.record_entry
        SET merge_date = NOW(), merged_to = target_record
        WHERE id = source_record;

    -- replace book bag entries of source_record with target_record
    UPDATE container.biblio_record_entry_bucket_item
        SET target_biblio_record_entry = target_record
        WHERE bucket IN (SELECT id FROM container.biblio_record_entry_bucket WHERE btype = 'bookbag')
        AND target_biblio_record_entry = source_record;

    -- move over record notes 
    UPDATE biblio.record_note 
        SET record = target_record, value = CONCAT(value,'; note merged from ',source_record::TEXT) 
        WHERE record = source_record
        AND NOT deleted;

    -- add note to record merge 
    INSERT INTO biblio.record_note (record, value) 
        VALUES (target_record,CONCAT('record ',source_record::TEXT,' merged on ',NOW()::TEXT));

    -- Finally, "delete" the source record
    UPDATE biblio.record_entry SET active = FALSE WHERE id = source_record;
    DELETE FROM biblio.record_entry WHERE id = source_record;

	-- That's all, folks!
	RETURN moved_objects;
END;
$func$ LANGUAGE plpgsql;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1493', :eg_version);
ALTER TABLE actor.org_lasso ADD COLUMN IF NOT EXISTS opac_visible BOOL NOT NULL DEFAULT TRUE;

COMMIT;
BEGIN;

-- Bootstrap KPAC Configuration Interface

SELECT evergreen.upgrade_deps_block_check('1494', :eg_version);

CREATE TABLE config.kpac_content_types (
    id              SERIAL PRIMARY KEY,
    name            TEXT NOT NULL
);

INSERT INTO config.kpac_content_types
    (id, name)
VALUES
    (1, 'Category'),
    (2, 'Book List'),
    (3, 'URL'),
    (4, 'Search String')
; 

CREATE TABLE config.kpac_topics (
    id              SERIAL PRIMARY KEY,
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    parent          INTEGER, -- empty is home / top level entry
    img             TEXT, -- image file name
    name            TEXT NOT NULL,
    description     TEXT,
    content_type    INTEGER NOT NULL REFERENCES config.kpac_content_types (id),
    content_list    INTEGER, -- bookbag id
    content_link    TEXT, -- url
    content_search  TEXT, -- preset search string
    topic_order     INTEGER
);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
   'eg.grid.admin.server.config.kpac_topics', 'gui', 'object',
   oils_i18n_gettext(
       'eg.grid.admin.server.config.kpac_topics',
       'Grid Config: KPAC topics',
       'cwst', 'label')
);

INSERT into config.org_unit_setting_type
	(name, grp, label, description, datatype)
VALUES (
	'opac.show_kpac_link',
	'opac',
	oils_i18n_gettext('opac.show_kpac_link',
    	'Show KPAC Link',
    	'coust', 'label'),
	oils_i18n_gettext('opac.show_kpac_link',
    	'Show the KPAC link in the OPAC. Default is false.',
    	'coust', 'description'),
	'bool'
);

INSERT into permission.perm_list
    (code, description)
VALUES (
    'KPAC_ADMIN',
    'Allow user to configure KPAC category and topic entries'
);

INSERT into config.org_unit_setting_type
	(name, grp, label, description, datatype)
VALUES (
	'opac.kpac_audn_filter',
	'opac',
    oils_i18n_gettext('opac.kpac_audn_filter',
        'KPAC Audience Filter',
        'coust', 'label'),
	oils_i18n_gettext('opac.kpac_audn_filter',
        'Controls which items to display based on MARC Target Audience (Audn) field. Options are: a,b,c,d,j. Default is: a,b,c,j',
        'coust', 'description'),
	'string'
);


COMMIT;


BEGIN;

SELECT evergreen.upgrade_deps_block_check('1495', :eg_version);

-- NOTE: Perm 627 is SSO_ADMIN
INSERT INTO config.org_unit_setting_type
( name, grp, label, description, datatype, update_perm )
VALUES
('staff.login.shib_sso.enable',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.enable', 'Enable Shibboleth SSO for the Staff Client', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.enable', 'Enable Shibboleth SSO for the Staff Client', 'coust', 'description'),
 'bool', 627),
('staff.login.shib_sso.entityId',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.entityId', 'Shibboleth Staff SSO Entity ID', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.entityId', 'Which configured Entity ID to use for SSO when there is more than one available to Shibboleth', 'coust', 'description'),
 'string', 627),
('staff.login.shib_sso.logout',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.logout', 'Log out of the Staff Shibboleth IdP', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.logout', 'When logging out of Evergreen, also force a logout of the IdP behind Shibboleth', 'coust', 'description'),
 'bool', 627),
('staff.login.shib_sso.allow_native',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.allow_native', 'Allow both Shibboleth and native Staff Client authentication', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.allow_native', 'When Shibboleth SSO is enabled, also allow native Evergreen authentication', 'coust', 'description'),
 'bool', 627),
('staff.login.shib_sso.evergreen_matchpoint',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.evergreen_matchpoint', 'Evergreen Staff SSO matchpoint', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.evergreen_matchpoint',
  'Evergreen-side field to match a patron against for Shibboleth SSO. Default is usrname.  Other reasonable values would be barcode or email.',
  'coust', 'description'),
 'string', 627),
('staff.login.shib_sso.shib_matchpoint',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.shib_matchpoint', 'Shibboleth Staff SSO matchpoint', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.shib_matchpoint',
  'Shibboleth-side field to match a patron against for Shibboleth SSO. Default is uid; use eppn for Active Directory', 'coust', 'description'),
 'string', 627),
 ('staff.login.shib_sso.shib_path',
 'sec',
 oils_i18n_gettext('staff.login.shib_sso.shib_path', 'Specific Shibboleth Application path. Default /Shibboleth.sso', 'coust', 'label'),
 oils_i18n_gettext('staff.login.shib_sso.shib_path', 'Specific Shibboleth Application path. Default /Shibboleth.sso', 'coust', 'description'),
 'string', 627)
;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1496', :eg_version);

ALTER TABLE actor.org_unit
	ADD COLUMN staff_catalog_visible BOOLEAN NOT NULL DEFAULT TRUE;

UPDATE actor.org_unit
    SET staff_catalog_visible=opac_visible;

CREATE OR REPLACE FUNCTION asset.staff_ou_record_copy_count(org integer, rid bigint)
 RETURNS TABLE(depth integer, org_unit integer, visible bigint, available bigint, unshadow bigint, transcendant integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    ans RECORD;
    trans INT;
BEGIN
    SELECT 1 INTO trans FROM biblio.record_entry b JOIN config.bib_source src ON (b.source = src.id) WHERE src.transcendant AND b.id = rid;

    FOR ans IN SELECT u.id, t.depth FROM actor.org_unit_ancestors(org) AS u JOIN actor.org_unit_type t ON (u.ou_type = t.id) WHERE staff_catalog_visible LOOP
        RETURN QUERY
        WITH available_statuses AS (SELECT ARRAY_AGG(id) AS ids FROM config.copy_status WHERE is_available),
            cp AS(
                SELECT  cp.id,
                        (cp.status = ANY (available_statuses.ids))::INT as available,
                        (cl.opac_visible AND cp.opac_visible)::INT as opac_visible
                  FROM
                        available_statuses,
                        actor.org_unit_descendants(ans.id) d
                        JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
                        JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
                        JOIN asset.call_number cn ON (cn.record = rid AND cn.id = cp.call_number AND NOT cn.deleted)
            ),
            peer AS (
                select  cp.id,
                        (cp.status = ANY  (available_statuses.ids))::INT as available,
                        (cl.opac_visible AND cp.opac_visible)::INT as opac_visible
                FROM
                        available_statuses,
                        actor.org_unit_descendants(ans.id) d
                        JOIN asset.copy cp ON (cp.circ_lib = d.id AND NOT cp.deleted)
                        JOIN asset.copy_location cl ON (cp.location = cl.id AND NOT cl.deleted)
                        JOIN biblio.peer_bib_copy_map bp ON (bp.peer_record = rid AND bp.target_copy = cp.id)
            )
        select ans.depth, ans.id, count(id), sum(x.available::int), sum(x.opac_visible::int), trans
        from ((select * from cp) union (select * from peer)) x
        group by 1,2,6;

        IF NOT FOUND THEN
            RETURN QUERY SELECT ans.depth, ans.id, 0::BIGINT, 0::BIGINT, 0::BIGINT, trans;
        END IF;

    END LOOP;
    RETURN;
END;
$function$;


INSERT INTO config.global_flag (name, enabled, label)
    VALUES (
        'staff.search.shelving_location_groups_with_orgs', TRUE,
        oils_i18n_gettext(
            'staff.search.shelving_location_groups_with_orgs',
            'Staff Catalog Search: Display shelving location groups inside the Organizational Unit Selector',
            'cgf',
            'label'
        )
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1497', :eg_version); -- berick/csharp/Dyrcona/phasefx

-- Thank you, berick :-)
-- Start at 100 to avoid barcodes with long stretches of zeros early on.
-- eCard barcodes have 7 auto-generated digits.
CREATE SEQUENCE actor.auto_barcode_ecard_seq START 100 MAXVALUE 9999999;

CREATE OR REPLACE FUNCTION actor.generate_barcode
    (prefix TEXT, numchars INTEGER, seqname TEXT) RETURNS TEXT AS
$$
    SELECT NEXTVAL($3); -- bump the sequence up 1
    SELECT CASE
        WHEN LENGTH(CURRVAL($3)::TEXT) > $2 THEN NULL
        ELSE $1 || LPAD(CURRVAL($3)::TEXT, $2, '0')
    END;
$$ LANGUAGE SQL;

COMMENT ON FUNCTION actor.generate_barcode(TEXT, INTEGER, TEXT) IS $$
Generate a barcode starting with 'prefix' and followed by 'numchars'
numbers.  The auto portion numbers are generated from the provided
sequence, guaranteeing uniquness across all barcodes generated with
the same sequence.  The number is left-padded with zeros to meet the
numchars size requirement.  Returns NULL if the sequnce value is
higher than numchars can accommodate.
$$;

CREATE OR REPLACE FUNCTION evergreen.json_delta(old_obj JSON, new_obj JSON, only_keys TEXT[] DEFAULT '{}') RETURNS JSONB AS $f$
use JSON;
use List::Util qw/uniq/;

my $old = shift;
my $new = shift;
my $keylist = shift;

$old = from_json($old) if (!ref($old));
$new = from_json($new) if (!ref($new));

my $delta = {};

my @keys = @$keylist;
@keys = (keys(%$old), keys(%$new)) if (!@keys);

for my $key (uniq @keys) {
    $$delta{$key} = [$$old{$key},$$new{$key}] if ((
        ((!exists($$old{$key}) or !exists($$new{$key})) and not (!exists($$old{$key}) and !exists($$new{$key}))) # one exists
        or ((!defined($$old{$key}) or !defined($$new{$key})) and not (!defined($$old{$key}) and !defined($$new{$key}))) # or one is defined
        or ((defined($$old{$key}) and defined($$new{$key})) and $$old{$key} ne $$new{$key}) # or they do not match
    ) and grep {defined} $$old{$key},$$new{$key}); # there is data
}

return to_json($delta);
$f$ LANGUAGE PLPERLU;

CREATE TABLE actor.usr_delta_history (
    id          BIGSERIAL   PRIMARY KEY,
    eg_user     INT         REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE SET NULL,
    eg_ws       INT         REFERENCES actor.workstation (id) ON UPDATE CASCADE ON DELETE SET NULL,
    usr_id      INT         NOT NULL REFERENCES actor.usr (id) ON UPDATE CASCADE ON DELETE CASCADE,
    change_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delta       JSONB       NOT NULL,
    keylist     TEXT[]
);

CREATE OR REPLACE FUNCTION actor.record_usr_delta() RETURNS TRIGGER AS $f$
BEGIN
    INSERT INTO actor.usr_delta_history (eg_user, eg_ws, usr_id, delta, keylist)
        SELECT  a.eg_user,
                a.eg_ws,
                OLD.id,
                evergreen.json_delta(to_json(OLD.*), to_json(NEW.*), TG_ARGV),
                TG_ARGV
          FROM  auditor.get_audit_info() a;
    RETURN NEW;
END;
$f$ LANGUAGE PLPGSQL;

CREATE TRIGGER record_usr_delta
    AFTER UPDATE ON actor.usr
    FOR EACH ROW
    EXECUTE FUNCTION actor.record_usr_delta(last_update_time /* unquoted, literal comma-separated column names to include in the delta */);
ALTER TABLE actor.usr DISABLE TRIGGER record_usr_delta;
ALTER TABLE permission.grp_tree ADD COLUMN erenew BOOL NOT NULL DEFAULT FALSE;
ALTER TABLE permission.grp_tree ADD COLUMN temporary_perm_interval INTERVAL;
ALTER TABLE actor.usr ADD COLUMN guardian_email TEXT;

SELECT auditor.update_auditors(); 

-- for guardian_email
CREATE OR REPLACE FUNCTION actor.usr_delete(
	src_usr  IN INTEGER,
	dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	old_profile actor.usr.profile%type;
	old_home_ou actor.usr.home_ou%type;
	new_profile actor.usr.profile%type;
	new_home_ou actor.usr.home_ou%type;
	new_name    text;
	new_dob     actor.usr.dob%type;
BEGIN
	SELECT
		id || '-PURGED-' || now(),
		profile,
		home_ou,
		dob
	INTO
		new_name,
		old_profile,
		old_home_ou,
		new_dob
	FROM
		actor.usr
	WHERE
		id = src_usr;
	--
	-- Quit if no such user
	--
	IF old_profile IS NULL THEN
		RETURN;
	END IF;
	--
	perform actor.usr_purge_data( src_usr, dest_usr );
	--
	-- Find the root grp_tree and the root org_unit.  This would be simpler if we 
	-- could assume that there is only one root.  Theoretically, someday, maybe,
	-- there could be multiple roots, so we take extra trouble to get the right ones.
	--
	SELECT
		id
	INTO
		new_profile
	FROM
		permission.grp_ancestors( old_profile )
	WHERE
		parent is null;
	--
	SELECT
		id
	INTO
		new_home_ou
	FROM
		actor.org_unit_ancestors( old_home_ou )
	WHERE
		parent_ou is null;
	--
	-- Truncate date of birth
	--
	IF new_dob IS NOT NULL THEN
		new_dob := date_trunc( 'year', new_dob );
	END IF;
	--
	UPDATE
		actor.usr
		SET
			card = NULL,
			profile = new_profile,
			usrname = new_name,
			email = NULL,
			passwd = random()::text,
			standing = DEFAULT,
			ident_type = 
			(
				SELECT MIN( id )
				FROM config.identification_type
			),
			ident_value = NULL,
			ident_type2 = NULL,
			ident_value2 = NULL,
			net_access_level = DEFAULT,
			photo_url = NULL,
			prefix = NULL,
			first_given_name = new_name,
			second_given_name = NULL,
			family_name = new_name,
			suffix = NULL,
			alias = NULL,
			guardian = NULL,
			guardian_email = NULL,
			day_phone = NULL,
			evening_phone = NULL,
			other_phone = NULL,
			mailing_address = NULL,
			billing_address = NULL,
			home_ou = new_home_ou,
			dob = new_dob,
			active = FALSE,
			master_account = DEFAULT, 
			super_user = DEFAULT,
			barred = FALSE,
			deleted = TRUE,
			juvenile = DEFAULT,
			usrgroup = 0,
			claims_returned_count = DEFAULT,
			credit_forward_balance = DEFAULT,
			last_xact_id = DEFAULT,
			pref_prefix = NULL,
			pref_first_given_name = NULL,
			pref_second_given_name = NULL,
			pref_family_name = NULL,
			pref_suffix = NULL,
			name_keywords = NULL,
			create_date = now(),
			expire_date = now()
	WHERE
		id = src_usr;
END;
$$ LANGUAGE plpgsql;

---

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1498', :eg_version); -- berick/csharp/Dyrcona/phasefx

INSERT INTO actor.passwd_type
    (code, name, login, crypt_algo, iter_count)
    VALUES ('ecard_vendor', 'eCard Vendor Password', FALSE, 'bf', 10);

-- Example linking a SIP password to the 'admin' account.
-- SELECT actor.set_passwd(1, 'ecard_vendor', 'ecard_password');

INSERT INTO config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class )
VALUES
( 'opac.ecard_registration_enabled', 'opac',
    oils_i18n_gettext('opac.ecard_registration_enabled',
        'Enable eCard registration feature in the OPAC',
        'coust', 'label'),
    oils_i18n_gettext('opac.ecard_registration_enabled',
        'Enable access to the eCard registration form in the OPAC',
        'coust', 'description'),
    'bool', null)
,( 'opac.ecard_verification_enabled', 'opac',
    oils_i18n_gettext('opac.ecard_verification_enabled',
        'Enable eCard verification feature in the OPAC',
        'coust', 'label'),
    oils_i18n_gettext('opac.ecard_verification_enabled',
        'Enable access to the eCard verification form in the OPAC',
        'coust', 'description'),
    'bool', null)
,( 'opac.ecard_renewal_enabled', 'opac',
    oils_i18n_gettext('opac.ecard_renewal_enabled',
        'Enable eCard request renewal feature in the OPAC',
        'coust', 'label'),
    oils_i18n_gettext('opac.ecard_renewal_enabled',
        'Enable access to the eCard request renewal form in the OPAC',
        'coust', 'description'),
    'bool', null)
,( 'opac.ecard_renewal_offer_interval', 'opac',
    oils_i18n_gettext('opac.ecard_renewal_offer_interval',
        'Number of days before account expiration in which to offer an e-renewal.',
        'coust', 'label'),
    oils_i18n_gettext('opac.ecard_renewal_offer_interval',
        'Number of days before account expiration in which to offer an e-renewal.',
        'coust', 'description'),
    'interval', null)
,( 'vendor.quipu.ecard.account_id', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.account_id',
        'Quipu eCard Customer Account',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.account_id',
        'Quipu Customer Account ID to be used for eCard registration',
        'coust', 'description'),
    'integer', null)
,( 'vendor.quipu.ecard.hostname', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.hostname',
        'Quipu eCard/eRenew Fully Qualified Domain Name',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.hostname',
        'Quipu ecard/eRenew Fully Qualified Domain Name is the external hostname for the Quipu server. Defaults to ecard.quipugroup.net',
        'coust', 'description'),
    'string', null)
,( 'vendor.quipu.ecard.shared_secret', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.shared_secret',
        'Quipu eCard Shared Secret',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.shared_secret',
        'Quipu Customer Account shared secret to be used for eCard authentication',
        'coust', 'description'),
    'string', null)
,( 'vendor.quipu.ecard.barcode_prefix', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.barcode_prefix',
        'Barcode prefix for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.barcode_prefix',
        'Set the barcode prefix for new Quipu eCard users',
        'coust', 'description'),
    'string', null)
,( 'vendor.quipu.ecard.barcode_length', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.barcode_length',
        'Barcode length for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.barcode_length',
        'Set the barcode length for new Quipu eCard users',
        'coust', 'description'),
    'integer', null)
,( 'vendor.quipu.ecard.calculate_checkdigit', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.calculate_checkdigit',
        'Calculate barcode checkdigit for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.calculate_checkdigit',
        'Calculate the barcode check digit for new Quipu eCard users',
        'coust', 'description'),
    'bool', null)
,( 'vendor.quipu.ecard.patron_profile', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.patron_profile',
        'Patron permission profile for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.patron_profile',
        'Patron permission profile for Quipu eCard feature',
        'coust', 'description'),
    'link', 'pgt')
,( 'vendor.quipu.ecard.patron_profile.verified', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.patron_profile.verified',
        'Patron permission profile after verification for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.patron_profile.verified',
        'Patron permission profile after verification for Quipu eCard feature. This is only used if the setting "Enable eCard verification feature in the OPAC" is active.',
        'coust', 'description'),
    'link', 'pgt')
,( 'vendor.quipu.ecard.admin_usrname', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.admin_usrname',
        'Evergreen Admin Username for the Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.admin_usrname',
        'Username of the Evergreen admin account that will create new Quipu eCard users',
        'coust', 'description'),
    'string', null)
,( 'vendor.quipu.ecard.admin_org_unit', 'lib',
    oils_i18n_gettext('vendor.quipu.ecard.admin_org_unit',
        'Admin organizational unit for Quipu eCard feature',
        'coust', 'label'),
    oils_i18n_gettext('vendor.quipu.ecard.admin_org_unit',
        'Organizational unit used by the Evergreen admin user of the Quipu eCard feature',
        'coust', 'description'),
    'link', 'aou')
;

-- A/T seed data
INSERT into action_trigger.hook (key, core_type, description) VALUES
( 'au.create.ecard', 'au', 'A patron has been created via Ecard');

INSERT INTO action_trigger.event_definition (active, owner, name, hook, validator, reactor, delay, template)
VALUES (
    'f', 1, 'Send Ecard Verification Email', 'au.create.ecard', 'NOOP_True', 'SendEmail', '00:00:00',
$$
[%- USE date -%]
[%- user = target -%]
[%- lib = target.home_ou -%]
To: [%- params.recipient_email || user_data.email || user_data.0.email || user.email %]
From: [%- helpers.get_org_setting(target.home_ou.id, 'org.bounced_emails') || lib.email || params.sender_email || default_sender %]
Date: [%- date.format(date.now, '%a, %d %b %Y %T -0000', gmt => 1) %]
Reply-To: [%- lib.email || params.sender_email || default_sender %]
Subject: Your Library Ecard Verification Code
Auto-Submitted: auto-generated

Dear [% user.first_given_name %] [% user.family_name %],

We will never call to ask you for this code, and make sure you do not share it with anyone calling you directly.

Use this code to verify the Ecard registration for your Evergreen account:

One-Time code: [% user.ident_value2 %]

Sincerely,
[% lib.name %]

Contact your library for more information:

[% lib.name %]
[%- SET addr = lib.mailing_address -%]
[%- IF !addr -%] [%- SET addr = lib.billing_address -%] [%- END %]
[% addr.street1 %] [% addr.street2 %]
[% addr.city %], [% addr.state %]
[% addr.post_code %]
[% lib.phone %]
$$);

INSERT INTO action_trigger.environment (event_def, path)
VALUES (currval('action_trigger.event_definition_id_seq'), 'home_ou'),
       (currval('action_trigger.event_definition_id_seq'), 'home_ou.mailing_address'),
       (currval('action_trigger.event_definition_id_seq'), 'home_ou.billing_address');

-- ID has to be under 100 in order to prevent it from appearing as a dropdown in the patron editor.
INSERT INTO config.standing_penalty (id, name, label, staff_alert, org_depth) 
VALUES (90, 'PATRON_TEMP_RENEWAL',
	'Patron was given a temporary account renewal. 
	Please archive this message after the account is fully renewed.', TRUE, 0
	);

INSERT into config.org_unit_setting_type (name, label, description, datatype) 
VALUES ( 
    'ui.patron.edit.au.guardian_email.show',
    oils_i18n_gettext(
        'ui.patron.edit.au.guardian_email.show', 
        'GUI: Show guardian email field on patron registration', 
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'ui.patron.edit.au.guardian_email.show', 
        'The guardian email field will be shown on the patron registration screen. Showing a field makes it appear with required fields even when not required. If the field is required this setting is ignored.', 
        'coust', 'description'
    ),
    'bool'
), (
    'ui.patron.edit.au.guardian_email.suggest',
    oils_i18n_gettext(
        'ui.patron.edit.au.guardian_email.suggest', 
        'GUI: Suggest guardian email field on patron registration', 
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'ui.patron.edit.au.guardian_email.suggest', 
        'The guardian email field will be suggested on the patron registration screen. Suggesting a field makes it appear when suggested fields are shown. If the field is shown or required this setting is ignored.', 
        'coust', 'description'),
    'bool'
);

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1499', :eg_version);

CREATE OR REPLACE FUNCTION metabib.disable_browse_entry_reification () RETURNS VOID AS $f$
    INSERT INTO config.internal_flag (name,enabled)
      VALUES ('ingest.disable_browse_entry_reification',TRUE)
    ON CONFLICT (name) DO UPDATE SET enabled = TRUE;
$f$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION metabib.enable_browse_entry_reification () RETURNS VOID AS $f$
    UPDATE config.internal_flag SET enabled = FALSE WHERE name = 'ingest.disable_browse_entry_reification';
$f$ LANGUAGE SQL;


-- INSERT-only table that catches browse entry updates to be reconciled
CREATE UNLOGGED TABLE metabib.browse_entry_updates (
    transaction_id  BIGINT,
    simple_heading  BIGINT,
    source          BIGINT,
    authority       BIGINT,
    def             INT,
    sort_value      TEXT,
    value           TEXT
);
CREATE INDEX browse_entry_updates_tid_idx ON metabib.browse_entry_updates (transaction_id);

CREATE OR REPLACE FUNCTION metabib.browse_entry_reify (full_reify BOOLEAN DEFAULT FALSE) RETURNS INT AS $f$
  WITH new_authority_rows AS ( -- gather provisional authority browse entries
      DELETE FROM metabib.browse_entry_updates
        WHERE simple_heading IS NOT NULL AND (full_reify OR transaction_id = txid_current())
        RETURNING sort_value, value, simple_heading
  ), new_bib_rows AS ( -- gather provisional bib browse entries
      DELETE FROM metabib.browse_entry_updates
        WHERE def IS NOT NULL AND (full_reify OR transaction_id = txid_current())
        RETURNING sort_value, value, def, source, authority
  ), computed_browse_values AS ( -- unique set of to-be-mapped sort_value/value pairs :: sort_value, value, def, cmf.browse_nocase
      SELECT  nbr.sort_value, nbr.value, nbr.def, cmf.browse_nocase
        FROM  new_bib_rows AS nbr JOIN config.metabib_field AS cmf ON (nbr.def = cmf.id)
          UNION
      SELECT  sort_value, value, NULL::INT AS def, FALSE AS browse_nocase
        FROM new_authority_rows
  ), existing_browse_entries AS ( -- find the id of existing sort_value/value pairs, nocase'd if cmf says so :: id, sort_value, value, def (NULL for authority)
      SELECT  mbe.id, cr.sort_value, cr.value, cr.def
        FROM  metabib.browse_entry mbe
              JOIN computed_browse_values cr ON (
                  mbe.sort_value = cr.sort_value
                  AND (
                    (cr.browse_nocase AND evergreen.lowercase(mbe.value) = evergreen.lowercase(cr.value))
                    OR (NOT cr.browse_nocase AND mbe.value = cr.value)
                  )
              )
  ), missing_browse_entries AS ( -- unique set of sort_value/value pairs NOT in the browse_entry table
      SELECT DISTINCT sort_value, value FROM computed_browse_values
          EXCEPT
      SELECT sort_value, value FROM existing_browse_entries
  ), inserted_browse_entries AS ( -- insert missing sort_value/value pairs and get the new id for each
      INSERT INTO metabib.browse_entry (sort_value, value)
          SELECT sort_value, value FROM missing_browse_entries ON CONFLICT DO NOTHING RETURNING id, sort_value, value
  ), computed_browse_entries AS ( -- full set of to-be-mapped sort_value/value pairs with the id for each
      SELECT id, sort_value, value, def FROM existing_browse_entries
          UNION ALL
      SELECT id, sort_value, value, NULL::INT def FROM inserted_browse_entries
  ), new_authority_browse_map AS ( -- insert entry->simple_heading map now that all sort_value/value pairs have an id
      INSERT INTO metabib.browse_entry_simple_heading_map (entry, simple_heading)
          SELECT  cbe.id, nar.simple_heading
            FROM  computed_browse_entries cbe
                  JOIN new_authority_rows nar USING (sort_value, value)
      RETURNING *
  ), new_bib_browse_map AS ( -- insert entry->dev/source/authority map now that all sort_value/value pairs have an id
      INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
          SELECT  cbe.id, nbr.def, nbr.source, nbr.authority
            FROM  computed_browse_entries cbe
                  JOIN new_bib_rows nbr USING (sort_value, value, def)
            WHERE cbe.def IS NOT NULL
              UNION
          SELECT  cbe.id, nbr.def, nbr.source, nbr.authority
            FROM  computed_browse_entries cbe
                  JOIN new_bib_rows nbr USING (sort_value, value)
            WHERE cbe.def IS NULL
      RETURNING *
  )
  SELECT  a.row_count + b.row_count
    FROM  (SELECT COUNT(*) AS row_count FROM new_authority_browse_map) AS a,
          (SELECT COUNT(*) AS row_count FROM new_bib_browse_map) AS b;
$f$ LANGUAGE SQL;

-- This version does not constrain itself to just the current transaction.
CREATE OR REPLACE FUNCTION metabib.browse_entry_full_reify () RETURNS INT AS $f$
    SELECT metabib.browse_entry_reify(TRUE);
$f$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries(
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE,
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE,
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id || $$ AND field = ANY($1)$$ USING field_list;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id AND field = ANY(field_list);
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id AND def = ANY(field_list);
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

        -- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN

            CONTINUE WHEN ind_data.sort_value IS NULL;

            INSERT INTO metabib.browse_entry_updates (transaction_id, sort_value, value, def, source, authority)
                VALUES (txid_current(), SUBSTRING(ind_data.sort_value FOR 1000), SUBSTRING(metabib.browse_normalize(ind_data.value, ind_data.field) FOR 1000),
                        ind_data.field, ind_data.source, ind_data.authority);

        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
        IF NOT FOUND THEN
            PERFORM search.symspell_dictionary_reify();
        END IF;
    END IF;

    IF NOT b_skip_browse THEN
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_browse_entry_reification' AND enabled;
        IF NOT FOUND THEN
            PERFORM metabib.browse_entry_reify();
        END IF;
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.indexing_update (auth authority.record_entry, insert_only BOOL DEFAULT FALSE, old_heading TEXT DEFAULT NULL) RETURNS BOOL AS $func$
DECLARE
    ashs    authority.simple_heading%ROWTYPE;
    mbe_row metabib.browse_entry%ROWTYPE;
    mbe_id  BIGINT;
    ash_id  BIGINT;
    diag_detail     TEXT;
    diag_context    TEXT;
BEGIN

    -- Unless there's a setting stopping us, propagate these updates to any linked bib records when the heading changes
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_auto_update' AND enabled;

    IF NOT FOUND AND auth.heading <> old_heading THEN
        PERFORM authority.propagate_changes(auth.id);
    END IF;

    IF NOT insert_only THEN
        DELETE FROM authority.authority_linking WHERE source = auth.id;
        DELETE FROM authority.simple_heading WHERE record = auth.id;
    END IF;

    INSERT INTO authority.authority_linking (source, target, field)
        SELECT source, target, field FROM authority.calculate_authority_linking(
            auth.id, auth.control_set, auth.marc::XML
        );

    FOR ashs IN SELECT * FROM authority.simple_heading_set(auth.marc) LOOP

        INSERT INTO authority.simple_heading (record,atag,value,sort_value,thesaurus)
            VALUES (ashs.record, ashs.atag, ashs.value, ashs.sort_value, ashs.thesaurus);
            ash_id := CURRVAL('authority.simple_heading_id_seq'::REGCLASS);

        INSERT INTO metabib.browse_entry_updates (transaction_id, sort_value, value, simple_heading)
            VALUES (txid_current(), SUBSTRING(ashs.sort_value FOR 1000), SUBSTRING(ashs.value FOR 1000), ash_id);

    END LOOP;

    -- Flatten and insert the afr data
    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_full_rec' AND enabled;
    IF NOT FOUND THEN
        PERFORM authority.reingest_authority_full_rec(auth.id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_authority_rec_descriptor' AND enabled;
        IF NOT FOUND THEN
            PERFORM authority.reingest_authority_rec_descriptor(auth.id);
        END IF;
    END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
    IF NOT FOUND THEN
        PERFORM search.symspell_dictionary_reify();
    END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_browse_entry_reification' AND enabled;
    IF NOT FOUND THEN
        PERFORM metabib.browse_entry_reify();
    END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS diag_detail  = PG_EXCEPTION_DETAIL,
                            diag_context = PG_EXCEPTION_CONTEXT;
    RAISE WARNING '%\n%', diag_detail, diag_context;
    RETURN FALSE;
END;
$func$ LANGUAGE PLPGSQL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1500', :eg_version);

INSERT INTO config.record_attr_definition (name,label,sorter,filter,tag,sf_list,multi,vocabulary) VALUES
 ('a11yAccessMode',oils_i18n_gettext('a11yAccessMode', 'Content access mode', 'crad', 'label'),FALSE,TRUE,'341','a',TRUE,'https://schema.org/accessMode'),
 ('a11yTextFeatures',oils_i18n_gettext('a11yTextFeatures', 'Textual assistive features', 'crad', 'label'),FALSE,TRUE,'341','b',TRUE,'https://schema.org/accessibilityFeature'),
 ('a11yVisualFeatures',oils_i18n_gettext('a11yVisualFeatures', 'Visual assistive features', 'crad', 'label'),FALSE,TRUE,'341','c',TRUE,'https://schema.org/accessibilityFeature'),
 ('a11yAuditoryFeatures',oils_i18n_gettext('a11yAuditoryFeatures', 'Auditory assistive features', 'crad', 'label'),FALSE,TRUE,'341','d',TRUE,'https://schema.org/accessibilityFeature'),
 ('a11yTactileFeatures',oils_i18n_gettext('a11yTactileFeatures', 'Tactile assistive features', 'crad', 'label'),FALSE,TRUE,'341','e',TRUE,'https://schema.org/accessibilityFeature')
;

INSERT INTO config.coded_value_map (id, opac_visible, ctype, code, value, search_label) VALUES
 (1753,true,'a11yAccessMode','auditory',oils_i18n_gettext('1753','Auditory','ccvm','value'),oils_i18n_gettext('1753','Auditory','ccvm','search_label')),
 (1754,true,'a11yAccessMode','textual',oils_i18n_gettext('1754','Textual','ccvm','value'),oils_i18n_gettext('1754','Textual','ccvm','search_label')),
 (1755,true,'a11yAccessMode','visual',oils_i18n_gettext('1755','Visual','ccvm','value'),oils_i18n_gettext('1755','Visual','ccvm','search_label')),
 (1756,true,'a11yAccessMode','tactile',oils_i18n_gettext('1756','Tactile','ccvm','value'),oils_i18n_gettext('1756','Tactile','ccvm','search_label')),
 (1757,true,'a11yTextFeatures','annotations',oils_i18n_gettext('1757','annotations','ccvm','value'),oils_i18n_gettext('1757','Annotations','ccvm','search_label')),
 (1758,true,'a11yTextFeatures','ARIA',oils_i18n_gettext('1758','ARIA','ccvm','value'),oils_i18n_gettext('1758','ARIA','ccvm','search_label')),
 (1759,true,'a11yTextFeatures','bookmarks',oils_i18n_gettext('1759','bookmarks','ccvm','value'),oils_i18n_gettext('1759','Bookmarks','ccvm','search_label')),
 (1760,true,'a11yTextFeatures','index',oils_i18n_gettext('1760','index','ccvm','value'),oils_i18n_gettext('1760','Index','ccvm','search_label')),
 (1761,true,'a11yTextFeatures','pageBreakMarkers',oils_i18n_gettext('1761','pageBreakMarkers','ccvm','value'),oils_i18n_gettext('1761','Page break markers','ccvm','search_label')),
 (1762,false,'a11yTextFeatures','pageNavigation',oils_i18n_gettext('1762','pageNavigation','ccvm','value'),oils_i18n_gettext('1762','Page navigation','ccvm','search_label')),
 (1763,true,'a11yTextFeatures','readingOrder',oils_i18n_gettext('1763','readingOrder','ccvm','value'),oils_i18n_gettext('1763','Reading order','ccvm','search_label')),
 (1764,true,'a11yTextFeatures','structuralNavigation',oils_i18n_gettext('1764','structuralNavigation','ccvm','value'),oils_i18n_gettext('1764','Structural navigation','ccvm','search_label')),
 (1765,true,'a11yTextFeatures','tableOfContents',oils_i18n_gettext('1765','tableOfContents','ccvm','value'),oils_i18n_gettext('1765','Table of contents','ccvm','search_label')),
 (1766,true,'a11yTextFeatures','taggedPDF',oils_i18n_gettext('1766','taggedPDF','ccvm','value'),oils_i18n_gettext('1766','Tagged PDF','ccvm','search_label')),
 (1767,true,'a11yTextFeatures','alternativeText',oils_i18n_gettext('1767','alternativeText','ccvm','value'),oils_i18n_gettext('1767','Alternative text','ccvm','search_label')),
 (1768,true,'a11yTextFeatures','captions',oils_i18n_gettext('1768','captions','ccvm','value'),oils_i18n_gettext('1768','Captions','ccvm','search_label')),
 (1769,true,'a11yTextFeatures','closedCaptions',oils_i18n_gettext('1769','closedCaptions','ccvm','value'),oils_i18n_gettext('1769','Closed captions','ccvm','search_label')),
 (1770,true,'a11yTextFeatures','describedMath',oils_i18n_gettext('1770','describedMath','ccvm','value'),oils_i18n_gettext('1770','Described math','ccvm','search_label')),
 (1771,true,'a11yTextFeatures','longDescription',oils_i18n_gettext('1771','longDescription','ccvm','value'),oils_i18n_gettext('1771','Long description','ccvm','search_label')),
 (1772,true,'a11yTextFeatures','openCaptions',oils_i18n_gettext('1772','openCaptions','ccvm','value'),oils_i18n_gettext('1772','Open captions','ccvm','search_label')),
 (1773,true,'a11yTextFeatures','transcript',oils_i18n_gettext('1773','transcript','ccvm','value'),oils_i18n_gettext('1773','transcript','ccvm','search_label')),
 (1774,true,'a11yTextFeatures','displayTransformability',oils_i18n_gettext('1774','displayTransformability','ccvm','value'),oils_i18n_gettext('1774','Display transformability','ccvm','search_label')),
 (1775,true,'a11yTextFeatures','ChemML',oils_i18n_gettext('1775','ChemML','ccvm','value'),oils_i18n_gettext('1775','ChemML','ccvm','search_label')),
 (1776,true,'a11yTextFeatures','latex',oils_i18n_gettext('1776','latex','ccvm','value'),oils_i18n_gettext('1776','LaTeX','ccvm','search_label')),
 (1777,false,'a11yTextFeatures','latex-chemistry',oils_i18n_gettext('1777','latex-chemistry','ccvm','value'),oils_i18n_gettext('1777','LaTeX-chemistry','ccvm','search_label')),
 (1778,true,'a11yTextFeatures','MathML',oils_i18n_gettext('1778','MathML','ccvm','value'),oils_i18n_gettext('1778','MathML','ccvm','search_label')),
 (1779,false,'a11yTextFeatures','MathML-chemistry',oils_i18n_gettext('1779','MathML-chemistry','ccvm','value'),oils_i18n_gettext('1779','MathML-chemistry','ccvm','search_label')),
 (1780,true,'a11yTextFeatures','ttsMarkup',oils_i18n_gettext('1780','ttsMarkup','ccvm','value'),oils_i18n_gettext('1780','TTS markup','ccvm','search_label')),
 (1781,true,'a11yTextFeatures','largePrint',oils_i18n_gettext('1781','largePrint','ccvm','value'),oils_i18n_gettext('1781','Large print','ccvm','search_label')),
 (1782,false,'a11yTextFeatures','horizontalWriting',oils_i18n_gettext('1782','horizontalWriting','ccvm','value'),oils_i18n_gettext('1782','Horizontal writing','ccvm','search_label')),
 (1783,false,'a11yTextFeatures','verticalWriting',oils_i18n_gettext('1783','verticalWriting','ccvm','value'),oils_i18n_gettext('1783','VerticalWriting','ccvm','search_label')),
 (1784,false,'a11yTextFeatures','withAdditionalWordSegmentation',oils_i18n_gettext('1784','withAdditionalWordSegmentation','ccvm','value'),oils_i18n_gettext('1784','With additional word segmentation','ccvm','search_label')),
 (1785,false,'a11yTextFeatures','withoutAdditionalWordSegmentation',oils_i18n_gettext('1785','withoutAdditionalWordSegmentation','ccvm','value'),oils_i18n_gettext('1785','Without additional word segmentation','ccvm','search_label')),
 (1786,true,'a11yVisualFeatures','highContrastDisplay',oils_i18n_gettext('1786','highContrastDisplay','ccvm','value'),oils_i18n_gettext('1786','High contrast display','ccvm','search_label')),
 (1787,true,'a11yVisualFeatures','signLanguage',oils_i18n_gettext('1787','signLanguage','ccvm','value'),oils_i18n_gettext('1787','Sign language','ccvm','search_label')),
 (1788,true,'a11yAuditoryFeatures','audioDescription',oils_i18n_gettext('1788','audioDescription','ccvm','value'),oils_i18n_gettext('1788','Audio description','ccvm','search_label')),
 (1789,true,'a11yAuditoryFeatures','highContrastAudio',oils_i18n_gettext('1789','highContrastAudio','ccvm','value'),oils_i18n_gettext('1789','High contrast audio','ccvm','search_label')),
 (1790,true,'a11yAuditoryFeatures','timingControl',oils_i18n_gettext('1790','timingControl','ccvm','value'),oils_i18n_gettext('1790','Timing control','ccvm','search_label')),
 (1791,true,'a11yAuditoryFeatures','synchronizedAudioText',oils_i18n_gettext('1791','synchronizedAudioText','ccvm','value'),oils_i18n_gettext('1791','Synchronized audio text','ccvm','search_label')),
 (1792,true,'a11yTactileFeatures','braille',oils_i18n_gettext('1792','braille','ccvm','value'),oils_i18n_gettext('1792','Braille','ccvm','search_label')),
 (1793,false,'a11yTactileFeatures','tactileGraphic',oils_i18n_gettext('1793','tactileGraphic','ccvm','value'),oils_i18n_gettext('1793','Tactile graphic','ccvm','search_label')),
 (1794,false,'a11yTactileFeatures','tactileObject',oils_i18n_gettext('1794','tactileObject','ccvm','value'),oils_i18n_gettext('1794','Tactile object','ccvm','search_label'))
;

-- The above is autogenerated from LoC data; because we use metabib.full_rec to look up the
-- in-record value, we have to make our CCVM value lowercase, as that's how MFR stores the data.
UPDATE config.coded_value_map SET code = LOWER(code) WHERE code <> LOWER(code) AND ctype LIKE 'a11y%';

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1501', :eg_version);

ALTER FUNCTION permission.usr_has_home_perm STABLE;
ALTER FUNCTION permission.usr_has_work_perm STABLE;
ALTER FUNCTION permission.usr_has_object_perm ( INT, TEXT, TEXT, TEXT ) STABLE;
ALTER FUNCTION permission.usr_has_perm STABLE;
ALTER FUNCTION permission.usr_has_perm_at_nd STABLE;
ALTER FUNCTION permission.usr_has_perm_at_all_nd STABLE;
ALTER FUNCTION permission.usr_has_perm_at STABLE;
ALTER FUNCTION permission.usr_has_perm_at_all STABLE;

CREATE OR REPLACE FUNCTION evergreen.setup_delete_protect_rule (
    t_schema TEXT,
    t_table TEXT,
    t_additional TEXT DEFAULT '',
    t_pkey TEXT DEFAULT 'id',
    t_deleted TEXT DEFAULT 'deleted'
) RETURNS VOID AS $$
DECLARE
    rule_name   TEXT;
    table_name  TEXT;
    fq_pkey     TEXT;
BEGIN

    rule_name := 'protect_' || t_schema || '_' || t_table || '_delete';
    table_name := t_schema || '.' || t_table;
    fq_pkey := table_name || '.' || t_pkey;

    EXECUTE 'DROP RULE IF EXISTS ' || rule_name || ' ON ' || table_name;
    EXECUTE 'CREATE RULE ' || rule_name
            || ' AS ON DELETE TO ' || table_name
            || ' DO INSTEAD (UPDATE ' || table_name
            || '   SET ' || t_deleted || ' = TRUE '
            || '   WHERE OLD.' || t_pkey || ' = ' || fq_pkey
            || '   ; ' || t_additional || ')';

END;
$$ STRICT LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION permission.usr_has_object_perm ( iuser INT, tperm TEXT, obj_type TEXT, obj_id TEXT, target_ou INT ) RETURNS BOOL AS $$
DECLARE
    r_usr   actor.usr%ROWTYPE;
    r_perm  permission.perm_list%ROWTYPE;
    res     BOOL;
BEGIN

    SELECT * INTO r_usr FROM actor.usr WHERE id = iuser;
    SELECT * INTO r_perm FROM permission.perm_list WHERE code = tperm;

    IF r_usr.active = FALSE THEN
        RETURN FALSE;
    END IF;

    IF r_usr.super_user = TRUE THEN
        RETURN TRUE;
    END IF;

    SELECT TRUE INTO res FROM permission.usr_object_perm_map WHERE perm = r_perm.id AND usr = r_usr.id AND object_type = obj_type AND object_id = obj_id;

    IF FOUND THEN
        RETURN TRUE;
    END IF;

    IF target_ou > -1 THEN
        RETURN permission.usr_has_perm( iuser, tperm, target_ou);
    END IF;

    RETURN FALSE;

END;
$$ LANGUAGE PLPGSQL STABLE;

-- Start trimming back RULEs, they're starting to make things too hard.  Trigger time!
CREATE OR REPLACE FUNCTION evergreen.raise_protected_row_exception() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Cannot % %.% with % of %', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME, COALESCE(TG_ARGV[0]::TEXT,'id'), COALESCE(TG_ARGV[1]::TEXT,'-1');
END;
$$ LANGUAGE plpgsql;

DROP RULE IF EXISTS protect_bre_id_neg1 ON biblio.record_entry;
CREATE TRIGGER protect_bre_id_neg1
  BEFORE UPDATE ON biblio.record_entry
  FOR EACH ROW WHEN (NEW.deleted = TRUE AND OLD.deleted = FALSE AND OLD.id = -1)
  EXECUTE PROCEDURE evergreen.raise_protected_row_exception();

DROP RULE IF EXISTS protect_acn_id_neg1 ON asset.call_number;
CREATE TRIGGER protect_acn_id_neg1
  BEFORE UPDATE ON asset.call_number
  FOR EACH ROW WHEN (OLD.id = -1)
  EXECUTE PROCEDURE evergreen.raise_protected_row_exception();

-- Open-ILS/src/sql/Pg/005.schema.actors.sql
DROP RULE IF EXISTS protect_user_delete ON actor.usr;
SELECT evergreen.setup_delete_protect_rule('actor','usr');

DROP RULE IF EXISTS protect_usr_message_delete ON actor.usr_message;
SELECT evergreen.setup_delete_protect_rule('actor','usr_message');

-- Open-ILS/src/sql/Pg/011.schema.authority.sql
DROP RULE IF EXISTS protect_authority_rec_delete ON authority.record_entry;
SELECT evergreen.setup_delete_protect_rule('authority','record_entry','DELETE FROM authority.full_rec WHERE record = OLD.id');

-- Open-ILS/src/sql/Pg/040.schema.asset.sql
DROP RULE IF EXISTS protect_copy_delete ON asset.copy;
SELECT evergreen.setup_delete_protect_rule('asset','copy');

DROP RULE IF EXISTS protect_cn_delete ON asset.call_number;
SELECT evergreen.setup_delete_protect_rule('asset','call_number');

-- Open-ILS/src/sql/Pg/210.schema.serials.sql
DROP RULE IF EXISTS protect_mfhd_delete ON serial.record_entry;
SELECT evergreen.setup_delete_protect_rule('serial','record_entry');

DROP RULE IF EXISTS protect_serial_unit_delete ON serial.unit;
SELECT evergreen.setup_delete_protect_rule('serial','unit');

-- Open-ILS/src/sql/Pg/800.fkeys.sql
DROP RULE IF EXISTS protect_bib_rec_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','record_entry');

DROP RULE IF EXISTS protect_mono_part_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','monograph_part','DELETE FROM asset.copy_part_map WHERE part = OLD.id');

DROP RULE IF EXISTS protect_copy_location_delete ON asset.copy_location;
SELECT evergreen.setup_delete_protect_rule(
    'asset', 'copy_location',
    'SELECT asset.check_delete_copy_location(OLD.id);'
      || ' UPDATE acq.lineitem_detail SET location = NULL WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_order WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_group_map WHERE location = OLD.id;'
      || ' DELETE FROM config.circ_limit_set_copy_loc_map WHERE copy_loc = OLD.id;'
);

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1502', :eg_version);

CREATE INDEX IF NOT EXISTS cbreb_pub_owner_not_temp_idx ON container.biblio_record_entry_bucket (pub,owner) WHERE btype != 'temp';

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1503', :eg_version);

CREATE OR REPLACE FUNCTION asset.record_has_holdable_copy ( rid BIGINT, ou INT DEFAULT NULL) RETURNS BOOL AS $f$
DECLARE
    ous INT[] := (SELECT array_agg(id) FROM actor.org_unit_descendants(COALESCE(ou, (SELECT id FROM evergreen.org_top()))));
BEGIN
    PERFORM 1
        FROM
            asset.copy acp
            JOIN asset.call_number acn ON acp.call_number = acn.id
            JOIN asset.copy_location acpl ON acp.location = acpl.id
            JOIN config.copy_status ccs ON acp.status = ccs.id
        WHERE
            acn.record = rid
            AND acp.holdable = true
            AND acpl.holdable = true
            AND ccs.holdable = true
            AND acp.deleted = false
            AND acpl.deleted = false
            AND acp.circ_lib = ANY(ous)
        LIMIT 1;
    IF FOUND THEN
        RETURN true;
    END IF;
    RETURN FALSE;
END;
$f$ LANGUAGE PLPGSQL;

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1504', :eg_version); -- phasefx

-- A/T seed data
INSERT into action_trigger.hook (key, core_type, description) VALUES
( 'au.erenewal', 'au', 'A patron has been renewed via Erenewal');

COMMIT;
BEGIN;

SELECT evergreen.upgrade_deps_block_check('1505', :eg_version);

CREATE OR REPLACE FUNCTION openapi.check_generic_endpoint_rate_limit (target_endpoint TEXT, accessing_usr INT DEFAULT NULL, from_ip_addr INET DEFAULT NULL) RETURNS INT AS $f$
DECLARE
    def_rl    openapi.rate_limit_definition%ROWTYPE;
    def_u_rl  openapi.rate_limit_definition%ROWTYPE;
    def_i_rl  openapi.rate_limit_definition%ROWTYPE;
    u_wait    INT;
    i_wait    INT;
BEGIN
    def_rl := openapi.find_default_endpoint_rate_limit(target_endpoint);

    IF accessing_usr IS NOT NULL THEN
        def_u_rl := openapi.find_user_endpoint_rate_limit(target_endpoint, accessing_usr);
    END IF;

    IF from_ip_addr IS NOT NULL THEN
        def_i_rl := openapi.find_ip_addr_endpoint_rate_limit(target_endpoint, from_ip_addr);
    END IF;

    -- Now we test the user-based and IP-based limits in their focused way...
    IF def_u_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO u_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.accessor ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.endpoint_access_attempt_log l
                  WHERE l.endpoint = target_endpoint
                        AND l.accessor = accessing_usr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    IF def_i_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_i_rl.limit_interval) - NOW())) INTO i_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.endpoint_access_attempt_log l
                  WHERE l.endpoint = target_endpoint
                        AND l.ip_addr = from_ip_addr
                        AND l.attempt_time > NOW() - def_i_rl.limit_interval
                ) x
          WHERE running_count = def_i_rl.limit_count;
    END IF;

    -- If there are no user-specific or IP-based limit
    -- overrides; check endpoint-wide limits for user,
    -- then IP, and if we were passed neither, then limit
    -- endpoint access for all users.  Better to lock it
    -- all down than to set the servers on fire.
    IF COALESCE(u_wait, i_wait) IS NULL AND COALESCE(def_i_rl.id, def_u_rl.id) IS NULL THEN
        IF accessing_usr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.accessor ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.accessor = accessing_usr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSIF from_ip_addr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.ip_addr = from_ip_addr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSE -- we have no user and no IP, global per-endpoint rate limit?
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.endpoint ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.endpoint_access_attempt_log l
                      WHERE l.endpoint = target_endpoint
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        END IF;
    END IF;

    -- Send back the largest required wait time, or NULL for no restriction
    u_wait := GREATEST(u_wait,i_wait);
    IF u_wait > 0 THEN
        RETURN u_wait;
    END IF;

    RETURN NULL;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION openapi.check_auth_endpoint_rate_limit (accessing_usr TEXT DEFAULT NULL, from_ip_addr INET DEFAULT NULL) RETURNS INT AS $f$
DECLARE
    def_rl    openapi.rate_limit_definition%ROWTYPE;
    def_u_rl  openapi.rate_limit_definition%ROWTYPE;
    def_i_rl  openapi.rate_limit_definition%ROWTYPE;
    u_wait    INT;
    i_wait    INT;
BEGIN
    def_rl := openapi.find_default_endpoint_rate_limit('authenticateUser');

    IF accessing_usr IS NOT NULL THEN
        SELECT  (openapi.find_user_endpoint_rate_limit('authenticateUser', u.id)).* INTO def_u_rl
          FROM  actor.usr u
          WHERE u.usrname = accessing_usr;
    END IF;

    IF from_ip_addr IS NOT NULL THEN
        def_i_rl := openapi.find_ip_addr_endpoint_rate_limit('authenticateUser', from_ip_addr);
    END IF;

    -- Now we test the user-based and IP-based limits in their focused way...
    IF def_u_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_u_rl.limit_interval) - NOW())) INTO u_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.cred_user ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.authen_attempt_log l
                  WHERE l.cred_user = accessing_usr
                        AND l.attempt_time > NOW() - def_u_rl.limit_interval
                ) x
          WHERE running_count = def_u_rl.limit_count;
    END IF;

    IF def_i_rl.id IS NOT NULL THEN
        SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_i_rl.limit_interval) - NOW())) INTO i_wait
          FROM  (SELECT l.attempt_time,
                        COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                  FROM  openapi.authen_attempt_log l
                  WHERE l.ip_addr = from_ip_addr
                        AND l.attempt_time > NOW() - def_i_rl.limit_interval
                ) x
          WHERE running_count = def_i_rl.limit_count;
    END IF;

    -- If there are no user-specific or IP-based limit
    -- overrides; check endpoint-wide limits for user,
    -- then IP, and if we were passed neither, then limit
    -- endpoint access for all users.  Better to lock it
    -- all down than to set the servers on fire.
    IF COALESCE(u_wait, i_wait) IS NULL AND COALESCE(def_i_rl.id, def_u_rl.id) IS NULL THEN
        IF accessing_usr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.cred_user ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.authen_attempt_log l
                      WHERE l.cred_user = accessing_usr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSIF from_ip_addr IS NOT NULL THEN
            SELECT  CEIL(EXTRACT(EPOCH FROM (x.attempt_time + def_rl.limit_interval) - NOW())) INTO i_wait
              FROM  (SELECT l.attempt_time,
                            COUNT(*) OVER (PARTITION BY l.ip_addr ORDER BY l.attempt_time DESC) AS running_count
                      FROM  openapi.authen_attempt_log l
                      WHERE l.ip_addr = from_ip_addr
                            AND l.attempt_time > NOW() - def_rl.limit_interval
                    ) x
              WHERE running_count = def_rl.limit_count;
        ELSE -- we have no user and no IP, global auth attempt rate limit?
            SELECT  CEIL(EXTRACT(EPOCH FROM (l.attempt_time + def_rl.limit_interval) - NOW())) INTO u_wait
              FROM  openapi.authen_attempt_log l
              WHERE l.attempt_time > NOW() - def_rl.limit_interval
              ORDER BY l.attempt_time DESC
              LIMIT 1 OFFSET def_rl.limit_count;
        END IF;
    END IF;

    -- Send back the largest required wait time, or NULL for no restriction
    u_wait := GREATEST(u_wait,i_wait);
    IF u_wait > 0 THEN
        RETURN u_wait;
    END IF;

    RETURN NULL;
END;
$f$ STABLE LANGUAGE PLPGSQL;

COMMIT;

BEGIN;

SELECT evergreen.upgrade_deps_block_check('1506', :eg_version);

CREATE OR REPLACE FUNCTION evergreen.setup_delete_protect_rule (
    t_schema TEXT,
    t_table TEXT,
    t_additional TEXT DEFAULT '',
    t_pkey TEXT DEFAULT 'id',
    t_deleted TEXT DEFAULT 'deleted'
) RETURNS VOID AS $$
DECLARE
    rule_name   TEXT;
    table_name  TEXT;
    fq_pkey     TEXT;
BEGIN

    rule_name := 'protect_' || t_schema || '_' || t_table || '_delete';
    table_name := t_schema || '.' || t_table;
    fq_pkey := table_name || '.' || t_pkey;

    EXECUTE 'DROP RULE IF EXISTS ' || rule_name || ' ON ' || table_name;
    EXECUTE 'CREATE RULE ' || rule_name
            || ' AS ON DELETE TO ' || table_name
            || ' DO INSTEAD (UPDATE ' || table_name
            || '   SET ' || t_deleted || ' = TRUE '
            || '   WHERE OLD.' || t_pkey || ' = ' || fq_pkey
            || '   ; ' || t_additional || ')';

END;
$$ STRICT LANGUAGE PLPGSQL;

-- Open-ILS/src/sql/Pg/005.schema.actors.sql
DROP RULE IF EXISTS protect_user_delete ON actor.usr;
SELECT evergreen.setup_delete_protect_rule('actor','usr');

DROP RULE IF EXISTS protect_usr_message_delete ON actor.usr_message;
SELECT evergreen.setup_delete_protect_rule('actor','usr_message');

-- Open-ILS/src/sql/Pg/011.schema.authority.sql
DROP RULE IF EXISTS protect_authority_rec_delete ON authority.record_entry;
SELECT evergreen.setup_delete_protect_rule('authority','record_entry','DELETE FROM authority.full_rec WHERE record = OLD.id');

-- Open-ILS/src/sql/Pg/040.schema.asset.sql
DROP RULE IF EXISTS protect_copy_delete ON asset.copy;
SELECT evergreen.setup_delete_protect_rule('asset','copy');

DROP RULE IF EXISTS protect_cn_delete ON asset.call_number;
SELECT evergreen.setup_delete_protect_rule('asset','call_number');

-- Open-ILS/src/sql/Pg/210.schema.serials.sql
DROP RULE IF EXISTS protect_mfhd_delete ON serial.record_entry;
SELECT evergreen.setup_delete_protect_rule('serial','record_entry');

DROP RULE IF EXISTS protect_serial_unit_delete ON serial.unit;
SELECT evergreen.setup_delete_protect_rule('serial','unit');

-- Open-ILS/src/sql/Pg/800.fkeys.sql
DROP RULE IF EXISTS protect_bib_rec_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','record_entry');

DROP RULE IF EXISTS protect_mono_part_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','monograph_part','DELETE FROM asset.copy_part_map WHERE part = OLD.id');

DROP RULE IF EXISTS protect_copy_location_delete ON asset.copy_location;
SELECT evergreen.setup_delete_protect_rule(
    'asset', 'copy_location',
    'SELECT asset.check_delete_copy_location(OLD.id);'
      || ' UPDATE acq.lineitem_detail SET location = NULL WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_order WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_group_map WHERE location = OLD.id;'
      || ' DELETE FROM config.circ_limit_set_copy_loc_map WHERE copy_loc = OLD.id;'
);

COMMIT;

-- XXX: Change workstation to usr, and cwst to cust, if
-- we decide on user settings instead of WS settings.
INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES
(
    'eg.grid.ff.ill.onshelf.borrower', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.onshelf.borrower',
        'Grid Config: ILL items on Borrower Hold Self',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.onshelf.lender', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.onshelf.lender',
        'Grid Config: Lender items on remote Hold Selves',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.pending.borrower', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.pending.borrower',
        'Grid Config: Pending ILL Requests for Borrower',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.pending.lender', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.pending.lender',
        'Grid Config: Pending ILL Requests targeting Lender',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.circulating.borrower', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.circulating.borrower',
        'Grid Config: ILL items circulating at Borrower',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.circulating.lender', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.circulating.lender',
        'Grid Config: Lender items circulating elsewhere',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.incoming_transit.borrower', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.incoming_transit.borrower',
        'Grid Config: ILL items transiting to Borrower',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.incoming_transit.lender', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.incoming_transit.lender',
        'Grid Config: Lender items returning from elsewhere',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.outgoing_transit.borrower', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.outgoing_transit.borrower',
        'Grid Config: ILL items transiting home from Borrower',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.outgoing_transit.lender', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.outgoing_transit.lender',
        'Grid Config: Lender items transiting for ILL elsewhere',
        'cwst', 'label')
);

INSERT INTO permission.perm_list (id,code) VALUES
 (695,'ff.menuAccess.search'),
 (696,'ff.menuAccess.circulation'),
 (697,'ff.menuAccess.cataloging'),
 (698,'ff.menuAccess.acquisitions'),
 (699,'ff.menuAccess.booking'),
 (700,'ff.menuAccess.adminstration')
ON CONFLICT DO NOTHING;

-- Menu visibility for all "administrator" groups
INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
   SELECT  pgt.id, perm.id, 0, FALSE
     FROM  permission.grp_tree pgt,
           permission.perm_list perm
     WHERE pgt.name ~ 'Administrator$' AND
           perm.code ~ '^ff.menuAccess.';


---------------------
-- This comes after the commit because the table may already exists, and that's fine
---------------------

CREATE TABLE action.copy_block_hold (
    id serial primary key,
    item bigint NOT NULL,
    hold bigint REFERENCES action.hold_request(id) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    staff bigint NOT NULL REFERENCES actor.usr(id) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    block_time timestamp with time zone DEFAULT now() NOT NULL,
    reason text NOT NULL
);

CREATE OR REPLACE FUNCTION evergreen.action_copy_block_hold_item_inh_fkey()
 RETURNS trigger
 LANGUAGE plpgsql
 COST 50
AS $function$
BEGIN
    PERFORM 1 FROM asset.copy WHERE id = NEW.item;
    IF NOT FOUND THEN
        RAISE foreign_key_violation USING MESSAGE = FORMAT(
            $$Referenced asset.copy id not found, item:%s$$, NEW.item
        );
    END IF;
    RETURN NEW;
END;
$function$;

CREATE CONSTRAINT TRIGGER inherit_copy_block_hold_item_fkey
    AFTER INSERT OR UPDATE ON action.copy_block_hold DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE PROCEDURE evergreen.action_copy_block_hold_item_inh_fkey();

CREATE OR REPLACE FUNCTION actor.org_unit_descendants( INT, INT ) RETURNS SETOF actor.org_unit AS $$
    WITH RECURSIVE descendant_depth AS (
        SELECT  *
          FROM  (SELECT ou.id,
                        ou.parent_ou,
                        out.depth
                  FROM  actor.org_unit ou
                        JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                        JOIN anscestor_depth ad ON (ad.id = ou.id)
                  WHERE ad.depth >= $2  -- 1) requested depth OR DEEPER to account for unbalanced trees with "skipped" types
                  ORDER BY ad.depth ASC -- 2) order by depth shallowness, so, as close to the requested depth as available
                  LIMIT 1               -- 3) just the shallowest (one row required to start the recursion)
                ) x
            UNION ALL
        SELECT  ou.id,
                ou.parent_ou,
                out.depth
          FROM  actor.org_unit ou
                JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                JOIN descendant_depth ot ON (ot.id = ou.parent_ou)
    ), anscestor_depth AS (
        SELECT  ou.id,
                ou.parent_ou,
                out.depth
          FROM  actor.org_unit ou
                JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
          WHERE ou.id = $1
            UNION ALL
        SELECT  ou.id,
                ou.parent_ou,
                out.depth
          FROM  actor.org_unit ou
                JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                JOIN anscestor_depth ot ON (ot.parent_ou = ou.id)
    ) SELECT ou.* FROM actor.org_unit ou JOIN descendant_depth USING (id);
$$ LANGUAGE SQL ROWS 1;

CREATE OR REPLACE FUNCTION actor.org_unit_ancestor_at_depth ( INT,INT ) RETURNS actor.org_unit AS $$
    SELECT  a.*
      FROM  actor.org_unit a
      WHERE id IN (
                SELECT  x.id
                  FROM  actor.org_unit_ancestors($1) x
                        JOIN actor.org_unit_type y ON (x.ou_type = y.id AND y.depth >= $2)
                  ORDER BY y.depth ASC
                  LIMIT 1
            );
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION permission.usr_has_perm_at_nd(user_id integer, perm_code text)
 RETURNS SETOF integer
 LANGUAGE plpgsql
 STABLE ROWS 1
AS $function$
--
-- Return a set of all the org units for which a given user has a given
-- permission, granted directly (not through inheritance from a parent
-- org unit).
--
-- The permissions apply to a minimum depth of the org unit hierarchy,
-- for the org unit(s) to which the user is assigned.  (They also apply
-- to the subordinates of those org units, but we don't report the
-- subordinates here.)
--
-- For purposes of this function, the permission.usr_work_ou_map table
-- defines which users belong to which org units.  I.e. we ignore the
-- home_ou column of actor.usr.
--
DECLARE
    b_super       BOOLEAN;
    n_perm        INTEGER;
    n_min_depth   INTEGER;
BEGIN
    --
    -- Check for superuser
    --
    SELECT super_user INTO b_super FROM actor.usr WHERE id = user_id;

    IF NOT FOUND THEN
        RETURN;             -- No user?  No permissions.
    ELSIF b_super THEN
        -- Super user has all permissions everywhere
        RETURN QUERY SELECT id FROM actor.org_unit WHERE parent_ou IS NULL;
        RETURN;
    END IF;

    -- Translate the permission name to a numeric permission id
    SELECT id INTO n_perm FROM permission.perm_list WHERE code = perm_code;

    IF NOT FOUND THEN
        RETURN;               -- No such permission
    END IF;

    -- Find the highest-level org unit (i.e. the minimum depth)
    -- to which the permission is applied for this user
    --
    -- This query is modified from the one in permission.usr_perms().
    SELECT INTO n_min_depth
        min( depth )
    FROM    (
        SELECT depth
          FROM permission.usr_perm_map upm
         WHERE upm.usr = user_id
           AND (upm.perm = n_perm OR upm.perm = -1)
                    UNION
        SELECT  gpm.depth
          FROM  permission.grp_perm_map gpm
          WHERE (gpm.perm = n_perm OR gpm.perm = -1)
            AND gpm.grp IN (
               SELECT   (permission.grp_ancestors(
                    (SELECT profile FROM actor.usr WHERE id = user_id)
                )).id
            )
                    UNION
        SELECT  p.depth
          FROM  permission.grp_perm_map p
          WHERE (p.perm = n_perm OR p.perm = -1)
            AND p.grp IN (
                SELECT (permission.grp_ancestors(m.grp)).id
                FROM   permission.usr_grp_map m
                WHERE  m.usr = user_id
            )
    ) AS x;

    IF NOT FOUND THEN
        RETURN;                -- No such permission for this user
    END IF;

    RETURN QUERY
        SELECT  DISTINCT d.id
          FROM  permission.usr_work_ou_map m,
                actor.org_unit_ancestor_at_depth(m.work_ou, n_min_depth) d
          WHERE m.usr = user_id;

    RETURN;
END;
$function$;

DELETE FROM config.ui_staff_portal_page_entry;

INSERT INTO config.ui_staff_portal_page_entry
    (id, page_col, col_pos, entry_type, label, image_url, target_url, url_newtab, owner)
VALUES
    ( 1, 1, 0, 'header',        oils_i18n_gettext( 1, 'ILL Management', 'cusppe', 'label'), NULL, NULL, NULL, 1)
,   ( 2, 1, 1, 'menuitem',      oils_i18n_gettext( 2, 'ILL Processing', 'cusppe', 'label'), '/images/portal/book.png', '/eg2/staff/ill', NULL, 1)
,   ( 3, 1, 2, 'menuitem',      oils_i18n_gettext( 3, 'Pending Requests', 'cusppe', 'label'), '/images/portal/retreivepatron.png', '/eg2/staff/ill/pending', NULL, 1)
,   ( 4, 1, 3, 'menuitem',      oils_i18n_gettext( 4, 'ILL Pull List', 'cusppe', 'label'), '/images/portal/holds.png', '/eg2/staff/circ/holds/pull-list', NULL, 1)
,   ( 5, 2, 0, 'header',        oils_i18n_gettext( 5, 'Bibliographic Search', 'cusppe', 'label'), NULL, NULL, NULL, 1)
,   ( 6, 2, 1, 'catalogsearch', oils_i18n_gettext( 6, 'Search Catalog', 'cusppe', 'label'), NULL, NULL, NULL, 1)
,   ( 9, 3, 0, 'header',        oils_i18n_gettext( 9, 'Administration', 'cusppe', 'label'), NULL, NULL, NULL, 1)
,   (10, 3, 1, 'link',          oils_i18n_gettext(10, 'Fulfillment Documentation', 'cusppe', 'label'), '/images/portal/helpdesk.png', '/fulfillment-ill-documentation.pdf', TRUE, 1)
,   (11, 3, 2, 'menuitem',      oils_i18n_gettext(11, 'Workstation Administration', 'cusppe', 'label'), '/images/portal/helpdesk.png', '/eg/staff/admin/workstation/index', NULL, 1)
;

