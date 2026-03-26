import {Injectable, EventEmitter} from '@angular/core';
import {Router, ActivatedRoute, NavigationEnd} from '@angular/router';
import {empty, Observable} from 'rxjs';
import {OrgService} from '@eg/core/org.service';
import {NetService} from '@eg/core/net.service';
import {AuthService} from '@eg/core/auth.service';
import {EventService, EgEvent} from '@eg/core/event.service';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {StoreService} from '@eg/core/store.service';
import {PatronService, PatronSummary, PatronStats} from '@eg/staff/share/patron/patron.service';
import {AudioService} from '@eg/share/util/audio.service';
import {StringService} from '@eg/share/string/string.service';
import {PcrudService} from '@eg/core/pcrud.service';

const LOST = 3;
const WARNING_TIMEOUT = 20;
const PATRON_IDLE_TIMEOUT = 160;

export interface ActionContext {
    wideDisplayFields?: IdlObject;
    copy?: IdlObject;
    hold?: IdlObject;
    hold_blocks?: IdlObject[];
    rejections?: IdlObject[];
    transit?: IdlObject;
    circ?: IdlObject;
    next_action?: string;
    barcode?: string; // copy
    username?: string; // patron username or barcode
    can_retarget_hold?: boolean;
    can_cancel_hold?: boolean;
    can_mark_lost?: boolean;
    open_transit?: boolean;
    open_hold?: boolean;
    open_circ?: boolean;
    result?: any;
    firstEvent?: EgEvent;
    payload?: any;
    override?: boolean;
    blocked?: boolean;
    redo?: boolean;
    renew?: boolean;
    displayText?: string; // string key
    alertSound?: string;
    shouldPopup?: boolean;
    previousCirc?: IdlObject;
    renewalFailure?: boolean;
    newCirc?: IdlObject;
    external?: boolean; // not from main checkout input.
    renewSuccessCount?: number;
    renewFailCount?: number;
}

const CIRC_FLESH_DEPTH = 4;
const CIRC_FLESH_FIELDS = {
    circ: ['target_copy'],
    acp:  ['call_number'],
    acn:  ['record'],
    bre:  ['flat_display_entries']
};

@Injectable({providedIn: 'root'})
export class ILLService {

    // Currently active patron account object.
    patronSummary: PatronSummary;
    statusDisplayText = '';
    statusDisplaySuccess: boolean;

    barcodeRegex: RegExp;
    patronPasswordRequired = false;
    patronIdleTimeout: number;
    patronTimeoutId: ReturnType<typeof setTimeout>;
    logoutWarningTimeout = WARNING_TIMEOUT;
    logoutWarningTimerId: ReturnType<typeof setTimeout>;

    alertAudio = false;
    alertPopup = false;
    orgSettings: any;
    overrideCheckoutEvents: string[] = [];
    blockStatuses: number[] = [];

    currentAction: ActionContext;
    previousActions: ActionContext[] = [];

    // We get this from the main scko component.
    focusBarcode: EventEmitter<void> = new EventEmitter<void>();
    patronLoaded: EventEmitter<void> = new EventEmitter<void>();

    constructor(
        private router: Router,
        private route: ActivatedRoute,
        private org: OrgService,
        private net: NetService,
        private evt: EventService,
        public auth: AuthService,
        private pcrud: PcrudService,
        private audio: AudioService,
        private strings: StringService,
        private patrons: PatronService,
        private idl: IdlService,
    ) {}

    logoutStaff() {
        this.resetPatron();
        this.auth.logout();
        this.router.navigate(['/staff/selfcheck']);
    }

    fetchWebActionPrintTemplate(focus: string, contextOrg?: number): Promise<any> {
        contextOrg ||= this.auth.user().ws_ou();
        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.web_action_print_template.fetch',
            contextOrg, focus
        ).toPromise();
    }

    checkin(cp: number, action?: string, contextOrg?: number): Promise<any> {
        contextOrg ||= this.auth.user().ws_ou();
        return this.circAPIRequest(
            'open-ils.circ.checkin.override',
            { circ_lib : contextOrg, copy_id: cp, ff_action: action }
        ).then(resp => {
            // If any response events are non-success, report the
            // checkin as a failure.
            let success = true;
            [].concat(resp).forEach(evt => {
                console.debug('Checkin returned', resp);

                const code = evt.textcode;
                if (code !== 'SUCCESS' && code !== 'NO_CHANGE' && code !== 'ROUTE_ITEM') {
                    success = false;
                }
            });

            return success;
        });
    }

    circAPIRequest(method: string, ...args: any[]): Promise<any> {
        return this.net.request('open-ils.circ', method, this.auth.token(), ...args).toPromise();
    }

    checkout(cp: number, patron: number, action?: string, contextOrg?: number): Promise<any> {
        contextOrg ||= this.auth.user().ws_ou();
        return this.circAPIRequest(
            'open-ils.circ.checkout.full.override',
            { patron_id: patron, circ_lib : contextOrg, copy_id: cp, ff_action: action }
        );
    }

    cancel(hold_id: number): Promise<any> {
        return this.circAPIRequest( 'open-ils.circ.hold.cancel', hold_id);
    }

    retarget(hold_id: number): Promise<any> {
        return this.circAPIRequest( 'open-ils.circ.hold.reset', hold_id);
    }

    resolveNextActionByTabAndRole(tab: string, role: string) {
        switch (tab) {
            case 'pending':
                if (role === 'lender') {
                    return 'ill-home-capture';
                }
                break;

            case 'incoming':
                if (role === 'borrower') {
                    return 'ill-foreign-receive';
                }
                return 'transit-home-receive';
                break;

            case 'onshelf':
                if (role === 'borrower') {
                    return 'ill-foreign-checkout';
                }
                break;

            case 'circulating':
                if (role === 'borrower') {
                    return 'ill-foreign-checkin';
                }
                break;

            case 'outgoing': // no default next action
            default:
                break;
        }
        
        return null;
    }

    getTransactionDispositionByBarcode(barcode: string, contextOrg?: number): Promise<any> {
        contextOrg ||= this.auth.user().ws_ou();
        const dispoList: ActionContext[] = [];

        return this.circAPIRequest(
            'open-ils.circ.item.transaction.disposition',
            contextOrg, barcode
        ).then(items => {
            if (!items || !items[0]) {
                return null;
            }

            items.forEach( i => {
                if (i.copy) {
                    // Flesh out copy libs
                    i.copy.circ_lib(this.org.get(i.copy.circ_lib()));
                    i.copy.source_lib(this.org.get(i.copy.source_lib()));

                    // Flesh out CN lib
                    i.copy.call_number().owning_lib(this.org.get(i.copy.call_number().owning_lib()));

                    // Flesh out bib lib
                    i.copy.call_number().record().owner(this.org.get(i.copy.call_number().record().owner()));

                    // Flesh out hold and circ libs
                    if (i.circ) {
                        i.circ.circ_lib(this.org.get(i.circ.circ_lib()));
                    }
                    if (i.hold) {
                        i.hold.request_lib(this.org.get(i.hold.request_lib()));
                        i.hold.pickup_lib(this.org.get(i.hold.pickup_lib()));
                        if (i.hold.current_shelf_lib()) {
                            i.hold.current_shelf_lib(this.org.get(i.hold.current_shelf_lib()));
                        }

                        if (i.hold.transit() && !i.transit) { // copy the transit "up"
                            i.transit = i.hold.transit();
                        }
                    }
                }

                dispoList.push({
                    wideDisplayFields: i.copy?.call_number().record().wide_display_entry() || i.copy?.call_number().record().simple_record() || null,
                    copy: i.copy || null,
                    hold: i.hold || null,
                    hold_blocks: i.hold_blocks || [],
                    rejections: i.rejections || [],
                    transit: i.transit || null,
                    circ: i.circ || null,
                    next_action: i.next_action || null,
                    barcode: barcode,
                    can_retarget_hold: !!i.can_retarget_hold,
                    can_cancel_hold: !!i.can_cancel_hold,

                    can_mark_lost: (i.circ && i.copy?.status().id() == 1),
                    open_circ: !!(i.circ && !(i.circ.checkin_time())),
                    open_transit: !!(i.transit && !(i.transit?.dest_recv_time() || i.transit?.cancel_time())),
                    open_hold: !!(i.hold && !(i.hold.fulfillment_time() || i.hold.cancel_time()))
                });

            });

            return dispoList;
        }).then(list => {
            return this.pcrud.search(
                'acbh', {item: list.map(i => i.copy.id()), hold:null},
                {}, {atomic: true}
            ).toPromise().then(blocks => {
                const blocked_item_ids = blocks.map(b => b.item());
                dispoList.forEach(d => d.blocked = !!blocked_item_ids.includes(d.copy.id()));
                return dispoList;
            });
        });

    }

    resetPatron() {
        this.statusDisplayText = '';
        this.patronSummary = null;
    }

    load(): Promise<any> {

        // Note we cannot use server-store unless we are logged
        // in with a workstation.
        return this.org.settings([
            'opac.barcode_regex',
            'circ.selfcheck.auto_override_checkout_events',
            'circ.selfcheck.patron_password_required',
            'circ.checkout_auto_renew_age',
            'circ.selfcheck.workstation_required',
            'circ.selfcheck.alert.popup',
            'circ.selfcheck.alert.sound',
            'credit.payments.allow',
            'circ.selfcheck.block_checkout_on_copy_status'
        ]).then(sets => {
            this.orgSettings = sets;

            const regPattern = sets['opac.barcode_regex'] || /^\d/;
            this.barcodeRegex = new RegExp(regPattern);
            this.patronPasswordRequired =
                sets['circ.selfcheck.patron_password_required'];

            this.alertAudio = sets['circ.selfcheck.alert.sound'];
            this.alertPopup = sets['circ.selfcheck.alert.popup'];

            this.overrideCheckoutEvents =
                sets['circ.selfcheck.auto_override_checkout_events'] || [];

            this.blockStatuses =
                sets['circ.selfcheck.block_checkout_on_copy_status'] ?
                    sets['circ.selfcheck.block_checkout_on_copy_status'].map(s => Number(s)) :
                    [];

            // Load a patron by barcode via URL params.
            // Useful for development.
            const username = this.route.snapshot.queryParamMap.get('patron');

            return this.loadPatron(username);
        }).catch(_ => {}); // console errors
    }

    getFleshedCircs(circIds: number[]): Observable<IdlObject> {
        if (circIds.length === 0) { return empty(); }

        return this.pcrud.search('circ', {id: circIds}, {
            flesh: CIRC_FLESH_DEPTH,
            flesh_fields: CIRC_FLESH_FIELDS,
            order_by : {circ : 'due_date'},
            select: {bre : ['id']}
        });
    }

    getFleshedCirc(circId: number): Promise<IdlObject> {
        return this.getFleshedCircs([circId]).toPromise();
    }

    loadPatron(username: string, password?: string): Promise<any> {
        this.resetPatron();

        if (!username) { return; }

        let barcode;
        if (username.match(this.barcodeRegex)) {
            barcode = username;
            username = null;
        }

        if (!this.patronPasswordRequired) {
            return this.fetchPatron(username, barcode);
        }

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.verify_user_password',
            this.auth.token(), barcode, username, null, password
        ).toPromise().then(verified => {
            if (Number(verified) === 1) {
                return this.fetchPatron(username, barcode);
            } else {
                return Promise.reject('Bad password');
            }
        });
    }

    fetchPatron(username: string, barcode: string, id?: number): Promise<any> {
        if (id) {
            return this.loadPatronById(id);
        }

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.user.retrieve_id_by_barcode_or_username',
            this.auth.token(), barcode, username
        ).toPromise().then(patronId => {
            const evt = this.evt.parse(patronId);

            if (evt || !patronId) {
                console.error('Cannot find user: ', evt);
                return Promise.reject('User not found');
            }

            return this.loadPatronById(patronId);
        });
    }

    loadPatronById(patronId: number): Promise<any> {
        return this.patrons.getFleshedById(patronId)
            .then(patron => this.patronSummary = new PatronSummary(patron))
            .then(_ => this.patrons.getVitalStats(this.patronSummary.patron))
            .then(stats => this.patronSummary.stats = stats)
            .then(_ => this.patronLoaded.emit());
    }


    getErrorDisplyText(evt: EgEvent): string {

        switch (evt.textcode) {
            case 'PATRON_EXCEEDS_CHECKOUT_COUNT':
                return 'scko.error.patron_exceeds_checkout_count';
            case 'MAX_RENEWALS_REACHED':
                return 'scko.error.max_renewals';
            case 'ITEM_NOT_CATALOGED':
                return 'scko.error.item_not_cataloged';
            case 'COPY_CIRC_NOT_ALLOWED':
                return 'scko.error.copy_circ_not_allowed';
            case 'OPEN_CIRCULATION_EXISTS':
                return 'scko.error.already_out';
            case 'PATRON_EXCEEDS_FINES':
                return 'scko.error.patron_fines';
            default:
                if (evt.payload && evt.payload.fail_part) {
                    return 'scko.error.' +
                        evt.payload.fail_part.replace(/\./g, '_');
                }
        }

        return 'scko.error.unknown';
    }

    copyIsPrecat(copy: IdlObject): boolean {
        return Number(copy.call_number().id()) === -1;
    }

    copyDisplayValue(cp: IdlObject, field: string): string {
        if (!cp) { return ''; }

        const cp_fields = cp.call_number().record().wide_display_entry()
            || cp.call_number().record().simple_record();

        if (cp_fields && cp_fields[field]) {
            return cp_fields[field]() || '';
        }

        const entry = cp.call_number().record().flat_display_entries().filter(e => e.name() === field)[0];

        return entry ? entry.value() : '';
    }

    getCopyTitle(cp: IdlObject): string {
        if (!cp) { return ''; }
        if (this.copyIsPrecat(cp)) { return cp.dummy_title(); }
        return this.copyDisplayValue(cp, 'title');
    }

    getCopyAuthor(cp: IdlObject): string {
        if (!cp) { return ''; }
        if (this.copyIsPrecat(cp)) { return cp.dummy_author(); }
        return this.copyDisplayValue(cp, 'author');
    }

}



