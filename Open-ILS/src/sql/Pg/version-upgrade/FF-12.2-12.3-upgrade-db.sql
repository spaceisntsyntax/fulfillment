\set ON_ERROR_STOP on
\set eg_version '''FF-12.3'''

BEGIN;

       
-- XXX: Change workstation to usr, and cwst to cust, if
-- we decide on user settings instead of WS settings.
INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES
(
    'eg.grid.ff.ill.top-titles.to_patrons', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.top-titles.to_patrons',
        'Grid Config: ILL Top Titles to my patrons',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.top-titles.from_items', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.top-titles.from_items',
        'Grid Config: ILL Top Titles of my items',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.my-requests.canceled', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.my-requests.canceled',
        'Grid Config: Recently Canceled ILL Requests',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.my-requests.suspended', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.my-requests.suspended',
        'Grid Config: Suspended ILL Requests',
        'cwst', 'label')
),(
    'eg.grid.ff.ill.my-requests.overdue', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.ff.ill.my-requests.overdue',
        'Grid Config: Long Unfilled ILL Requests',
        'cwst', 'label')
),(
    'ff.pending.my-requests.overdueDays', 'gui', 'object',
    oils_i18n_gettext(
        'ff.pending.my-requests.overdueDays',
        'Grid Config: last Long Unfilled filter value',
        'cwst', 'label')
),(
    'ff.pending.my-requests.showRecentlyCanceledDays', 'gui', 'object',
    oils_i18n_gettext(
        'ff.pending.my-requests.showRecentlyCanceledDays',
        'Grid Config: last Recently Canceled filter value',
        'cwst', 'label')
);

COMMIT;

