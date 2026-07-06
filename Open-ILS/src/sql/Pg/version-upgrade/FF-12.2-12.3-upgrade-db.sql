\set ON_ERROR_STOP on
\set eg_version '''FF-12.3'''

BEGIN;

       
-- XXX: Change workstation to usr, and cwst to cust, if
-- we decide on user settings instead of WS settings.
INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES
(
    'eg.grid.ff.ill.toptitles.to_patrons', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.toptitles.to_patrons',
        'Grid Config: ILL Top Titles to my patrons',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.toptitles.from_items', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.toptitles.from_items',
        'Grid Config: ILL Top Titles of my items',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.myrequests.canceled', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.myrequests.canceled',
        'Grid Config: Recently Canceled ILL Requests',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.myrequests.suspended', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.myrequests.suspended',
        'Grid Config: Suspended ILL Requests',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.myrequests.overdue', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.myrequests.overdue',
        'Grid Config: Long Unfilled ILL Requests',
        'cwst', 'label')
),(
    'ff.pending.myrequests.overdueDays', 'gui', 'string',
    oils_i18n_gettext(
        'ff.pending.myrequests.overdueDays',
        'Grid Config: last Long Unfilled filter value',
        'cwst', 'label')
),(
    'ff.pending.myrequests.showRecentlyCanceledDays', 'gui', 'string',
    oils_i18n_gettext(
        'ff.pending.myrequests.showRecentlyCanceledDays',
        'Grid Config: last Recently Canceled filter value',
        'cwst', 'label')
);

COMMIT;

