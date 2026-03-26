import {Component, OnInit, Input, Output, EventEmitter, ViewChild} from '@angular/core';
import {Location} from '@angular/common';
import {Observable, Observer, of, from, concatMap} from 'rxjs';
import {IdlObject} from '@eg/core/idl.service';
import {NetService} from '@eg/core/net.service';
import {OrgService} from '@eg/core/org.service';
import {AuthService} from '@eg/core/auth.service';
import {Pager} from '@eg/share/util/pager';
import {ServerStoreService} from '@eg/core/server-store.service';
import {GridDataSource, GridCellTextGenerator} from '@eg/share/grid/grid';
import {GridComponent} from '@eg/share/grid/grid.component';
import {ProgressDialogComponent} from '@eg/share/dialog/progress.component';
import {ConfirmDialogComponent} from '@eg/share/dialog/confirm.component';
import {MarkDamagedDialogComponent} from '@eg/staff/share/holdings/mark-damaged-dialog.component';
import {MarkMissingDialogComponent} from '@eg/staff/share/holdings/mark-missing-dialog.component';
import {MarkDiscardDialogComponent} from '@eg/staff/share/holdings/mark-discard-dialog.component';
import {HoldRetargetDialogComponent} from '@eg/staff/share/holds/retarget-dialog.component';
import {HoldCaptureDialogComponent} from '@eg/staff/share/holds/capture-dialog.component';
import {HoldTransferDialogComponent} from './transfer-dialog.component';
import {HoldCancelDialogComponent} from './cancel-dialog.component';
import {HoldManageDialogComponent} from './manage-dialog.component';
import {PrintService} from '@eg/share/print/print.service';
import {HoldingsService} from '@eg/staff/share/holdings/holdings.service';
import {OrgSelectComponent} from '@eg/share/org-select/org-select.component';
import {ComboboxEntry} from '@eg/share/combobox/combobox.component';
import {HoldCopyLocationsDialogComponent} from './copy-locations-dialog.component';
import deepEqual from 'deep-equal';

/** Holds grid with access to detail page and other actions */

@Component({
    selector: 'eg-holds-grid',
    templateUrl: 'grid.component.html',
    styles: ['.input-group > .form-control { width: auto; flex-grow: 0; }']
})
export class HoldsGridComponent implements OnInit {

    @Input() pageSize: number = null;
    @Input() defaultDatePlusTime: boolean;

    // link to singlescan in ILL mode
    @Input() illMode = false;
    @Input() ill_role: string = null;

    // Hide the "Holds Count" header
    @Input() hideHoldsCount = false;

    @Input() hideILLActions = false;

    // If either are set/true, the pickup lib selector will display
    @Input() initialPickupLib: number | IdlObject;
    @Input() hidePickupLibFilter: boolean;

    // Setting a value here puts us into "pull list" mode ...
    @Input() pullListOrg: number;
    // but setting this to true disables that.
    @Input() hidePullListLibFilter: boolean;

    @Input() hidePrintPullList = false;

    // If true, only retrieve holds with a Hopeless Date
    // and enable related Actions
    @Input() hopeless: boolean;

    // Grid persist key
    @Input() persistKey: string;

    @Input() preFetchSetting: string;

    @Input() printTemplate: string;

    // Adds a Place Hold grid toolbar button that emits
    // placeHoldRequested on click.
    @Input() showPlaceHoldButton = false;

    // If set, all holds are fetched on grid load and sorting/paging all
    // happens in the client.  If false, sorting and paging occur on
    // the server.
    @Input() enablePreFetch: boolean;

    // How to sort when no sort parameters have been applied
    // via grid controls.  This uses the eg-grid sort format:
    // [{name: fname, dir: 'asc'}, {name: fname2, dir: 'desc'}]
    @Input() defaultSort: any[];

    // To pass through to the underlying eg-grid
    @Input() showFields: string;

    // Display bib record summary along the top of the detail page.
    @Input() showRecordSummary = false;

    // If true, avoid popping up the progress dialog.  Note the grid
    // has it's own generic embedded 'loading' progress indicator.
    @Input() noLoadProgress = false;

    // Some default columns and actions do or don't make sense when
    // displaying holds for a specific patron vs. e.g. a specific title.
    @Input() patronFocused = false;

    @Input() currentShelfLib: any;
    @Input() copyCircLib: any;

    @Input() showCaptureAction = false;

    // Additional action menu options, added at the top of the menu or group
    // [{ label: string, method: function(any[]), group: string }, ...]
    @Input() customActions: any[];

    // Additional toolbar buttons, added at the end of the toolbar
    // [{ label: string, method: function(any[]) }, ...]
    @Input() customButtons: any[];

    mode: 'list' | 'detail' | 'manage' = 'list';
    initDone = false;
    holdsCount: number;
    pickupLib: IdlObject;
    plCompLoaded = false;
    gridDataSource: GridDataSource;
    detailHold: any;
    editHolds: number[];
    transferTarget: number;
    uncancelHoldCount: number;
    copyLocationClass?: string;
    copyLocationEntries: ComboboxEntry[] = [];
    copyLocationIds: number[] = [];

    @ViewChild('holdsGrid', { static: false }) private holdsGrid: GridComponent;
    @ViewChild('progressDialog', { static: true })
    private progressDialog: ProgressDialogComponent;
    @ViewChild('transferDialog', { static: true })
    private transferDialog: HoldTransferDialogComponent;
    @ViewChild('markDamagedDialog', { static: true })
    private markDamagedDialog: MarkDamagedDialogComponent;
    @ViewChild('markMissingDialog', { static: true })
    private markMissingDialog: MarkMissingDialogComponent;
    @ViewChild('markDiscardDialog')
    private markDiscardDialog: MarkDiscardDialogComponent;
    @ViewChild('captureDialog', { static: true })
    private captureDialog: HoldCaptureDialogComponent;
    @ViewChild('retargetDialog', { static: true })
    private retargetDialog: HoldRetargetDialogComponent;
    @ViewChild('cancelDialog', { static: true })
    private cancelDialog: HoldCancelDialogComponent;
    @ViewChild('manageDialog', { static: true })
    private manageDialog: HoldManageDialogComponent;
    @ViewChild('uncancelDialog') private uncancelDialog: ConfirmDialogComponent;
    @ViewChild('copyLocationsDialog')
    private copyLocationsDialog: HoldCopyLocationsDialogComponent;
    @ViewChild('clearCopyLocationsDialog')
    private clearCopyLocationsDialog: ConfirmDialogComponent;
    @ViewChild('pullPickupLibFilter')
    private pullPickupLibFilter: OrgSelectComponent;

    // Bib record ID.
    _recordId: number;
    @Input() set recordId(id: number) {
        this._recordId = id;
        if (this.initDone) { // reload on update
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    get recordId(): number {
        return this._recordId;
    }

    _patronId: number;
    @Input() set patronId(id: number) {
        this._patronId = id;
        if (this.initDone) {
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }
    get patronId(): number {
        return this._patronId;
    }

    // If true, show recently canceled holds only.
    @Input() showRecentlyCanceled = false;

    // If true, do NOT show captured holds
    @Input() excludeCaptured = false;

    // Include holds fulfilled on or after hte provided date.
    // If no value is passed, fulfilled holds are not displayed.
    _showFulfilledSince: Date;
    @Input() set showFulfilledSince(show: Date) {
        this._showFulfilledSince = show;
        if (this.initDone) { // reload on update
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }
    get showFulfilledSince(): Date {
        return this._showFulfilledSince;
    }


    cellTextGenerator: GridCellTextGenerator;

    // Include holds marked Hopeless on or after this date.
    _showHopelessAfter: Date;
    @Input() set showHopelessAfter(show: Date) {
        this._showHopelessAfter = show;
        if (this.initDone) { // reload on update
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    // Include holds marked Hopeless on or before this date.
    _showHopelessBefore: Date;
    @Input() set showHopelessBefore(show: Date) {
        this._showHopelessBefore = show;
        if (this.initDone) { // reload on update
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    // Notify the caller the place hold button was clicked.
    @Output() placeHoldRequested: EventEmitter<void> = new EventEmitter<void>();

    _prev_rows = [];
    _prev_pager = {};
    _prev_filters = {};
    _prev_options = {};

    constructor(
        private ngLocation: Location,
        private net: NetService,
        private org: OrgService,
        private store: ServerStoreService,
        private auth: AuthService,
        private printer: PrintService,
        private holdings: HoldingsService
    ) {
        this.gridDataSource = new GridDataSource();
    }

    ngOnInit() {
        this.initDone = true;
        this.pickupLib = this.org.get(this.initialPickupLib);
        this.hidePullListLibFilter ||= this.pullListOrg ? false : true;

        if (this.pullListOrg && this.hidePullListLibFilter) {
            this.plCompLoaded = true;
        }

        if (this.preFetchSetting) {
            this.store.getItem(this.preFetchSetting).then(
                applied => this.enablePreFetch = Boolean(applied)
            );
        } else {
            this.enablePreFetch = this.enablePreFetch ? true : false;
        }

        if (!this.defaultSort) {
            if (this.pullListOrg) {

                this.defaultSort = [
                    {name: 'copy_location_order_position', dir: 'asc'},
                    {name: 'acpl_name', dir: 'asc'},
                    {name: 'ancp_label', dir: 'asc'}, // NOTE: API typo "ancp"
                    {name: 'cn_label_sortkey', dir: 'asc'},
                    {name: 'ancs_label', dir: 'asc'} // NOTE: API typo "ancs"
                ];

            } else {
                this.defaultSort = [{name: 'request_time', dir: 'asc'}];
            }
        }

        this.gridDataSource.getRows = (pager: Pager, sort: any[]) => {

            if (!this.hidePickupLibFilter || this.pullListOrg) {
                // When the pickup lib selector is active, avoid any
                // data fetches until it has settled on a default value.
                // Once the final value is applied, its onchange will
                // fire and we'll be back here with plCompLoaded=true.
                if (!this.plCompLoaded) {return of([]);}
            }

            sort = sort.length > 0 ? sort : this.defaultSort;
            return this.fetchHolds(pager, sort);
        };

        // Text-ify function for cells that use display templates.
        this.cellTextGenerator = {
            title: row => row.title,
            // eslint-disable-next-line eqeqeq
            cp_barcode: row => (row.cp_barcode == null) ? '' : row.cp_barcode,
            current_item: row => row.current_copy ? row.cp_barcode : '',
            requested_item: row => this.isCopyHold(row) ? row.cp_barcode : '',
            ucard_barcode: row => row.ucard_barcode,
            status_string: row => {
                switch (row.hold_status) {
                    /* eslint-disable no-magic-numbers */
                    case 1:
                        return $localize`Waiting for Item`;
                    case 2:
                        return $localize`Waiting for Capture`;
                    case 3:
                        return $localize`In Transit`;
                    case 4:
                        return $localize`Ready for Pickup`;
                    case 5:
                        return $localize`Hold Shelf Delay`;
                    case 6:
                        return $localize`Canceled`;
                    case 7:
                        return $localize`Suspended`;
                    case 8:
                        return $localize`Wrong Shelf`;
                    case 9:
                        return $localize`Fulfilled`;
                    default:
                        return $localize`Unknown Error`;
                    /* eslint-enable no-magic-numbers */
                }
            }
        };

        if (this.pullListOrg) {
            this.store.getItem('eg.holds.pull_list_filters').then(data => {
                if (data) {
                    this.copyLocationClass = data.copyLocationClass;
                    this.copyLocationEntries = data.copyLocationEntries;
                    this.copyLocationIds = data.copyLocationIds;
                    if (data.pickupLib) {
                        this.pickupLib = this.org.get(data.pickupLib);
                    }
                } else {
                    this.copyLocationClass = 'acpl';
                }
            });
        }
    }

    customMethodCallback(method, rows) {
        method(rows);
        this._prev_rows = [];
        this.holdsGrid.reload();
    }

    // Returns true after all data/settings/etc required to render the
    // grid have been fetched.
    initComplete(): boolean {
        return this.enablePreFetch !== null;
    }

    pickupLibChanged(org: IdlObject) {
        this.pickupLib = org;
        this._prev_rows = [];
        this.holdsGrid.reload();
    }

    pullPickupLibLoaded(): void {
        this.plCompLoaded = true;
        this._prev_rows = [];
        this.holdsGrid.reload();
    }

    resetPullPickupLibFilter(): void {
        if (this.pickupLib) {
            this.pullPickupLibFilter.reset();
        }
    }

    pullPickupLibChanged(org: IdlObject): void {
        if (org?.id() !== this.pickupLib?.id()) {
            this.pickupLib = org;
            this.savePullFilterSettings();
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    openCopyLocationsDialog(): void {
        this.copyLocationsDialog.init();
        this.copyLocationsDialog.open({size: 'lg'}).subscribe(
            ([fmClass, entries, ids]) => {
                this.copyLocationClass = fmClass;
                this.copyLocationEntries = entries;
                this.copyLocationIds = ids;
                this.savePullFilterSettings();
                this._prev_rows = [];
                this.holdsGrid.reload();
            }
        );
    }

    clearCopyLocations(): void {
        if (!this.copyLocationEntries.length) {return;}
        this.clearCopyLocationsDialog.open().subscribe(data => {
            if (data) {
                this.copyLocationClass = 'acpl';
                this.copyLocationEntries = [];
                this.copyLocationIds = [];
                this.savePullFilterSettings();
                this._prev_rows = [];
                this.holdsGrid.reload();
            }
        });
    }

    pullListSettingsLoaded(): boolean {
        return !!this.copyLocationClass;
    }

    savePullFilterSettings(): void {
        this.store.setItem('eg.holds.pull_list_filters', {
            copyLocationClass: this.copyLocationClass,
            copyLocationEntries: this.copyLocationEntries,
            copyLocationIds: this.copyLocationIds,
            pickupLib: this.pickupLib ? +this.pickupLib.id() : undefined
        });
    }

    pullListOrgChanged(org: IdlObject): void {
        if (org && +org.id() !== +this.pullListOrg) {
            this.pullListOrg = org.id();
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    preFetchHolds(apply: boolean) {
        this.enablePreFetch = apply;

        if (apply) {
            this._prev_rows = [];
            setTimeout(() => this.holdsGrid.reload());
        }

        if (this.preFetchSetting) {
            // fire and forget
            this.store.setItem(this.preFetchSetting, apply);
        }
    }

    applyFilters(): any {

        const filters: any = {};

        if (this.copyLocationIds.length) {
            filters['acpl.id'] = this.copyLocationIds;
        }

        if (this.copyCircLib) {
            filters['cp.circ_lib'] = this.copyCircLib;
        }

        if (this.currentShelfLib) {
            filters['h.current_shelf_lib'] = this.currentShelfLib;
        }

        if (this.copyLocationIds.length) {
            filters['acpl.id'] = this.copyLocationIds;
        }

        if (this.pickupLib) {
            filters.pickup_lib =
                this.org.descendants(this.pickupLib, true);
        }

        if (this.pullListOrg) {
            filters.cancel_time = null;
            filters.capture_time = null;
            filters.frozen = 'f';

            // cp.* fields are set for copy-level holds even if they
            // have no current_copy.  Make sure current_copy is set.
            filters.current_copy = {'is not': null};

            // There are aliases for these (cp_status, cp_circ_lib),
            // but the API complains when I use them.
            filters['cp.status'] = {'in':{'select':{'ccs':['id']},'from':'ccs','where':{'holdable':'t','is_available':'t'}}};
            filters['cp.circ_lib'] = this.pullListOrg;
            // Avoid deleted copies AND this uses a database index on copy circ_lib where deleted is false.
            filters['cp.deleted'] = 'f';

            return filters;
        }

        if (this._showFulfilledSince) {
            filters.fulfillment_time = this._showFulfilledSince.toISOString();
        } else {
            filters.fulfillment_time = null;
        }


        if (this.hopeless) {
            filters['hopeless_holds'] = {
                'start_date' : this._showHopelessAfter
                    ? (
                // FIXME -- consistency desired, string or object
                        typeof this._showHopelessAfter === 'object'
                            ? this._showHopelessAfter.toISOString()
                            : this._showHopelessAfter
                    )
                    : '1970-01-01T00:00:00.000Z',
                'end_date' : this._showHopelessBefore
                    ? (
                // FIXME -- consistency desired, string or object
                        typeof this._showHopelessBefore === 'object'
                            ? this._showHopelessBefore.toISOString()
                            : this._showHopelessBefore
                    )
                    : (new Date()).toISOString()
            };
        }

        if (this.recordId) {
            filters.record_id = this.recordId;
        }

        if (this.patronId) {
            filters.usr_id = this.patronId;
        }

        return filters;
    }

    fetchHolds(pager: Pager, sort: any[]): Observable<any> {

        const filters = this.applyFilters();

        // We need at least one filter. fulfillment_time comes for free, so length > 1
        if (Object.keys(filters).length <= 1) {
            return new Observable(observer => observer.complete());
        }

        const orderBy: any = [];
        if (sort.length > 0) {
            sort.forEach(obj => {
                const subObj: any = {};
                subObj[obj.name] = {dir: obj.dir, nulls: 'last'};
                orderBy.push(subObj);
            });
        }

        const limit = this.enablePreFetch ? null : pager.limit;
        const offset = this.enablePreFetch ? 0 : pager.offset;
        const options: any = {};
        if (this.showRecentlyCanceled) {
            options.recently_canceled = true;
        } else {
            filters.cancel_time = null;
        }

        if (this.excludeCaptured) {
            filters.capture_time = null;
        }

        let pfStart = Number(pager.offset);
        let pfEnd = pfStart + pager.limit;

        if (this.enablePreFetch) {
            console.debug('prefetch mode start, end:',pfStart,pfEnd);
            if (this._prev_rows.length > 0
                && deepEqual(this._prev_filters, filters)
                && deepEqual(this._prev_options, options)
            ) {
                return new Observable(observer => {
                    this._prev_rows.slice(pfStart, pfEnd).forEach((r) => observer.next(r));
                    observer.complete();
                });
            } else {
                this._prev_rows = [];
                this._prev_pager = {...pager};
                this._prev_filters = {...filters};
                this._prev_options = {...options};
            }
        }

        let observer: Observer<any>;
        const observable = new Observable(obs => observer = obs);

        if (!this.noLoadProgress) {
            // Note remaining dialog actions have no impact
            this.progressDialog.open();
        }

        this.progressDialog.update({value: 0, max: 1});

        let first = true;
        let loadCount = this.holdsCount = 0;
        let currentIndex = 0;
        this.net.request(
            'open-ils.circ',
            'open-ils.circ.hold.wide_hash.stream',
            this.auth.token(), filters, orderBy, limit, offset, options
        ).subscribe(
            { next: holdData => {

                if (first) { // First response is the hold count.
                    console.debug('hold.wide_hash.stream hold count: ', holdData);
                    this.holdsCount = Number(holdData);
                    first = false;

                } else { // Subsequent responses are hold data blobs

                    this.progressDialog.update(
                        {value: ++loadCount, max: this.holdsCount});

                    if (this.enablePreFetch) {
                        this._prev_rows.push({...holdData});
                        if (currentIndex >= pfStart && currentIndex <= pfEnd) {
                            observer.next(holdData);
                        }
                        currentIndex++;
                    } else {
                        observer.next(holdData);
                    }
                }
            }, error: (err: unknown) => {
                this.progressDialog.close();
                observer.error(err);
            }, complete: ()  => {
                this.progressDialog.close();
                observer.complete();
            } }
        );

        return observable;
    }

    metaRecordHoldsSelected(rows: IdlObject[]) {
        let found = false;
        rows.forEach( row => {
            if (row.hold_type === 'M') {
                found = true;
            }
        });
        return found;
    }

    nonTitleHoldsSelected(rows: IdlObject[]) {
        let found = false;
        rows.forEach( row => {
            if (row.hold_type !== 'T') {
                found = true;
            }
        });
        return found;
    }

    showDetails(rows: any[]) {
        this.showDetail(rows[0]);
    }

    showHoldsForTitle(rows: any[]) {
        if (rows.length === 0) { return; }

        const url = this.ngLocation.prepareExternalUrl(
            `/staff/catalog/record/${rows[0].record_id}/holds`);

        window.open(url, '_blank');
    }

    showDetail(row: any) {
        if (row) {
            this.mode = 'detail';
            this.detailHold = row;
        }
    }

    showManager(rows: any[]) {
        if (rows.length) {
            this.mode = 'manage';
            this.editHolds = rows.map(r => r.id);
        }
    }

    handleModify(rowsModified: boolean) {
        this.mode = 'list';

        if (rowsModified) {
            this._prev_rows = [];
            // give the grid a chance to render then ask it to reload
            setTimeout(() => this.holdsGrid.reload());
        }
    }



    showRecentCircs(rows: any[]) {
        const copyIds = Array.from(new Set( rows.map(r => r.cp_id).filter( cp_id => Boolean(cp_id)) ));
        copyIds.forEach( copyId => {
            const url =
                '/eg/staff/cat/item/' + copyId + '/circ_list';
            window.open(url, '_blank');
        });
    }

    showPatron(rows: any[]) {
        const usrIds = Array.from(new Set( rows.map(r => r.usr_id).filter( usr_id => Boolean(usr_id)) ));
        usrIds.forEach( usrId => {
            const url =
                '/eg/staff/circ/patron/' + usrId + '/checkout';
            window.open(url, '_blank');
        });
    }

    showOrder(rows: any[]) {
        // Doesn't work in Typescript currently without compiler option:
        //   const bibIds = [...new Set( rows.map(r => r.record_id) )];
        const bibIds = Array.from(
            new Set( rows.filter(r => r.hold_type !== 'M').map(r => r.record_id) ));
        bibIds.forEach( bibId => {
            const url =
              '/eg/staff/acq/legacy/lineitem/related/' + bibId + '?target=bib';
            window.open(url, '_blank');
        });
    }

    addVolume(rows: any[]) {
        const bibIds = Array.from(
            new Set( rows.filter(r => r.hold_type !== 'M').map(r => r.record_id) ));
        bibIds.forEach( bibId => {
            this.holdings.spawnAddHoldingsUi(bibId);
        });
    }

    showTitle(rows: any[]) {
        const bibIds = Array.from(new Set( rows.map(r => r.record_id) ));
        bibIds.forEach( bibId => {
            // const url = '/eg/staff/cat/catalog/record/' + bibId;
            const url = '/eg/opac/record/' + bibId;
            window.open(url, '_blank');
        });
    }

    showManageDialog(rows: any[]) {
        const holdIds = rows.map(r => r.id).filter(id => Boolean(id));
        if (holdIds.length > 0) {
            this.manageDialog.holdIds = holdIds;
            this.manageDialog.open({size: 'lg'}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    showTransferDialog(rows: any[]) {
        const holdIds = rows.filter(r => r.hold_type === 'T').map(r => r.id).filter(id => Boolean(id));
        if (holdIds.length > 0) {
            this.transferDialog.holdIds = holdIds;
            this.transferDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    async showMarkDamagedDialog(rows: any[]) {
        const copyIds = rows.map(r => r.cp_id).filter(id => Boolean(id));
        if (copyIds.length === 0) { return; }

        let rowsModified = false;

        const markNext = async(ids: number[]) => {
            if (ids.length === 0) {
                return Promise.resolve();
            }

            this.markDamagedDialog.copyId = ids.pop();
            return this.markDamagedDialog.open({size: 'lg'}).subscribe(
                { next: ok => {
                    if (ok) { rowsModified = true; }
                    return markNext(ids);
                }, error: (dismiss: unknown) => markNext(ids) }
            );
        };

        await markNext(copyIds);
        if (rowsModified) {
            this._prev_rows = [];
            this.holdsGrid.reload();
        }
    }

    showMarkMissingDialog(rows: any[]) {
        const copyIds = rows.map(r => r.cp_id).filter(id => Boolean(id));
        if (copyIds.length > 0) {
            this.markMissingDialog.copyIds = copyIds;
            this.markMissingDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    showMarkDiscardDialog(rows: any[]) {
        const copyIds = rows.map(r => r.cp_id).filter(id => Boolean(id));
        if (copyIds.length > 0) {
            this.markDiscardDialog.copyIds = copyIds;
            this.markDiscardDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }


    showCaptureDialog(rows: any[]) {
        const copyIds = rows.map(r => r.cp_id).filter(id => Boolean(id));
        if (copyIds.length > 0) {
            this.captureDialog.copyIds = copyIds;
            this.captureDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    showRetargetDialog(rows: any[]) {
        const holdIds = rows.map(r => r.id).filter(id => Boolean(id));
        if (holdIds.length > 0) {
            this.retargetDialog.holdIds = holdIds;
            this.retargetDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    showCancelDialog(rows: any[]) {
        const holdIds = rows.map(r => r.id).filter(id => Boolean(id));
        if (holdIds.length > 0) {
            this.cancelDialog.holdIds = holdIds;
            this.cancelDialog.open({}).subscribe(
                rowsModified => {
                    if (rowsModified) {
                        this._prev_rows = [];
                        this.holdsGrid.reload();
                    }
                }
            );
        }
    }

    showUncancelDialog(rows: any[]) {
        const holdIds = rows.map(r => r.id).filter(id => Boolean(id));
        if (holdIds.length === 0) { return; }
        this.uncancelHoldCount = holdIds.length;

        this.uncancelDialog.open().subscribe(confirmed => {
            if (!confirmed) { return; }
            this.progressDialog.open();

            from(holdIds).pipe(concatMap(holdId => {
                return this.net.request(
                    'open-ils.circ',
                    'open-ils.circ.hold.uncancel',
                    this.auth.token(), holdId
                );
            // eslint-disable-next-line rxjs-x/no-nested-subscribe
            })).subscribe(
                { next: resp => {
                    if (Number(resp) !== 1) {
                        console.error('Failed uncanceling hold', resp);
                    }
                }, complete: () => {
                    this.progressDialog.close();
                    this._prev_rows = [];
                    this.holdsGrid.reload();
                } }
            );
        });
    }

    printHolds() {
        // Request a page with no limit to get all of the wide holds for
        // printing.  Call requestPage() directly instead of grid.reload()
        // since we may already have the data.

        const pager = new Pager();
        pager.offset = 0;
        pager.limit = null;

        if (this.gridDataSource.sort.length === 0) {
            this.gridDataSource.sort = this.defaultSort;
        }

        this.gridDataSource.requestPage(pager).then(() => {
            if (this.gridDataSource.data.length > 0) {
                this.printer.print({
                    templateName: this.printTemplate || 'holds_for_bib',
                    contextData: this.gridDataSource.data,
                    printContext: 'default'
                });
            }
        });
    }

    isCopyHold(holdData: any): boolean {
        if (holdData && holdData.hold_type) {
            return holdData.hold_type.match(/C|R|F/) !== null;
        }
        return false;
    }
}




