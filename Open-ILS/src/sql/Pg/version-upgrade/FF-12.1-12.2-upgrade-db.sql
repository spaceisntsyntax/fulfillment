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

COMMIT;

