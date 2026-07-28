\set ON_ERROR_STOP on
\set eg_version '''FF-12.2'''

BEGIN;

INSERT INTO config.org_unit_setting_type (name, label, description, datatype)
VALUES (
    'ff.remote.connector.usr_validate_only',
    oils_i18n_gettext(
        'ff.remote.connector.usr_validate_only',
        'LAI: Allow user validation and retrieval when the connector is disabled',
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'ff.remote.connector.usr_validate_only',
        'If true, Fulfillment will allow patrons to log in and staff to retrieve remote users even if the connector has been disabled for transactional use',
        'coust', 'description'
    ),
    'bool'
);

-- In FF-12.2 we're separating the au.usrname home org suffix from
-- the au.home_ou value, so that a remote patron can actually log
-- in from any sub-org of the connect-type YAOUS org unit.  This means
-- we need to find any "duplicate" old patrons and merge them.

SELECT  u.usrname, u.home_ou, c.barcode, s.org_unit
  FROM  actor.usr u
        JOIN actor.card c ON (u.card=c.id)
        LEFT JOIN LATERAL actor.org_unit_ancestor_setting('ff.remote.connector.type',u.home_ou) s ON TRUE
  WHERE u.usrname = c.barcode || ':'|| u.home_ou;

DO $func$
DECLARE
    r RECORD;
    s RECORD;
BEGIN
    FOR r IN
        SELECT  u.*,
                c.barcode
          FROM  actor.usr u
                JOIN actor.card c ON (u.card=c.id)
          WHERE u.usrname = c.barcode || ':'|| u.home_ou
    LOOP
        SELECT * INTO s FROM actor.org_unit_ancestor_setting('ff.remote.connector.type',r.home_ou);
        IF FOUND THEN
            IF s.org_unit <> r.home_ou THEN
                BEGIN
                    UPDATE actor.usr SET usrname = r.barcode || ':' || s.org_unit WHERE id = r.id;
                    RAISE INFO 'usrname for user with primary barcode [%] is now properly suffixed with org [%]',
                        r.barcode, s.org_unit;
                EXCEPTION WHEN OTHERS THEN
                    -- Yell about it!!!
                    RAISE WARNING 'User with primary barcode [%] is already present at org [%]! That is strange, and you should look into it. You probably want to merge the users.',
                        r.barcode, s.org_unit;
                END;
                BEGIN
                    UPDATE actor.card SET org = s.org_unit WHERE usr = r.id;
                    RAISE INFO 'card(s) for user with primary barcode [%] are now assigned to org [%]',
                        r.barcode, s.org_unit;
                EXCEPTION WHEN OTHERS THEN
                    -- Yell about it!!!
                    RAISE WARNING 'Card(s) with primary barcode [%] are already present at org [%]! That is strange, and you should look into it. You probably want to merge the users.',
                        r.barcode, s.org_unit;
                END;
            ELSE
                RAISE INFO 'usrname for user with primary barcode [%] is already properly suffixed with org [%]',
                    r.barcode, r.home_ou;
            END IF;
        ELSE
            RAISE WARNING 'Home org [%] of user with primary barcode [%] does not have an ancestor setting for YAOUS "ff.remote.connector.type", but should based on the usrname pattern.',
                r.home_ou, r.barcode;
        END IF;
    END LOOP;
END;
$func$;

SELECT  u.usrname, u.home_ou, c.barcode, s.org_unit
  FROM  actor.usr u
        JOIN actor.card c ON (u.card=c.id)
        LEFT JOIN LATERAL actor.org_unit_ancestor_setting('ff.remote.connector.type',u.home_ou) s ON TRUE
  WHERE u.usrname = c.barcode || ':'|| u.home_ou;

CREATE OR REPLACE FUNCTION unapi.acn ( obj_id BIGINT, format TEXT,  ename TEXT, includes TEXT[], org TEXT, depth INT DEFAULT NULL, slimit HSTORE DEFAULT NULL, soffset HSTORE DEFAULT NULL, include_xmlns BOOL DEFAULT TRUE ) RETURNS XML AS $F$
        SELECT  XMLELEMENT(
                    name volume,
                    XMLATTRIBUTES(
                        CASE WHEN $9 THEN 'http://open-ils.org/spec/holdings/v1' ELSE NULL END AS xmlns,
                        'tag:open-ils.org:U2@acn/' || acn.id AS id,
                        acn.id AS vol_id, o.shortname AS lib,
                        o.opac_visible AS opac_visible,
                        deleted, label, label_sortkey, label_class, record
                    ),
                    unapi.aou( owning_lib, $2, 'owning_lib', array_remove($4,'acn'), $5, $6, $7, $8),
                    CASE
                        WHEN ('acp' = ANY ($4)) THEN
                            CASE WHEN $6 IS NOT NULL THEN
                                XMLELEMENT( name copies,
                                    (SELECT XMLAGG(acp ORDER BY rank_avail) FROM (
                                        SELECT  unapi.acp( cp.id, 'xml', 'copy', array_remove($4,'acn'), $5, $6, $7, $8, FALSE),
                                            evergreen.rank_cp(cp) AS rank_avail
                                          FROM  asset.copy cp
                                                LEFT JOIN actor.org_unit_descendants( (SELECT id FROM actor.org_unit WHERE shortname = $5), $6) aoud ON (cp.circ_lib = aoud.id)
                                          WHERE cp.call_number = acn.id
                                              AND cp.deleted IS FALSE
                                              AND (aoud.id IS NULL OR (evergreen.org_top()).shortname = $5)
                                          ORDER BY rank_avail, COALESCE(cp.copy_number,0), cp.barcode
                                          LIMIT ($7 -> 'acp')::INT
                                          OFFSET ($8 -> 'acp')::INT
                                    )x)
                                )
                            ELSE
                                XMLELEMENT( name copies,
                                    (SELECT XMLAGG(acp ORDER BY rank_avail) FROM (
                                        SELECT  unapi.acp( cp.id, 'xml', 'copy', array_remove($4,'acn'), $5, $6, $7, $8, FALSE),
                                            evergreen.rank_cp(cp) AS rank_avail
                                          FROM  asset.copy cp
                                                LEFT JOIN actor.org_unit_descendants( (SELECT id FROM actor.org_unit WHERE shortname = $5) ) aoud ON (cp.circ_lib = aoud.id)
                                          WHERE cp.call_number = acn.id
                                              AND cp.deleted IS FALSE
                                              AND (aoud.id IS NULL OR (evergreen.org_top()).shortname = $5)
                                          ORDER BY rank_avail, COALESCE(cp.copy_number,0), cp.barcode
                                          LIMIT ($7 -> 'acp')::INT
                                          OFFSET ($8 -> 'acp')::INT
                                    )x)
                                )
                            END
                        ELSE NULL
                    END,
                    XMLELEMENT(
                        name uris,
                        (SELECT XMLAGG(auri) FROM (SELECT unapi.auri(uri,'xml','uri', array_remove($4,'acn'), $5, $6, $7, $8, FALSE) FROM asset.uri_call_number_map WHERE call_number = acn.id)x)
                    ),
                    unapi.acnp( acn.prefix, 'marcxml', 'prefix', array_remove($4,'acn'), $5, $6, $7, $8, FALSE),
                    unapi.acns( acn.suffix, 'marcxml', 'suffix', array_remove($4,'acn'), $5, $6, $7, $8, FALSE),
                    CASE WHEN ('bre' = ANY ($4)) THEN unapi.bre( acn.record, 'marcxml', 'record', array_remove($4,'acn'), $5, $6, $7, $8, FALSE) ELSE NULL END
                ) AS x
          FROM  asset.call_number acn
                JOIN actor.org_unit o ON (o.id = acn.owning_lib)
          WHERE acn.id = $1
              AND acn.deleted IS FALSE
          GROUP BY acn.id, o.shortname, o.opac_visible, deleted, label, label_sortkey, label_class, owning_lib, record, acn.prefix, acn.suffix;
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION evergreen.ranked_volumes(
    bibid BIGINT[],
    ouid INT,
    depth INT DEFAULT NULL,
    slimit HSTORE DEFAULT NULL,
    soffset HSTORE DEFAULT NULL,
    pref_lib INT DEFAULT NULL,
    includes TEXT[] DEFAULT NULL::TEXT[]
) RETURNS TABLE(id BIGINT, name TEXT, label_sortkey TEXT, rank BIGINT) AS $$
    WITH RECURSIVE ou_depth AS (
        SELECT COALESCE(
            $3,
            (
                SELECT depth
                FROM actor.org_unit_type aout
                    INNER JOIN actor.org_unit ou ON ou_type = aout.id
                WHERE ou.id = $2
            )
        ) AS depth
    ), descendant_depth AS (
        SELECT  ou.id,
                ou.parent_ou,
                out.depth
        FROM  actor.org_unit ou
                JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                JOIN anscestor_depth ad ON (ad.id = ou.id),
                ou_depth
        WHERE ad.depth = ou_depth.depth
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
        WHERE ou.id = $2
            UNION ALL
        SELECT  ou.id,
                ou.parent_ou,
                out.depth
        FROM  actor.org_unit ou
                JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                JOIN anscestor_depth ot ON (ot.parent_ou = ou.id)
    ), descendants as (
        SELECT ou.* FROM actor.org_unit ou JOIN descendant_depth USING (id)
    )

    SELECT ua.id, ua.name, ua.label_sortkey, MIN(ua.rank) AS rank FROM (
        SELECT acn.id, owning_lib.name, acn.label_sortkey,
            evergreen.rank_cp(acp),
            RANK() OVER w
        FROM asset.call_number acn
            JOIN asset.copy acp ON (acn.id = acp.call_number)
            LEFT JOIN descendants AS aou ON (acp.circ_lib = aou.id)
            JOIN actor.org_unit AS owning_lib ON (acn.owning_lib = owning_lib.id)
        WHERE acn.record = ANY ($1)
            AND (aou.id IS NULL OR $2 = (evergreen.org_top()).id)
            AND acn.deleted IS FALSE
            AND acp.deleted IS FALSE
            AND CASE WHEN ('exclude_invisible_acn' = ANY($7)) THEN
                EXISTS (
                    WITH basevm AS (SELECT c_attrs FROM  asset.patron_default_visibility_mask()),
                         circvm AS (SELECT search.calculate_visibility_attribute_test('circ_lib', ARRAY[acp.circ_lib]) AS mask)
                    SELECT  1
                      FROM  basevm, circvm, asset.copy_vis_attr_cache acvac
                      WHERE acvac.vis_attr_vector @@ (basevm.c_attrs || '&' || circvm.mask)::query_int
                            AND acvac.target_copy = acp.id
                            AND acvac.record = acn.record
                ) ELSE TRUE END
        GROUP BY acn.id, evergreen.rank_cp(acp), owning_lib.name, acn.label_sortkey, aou.id
        WINDOW w AS (
            ORDER BY
                COALESCE(
                    CASE WHEN aou.id = $2 THEN -20000 END,
                    CASE WHEN aou.id = $6 THEN -10000 END,
                    (SELECT distance - 5000
                        FROM actor.org_unit_descendants_distance($6) as x
                        WHERE x.id = aou.id AND $6 IN (
                            SELECT q.id FROM actor.org_unit_descendants($2) as q)),
                    (SELECT e.distance FROM actor.org_unit_descendants_distance($2) as e WHERE e.id = aou.id),
                    1000
                ),
                evergreen.rank_cp(acp)
        )
    ) AS ua
    GROUP BY ua.id, ua.name, ua.label_sortkey
    ORDER BY rank, ua.name, ua.label_sortkey
    LIMIT ($4 -> 'acn')::INT
    OFFSET ($5 -> 'acn')::INT;
$$ LANGUAGE SQL STABLE ROWS 10;

COMMIT;

