import {Component, OnInit, Input, ViewChild, AfterViewInit } from '@angular/core';
import {lastValueFrom, defaultIfEmpty} from 'rxjs';
import {OrgService} from '@eg/core/org.service';
import {ILLService, ActionContext} from './ill.service';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {DisallowItemComponent, DisallowDialogResult} from './disallow-item.component';

export interface DispositionDetail {
    next_action_step?: string;
    next_action?: string;
    next_action_label?: string;
    needs_capture?: boolean;
    needs_receive?: boolean;
    needs_checkin?: boolean;
    needs_checkout?: boolean;
    can_mark_lost?: boolean;
    can_round_trip?: boolean;
    can_retarget_hold?: boolean;
    can_cancel_hold?: boolean;
    open_transit?: boolean;
    open_hold?: boolean;
    open_circ?: boolean;
    mine?: boolean;
}

@Component({
    templateUrl: 'singlescan.component.html',
    selector: 'ff-singlescan'
})
export class SingleScanComponent implements OnInit, AfterViewInit {

    @Input() contextOrg: number;
    @Input() barcode: string;
    @Input() mode: 'ssts' | 'status' = 'ssts';

    @ViewChild('disallowDialog') private disallowDialog: DisallowItemComponent;

    multipleDispositions: ActionContext[] = []; 
    disposition: ActionContext = null;
    dispositionDetails: DispositionDetail = {};
    notFound = false;
    action_pending = false;

    constructor(
        private idl: IdlService,
        private org: OrgService,
        private ill: ILLService
    ) {}

    ngAfterViewInit() {
        // Initial focus example
        this.setFocus(this.barcode ? 'sstsBarcodeInput' : 'sstsNextActionButton');
    }

    setFocus(selector: string): void {
        setTimeout(() => { document.getElementById(selector)?.focus() });
    }

    ngOnInit() {
        if (this.barcode) {
            this.takeBarcode();
        } else {
            this.setFocus('sstsBarcodeInput');
        }
    }

    only_if_thing_preflight(thing?: string): Promise<any>|null {
        if (thing == 'circ' && !this.disposition.open_circ) {
            return Promise.resolve(true); // if optional thing is 'circ', skip unless there is an open circ
        }

        if (thing == 'hold' && !this.disposition.open_hold) {
            return Promise.resolve(true); // if optional thing is 'hold', skip unless there is an open hold
        }

        if (thing == 'transit' && !this.disposition.open_transit) {
            return Promise.resolve(true); // if optional thing is 'transit', skip unless there is an open transit
        }

        return null;
    }

    swap_dispo(new_active) {
        if (new_active) {
            const old = this.disposition;
            this.disposition = new_active;
            return old;
        }
        return null;
    }

    async popup_block_ill(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);

        this.disallowDialog.barcode = this.disposition.copy.barcode();
        this.disallowDialog.willCancelTransit = this.disposition.open_transit;
        this.disallowDialog.currentlyTargeted = this.disposition.open_hold;

        const result = await lastValueFrom(
            this.disallowDialog.open().pipe(
                defaultIfEmpty({rejected: true})
            )
        );

        if (!result.rejected) {
            const block_scope = result.blockAll ? 'block_all' : 'block_one';
            const block_end = block_scope == 'block_all' ? result.blockStop || null : null;

            if (this.disposition.open_transit) {
                return this.abort_transit().then(() => this[block_scope](result.blockReason, block_end));
            } else {
                return this[block_scope](result.blockReason, block_end);
            }
        } else {
            console.debug('hold blocking canceled');
        }

        return Promise.resolve(true);
    }

    block_one(reason: string, block_end, active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        console.debug('blocking one hold: ' + this.disposition.hold.id());

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.block',
            this.disposition.copy.id(), reason, this.disposition.hold.id()
        ).then(() => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    block_all(reason: string, block_end, active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        console.debug('blocking all holds for barcode '+this.disposition.copy.barcode());

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.block',
            this.disposition.copy.id(), reason, null, block_end
        ).then(() => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    unblock_all(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.unblock',
            this.disposition.copy.id()
        ).then(() => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    toggleHoldActive(frozen: string, active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);

        if (this.disposition.hold.frozen() == frozen) {
            this.swap_dispo(old);
            return Promise.resolve(true);
        }

        this.action_pending = true;

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.update.batch',
            null, [{id: this.disposition.hold.id(), frozen: frozen}]
        ).then(() => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    activate_hold(active_dispo?: ActionContext): Promise<any> {
        return this.toggleHoldActive('f', active_dispo);
    }

    suspend_hold(active_dispo?: ActionContext): Promise<any> {
        return this.toggleHoldActive('t', active_dispo);
    }

    abort_transit(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        return this.ill.circAPIRequest(
            'open-ils.circ.transit.abort',
            {transitid : this.disposition.transit.id()}
        ).then(() => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    mark_lost(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        return this.ill.circAPIRequest(
            'open-ils.circ.circulation.set_lost',
            {barcode : this.disposition.copy.barcode()}
        ).then((resp) => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    retarget(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        return this.ill.retarget(
            this.disposition.hold.id(),
        ).then(response => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    cancel(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        return this.ill.cancel(
            this.disposition.hold.id(),
        ).then(response => {
            this.action_pending = false;
            this.swap_dispo(old);
        }).then(() => this.takeBarcode());
    }

    checkin(active_dispo?: ActionContext, only_if_thing?: string, circ_lib_override?: number): Promise<any> {
        const old = this.swap_dispo(active_dispo);

        const maybe_promise = this.only_if_thing_preflight(only_if_thing);
        if (maybe_promise) {
            this.swap_dispo(old);
            return maybe_promise;
        }

        this.action_pending = true;

        return this.ill.checkin(
            this.disposition.copy.id(),
            this.disposition.next_action,
            circ_lib_override || this.contextOrg
        ).then(response => {
            this.action_pending = false;
            this.swap_dispo(old);

            // do some basic sanity checking before passing
            // the response to the caller.
            if (response) {
                [].concat(response);
                response = response[0];

                // TODO: check for failure events
                return response;
            } else {
                // warn that checkin failed
                return false;
            }
        }).then(() => this.takeBarcode());
    }

    checkout(active_dispo?: ActionContext, only_if_thing?: string, circ_lib_override?: number): Promise<any> {
        const old = this.swap_dispo(active_dispo);

        const maybe_promise = this.only_if_thing_preflight(only_if_thing);
        if (maybe_promise) {
            this.swap_dispo(old);
            return maybe_promise;
        }

        if (!this.disposition.copy && !this.disposition.hold?.usr()?.id()) {
            this.swap_dispo(old);
            return Promise.resolve(true);
        }

        this.action_pending = true;

        return this.ill.checkout(
            this.disposition.copy.id(),
            this.disposition.hold.usr().id(),
            this.disposition.next_action,
            circ_lib_override || this.contextOrg
        ).then(response => {
            this.action_pending = false;
            this.swap_dispo(old);

            // do some basic sanity checking before passing
            // the response to the caller.
            if (response) {
                [].concat(response);
                response = response[0];

                // TODO: check for failure events
                return response;
            } else {
                // warn that checkin failed
                return false;
            }
        }).then(() => this.takeBarcode());
    }

    round_trip(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);

        let remote_circ_lib = this.disposition.transit?.dest()
            || this.disposition.hold?.pickup_lib()
            || this.disposition.circ?.circ_lib();

        if (!remote_circ_lib) {
            console.debug("round_trip: no transaction-related remote org unit found on transit, hold, or circ");
            return Promise.resolve(true);
        }

        this.action_pending = true;

        return this.checkin( this.disposition, 'transit', remote_circ_lib.id() ) // this completes the transit
            .then(() => this.checkout( this.disposition, 'hold', remote_circ_lib.id()) ) // this completes the hold and checks out to the patron
            .then(() => this.checkin( this.disposition, null, remote_circ_lib.id()) ) // this completes the circ and transits back to lender
            .then(() => {
                this.action_pending = false
                this.swap_dispo(old);
            }).then(() => this.takeBarcode());
    }

    print_details(active_dispo?: ActionContext): Promise<any> {
        const old = this.swap_dispo(active_dispo);
        this.action_pending = true;

        let focus = this.disposition.hold ? 'hold' :
            (this.disposition.circ ? 'circ' : (this.disposition.transit ? 'transit' : 'copy'));

        // !!!: line up print template variables with
        // local data structures
        let template_data = {...this.disposition, ...this.idl.toHash(this.disposition, true)};

        if (this.disposition.copy) {
            template_data.barcode = this.disposition.copy.barcode();
            template_data.status = this.disposition.copy.status().name();
            template_data.item_circ_lib = this.disposition.copy.circ_lib().shortname();
            template_data.title = this.ill.getCopyTitle(this.disposition.copy);
            template_data.author = this.ill.getCopyAuthor(this.disposition.copy);
            template_data.call_number = this.disposition.copy.call_number().label();
        }

        if (this.disposition.transit) {
            template_data.transit_source = this.disposition.transit.source().shortname();
            template_data.transit_dest = this.disposition.transit.dest().shortname();
            template_data.transit_time = this.disposition.transit.source_send_time();
            template_data.transit_recv_time = this.disposition.transit.dest_recv_time();
        }

        if (this.disposition.hold) {
            template_data.card = this.disposition.hold.usr().card().barcode();
            template_data['card.barcode'] = template_data.card;
            template_data.patron_card = template_data.card;
            template_data.patron_name = this.formatPatronName(this.disposition.hold.usr());
            template_data.hold_request_usr = this.formatPatronName(this.disposition.hold.usr());
            template_data.hold_request_lib = this.disposition.hold.request_lib().shortname();
            template_data.hold_request_time = this.disposition.hold.request_time();
            template_data.hold_capture_time = this.disposition.hold.capture_time();
            template_data.hold_shelf_time = this.disposition.hold.shelf_time();
            template_data.hold_shelf_expire_time = this.disposition.hold.shelf_expire_time();
            template_data.hold_cancel_time = this.disposition.hold.cancel_time();
            template_data.hold_cancel_cause = this.disposition.hold.cancel_cause()?.label();
        }

        if (this.disposition.circ) {
            template_data.card = this.disposition.circ.usr().card().barcode();
            template_data['card.barcode'] = template_data.card;
            template_data.patron_card = template_data.card;
            template_data.patron_name = this.formatPatronName(this.disposition.circ.usr());
            template_data.circ_usr = template_data.patron_name;
            template_data.patron_id = this.disposition.circ.id();
            template_data.due_date = this.disposition.circ.due_date();
            template_data.circ_circ_lib = this.disposition.circ.circ_lib().shortname();
            template_data.circ_xact_start = this.disposition.circ.xact_start();
            template_data.xact_start = template_data.circ_xact_start
            template_data.circ_stop_fines = this.disposition.circ.stop_fines();
        }

        return this.ill.fetchWebActionPrintTemplate(focus) .then((template) => {

            if (!template || !(template = template.template())) { // assign
                console.warn('unable to find template for ' +
                    template_data.barcode + ' : ' + focus);
                return;
            }

            // !!!: templates stored for now as dojo-style
            // template.  Format is: ${ ... }
            template = template.replace(/\${([^}]+)}/g, (match, key) => {
                key = key.replace(/\s+/g,''); // remove whitespace
                let key_parts = key.split(':');
                let value = template_data[key_parts[0]];
                if (key_parts[1]) {
                    switch (key_parts[1]) {
                        case 'truncate_date': // only one used in stock templates
                            value = value.substring(0,10);
                            break;
                        default:
                    }
                }
                return value || '';
            });

            // append the "compiled" element to the new window and print
            const w = window.open();
            w.document.body.insertAdjacentHTML('afterbegin', template);
            w.document.close();

            setTimeout(() => {
                    w.print();
                    w.onafterprint = () => w.close();
                    this.action_pending = false;
                    this.swap_dispo(old);
                }
            );
        });
    }

    formatPatronName(u: IdlObject): string {
        return u.first_given_name() + ' ' + u.family_name();
    }

    takeAction(action_step): Promise<any> {
        return this[action_step]().then(() => this.takeBarcode());
    }

    takeBarcode(): Promise<any> {
        this.disposition = null;
        this.dispositionDetails = null;
        this.barcode = this.barcode.trim();
        return this.ill.getTransactionDispositionByBarcode(this.barcode)
            .then(dispoList => {
                console.debug("Barcode disposition:", dispoList);
                this.multipleDispositions = [];
                this.disposition = null;
                this.notFound = false;

                if (dispoList.length > 1) {
                    this.multipleDispositions = dispoList;
                } else if (dispoList.length === 1) {
                    this.selectOneDispo(dispoList[0]);
                } else {
                    this.notFound = true;
                }

            });
    }

    selectOneDispo(active_dispo) {
        this.disposition = active_dispo;
        this.dispositionDetails = this.getDispositionDetails();
        this.multipleDispositions = [];
        if (this.mode === 'ssts') {
            this.setFocus('sstsNextActionButton');
        }
    }

    getDispositionDetails(active_dispo?: ActionContext, action?: string): DispositionDetail {

        const noCache = !active_dispo;

        if (!action && !active_dispo && this.dispositionDetails?.next_action_step) {
            return this.dispositionDetails;
        }

        if (!active_dispo) {
            active_dispo = this.disposition;
        }

        action ||= active_dispo?.next_action; // in case we want to get some basics

        let dispo: DispositionDetail = {
            needs_capture: false,
            needs_receive: false,
            needs_checkin: false,
            needs_checkout: false,
            can_round_trip: false,
            next_action: action,
            open_transit: !!active_dispo?.open_transit,
            open_hold: !!active_dispo?.open_hold,
            open_circ: !!active_dispo?.open_circ,
            can_retarget_hold: !!active_dispo?.can_retarget_hold,
            can_cancel_hold: !!active_dispo?.can_cancel_hold,
            can_mark_lost: !!active_dispo?.can_mark_lost,
            mine: this.org.fullPath(this.contextOrg, true).includes(active_dispo?.copy.circ_lib().id())
        };

        if (!noCache) {
            this.dispositionDetails = dispo;
        }

        switch (action) {
            // capture lender copy for hold
            case 'ill-home-capture' :
                dispo.needs_capture = true;
                dispo.next_action_step = 'checkin';
                dispo.next_action_label = $localize`Capture Outgoing ILL`;
                break;
            // receive item at borrower
            case 'ill-foreign-receive':
                dispo.needs_receive = true;
                dispo.next_action_step = 'checkin';
                dispo.next_action_label = $localize`Capture Incoming ILL`;
                break;
            // receive lender copy back home
            case 'transit-home-receive':
                dispo.needs_receive = true;
                dispo.next_action_step = 'checkin';
                dispo.next_action_label = $localize`Receive Returning ILL`;
                break;
            // transit dispo.for cancelled hold back home (or next hold)
            case 'transit-foreign-return':
                dispo.needs_receive = true;
                dispo.next_action_step = 'checkin';
                dispo.next_action_label = $localize`Send Returning ILL`;
                break;
            // complete borrower circ, transit dispo.back home
            case 'ill-foreign-checkin':
                dispo.next_action_label = $localize`Checkin ILL`;
                dispo.next_action_step = 'checkin';
                dispo.needs_checkin = true;
                break;
            // check out dispo.to borrowing patron
            case 'ill-foreign-checkout':
                dispo.next_action_step = 'checkout';
                dispo.next_action_label = $localize`Checkout ILL`;
                dispo.needs_checkout = true;
                break;
            default:
                if (!active_dispo) {
                    return dispo;
                }

                if (!(active_dispo.open_transit || active_dispo.open_hold || active_dispo.open_circ) // nothing's happening
                    && dispo.mine // at home
                    && active_dispo.copy.status().is_available() === 'f' // wonky status
                ) {
                    dispo.next_action_step = 'checkin';
                    dispo.next_action_label = $localize`Clear bad status`;
                    dispo.needs_receive = true;
                } else if (!(active_dispo.open_transit || active_dispo.open_hold || active_dispo.open_circ) // nothing's happening
                    && !dispo.mine // NOT at home
                ) {
                    dispo.next_action_step = 'checkin';
                    dispo.next_action_label = $localize`Send item home`;
                    dispo.needs_checkin = true;
                } else if ( active_dispo.transit // it's moving ...
                    && !this.org.fullPath(this.contextOrg, true).includes(active_dispo.transit.dest().id()) // ... away from us ...
                    && active_dispo.open_transit // ... and the transit hasn't arrived or been canceled yet
                    && Date.parse(active_dispo.transit.source_send_time()) < Date.parse((new Date()).toISOString().substr(0,10)) // and it was sent before today
                ) {
                    dispo.next_action_step = 'round_trip';
                    dispo.next_action_label = $localize`Begin full Borrower Round-trip`;
                    dispo.can_round_trip = true;
                } else if ( active_dispo.copy && active_dispo.hold && !active_dispo.circ // it's captured for a patron ...
                    && dispo.mine // ... and we own it ...
                    && active_dispo.open_hold // ... and the hold hasn't been fulfilled or canceled yet
                    && (!active_dispo.transit || Date.parse(active_dispo.transit.source_send_time()) < Date.parse((new Date()).toISOString().substr(0,10))) // and it was sent before today
                ) {
                    dispo.next_action_step = 'round_trip';
                    dispo.next_action_label = $localize`Begin ILL for Borrower`;
                    dispo.can_round_trip = true;
                } else if ( active_dispo.copy && active_dispo.circ // it's out to a patron ...
                            && dispo.mine // ... and we own it ...
                ) {
                    dispo.next_action_step = 'round_trip';
                    dispo.next_action_label = $localize`Complete ILL for Borrower`;
                    dispo.can_round_trip = true;
                }
        }

        dispo.can_mark_lost = !!(active_dispo?.open_circ && active_dispo?.copy.status().id() == 1);

        return dispo;
    }
}
