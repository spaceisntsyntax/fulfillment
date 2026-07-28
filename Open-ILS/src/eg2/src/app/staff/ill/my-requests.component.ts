import {Component, Input, ViewChild} from '@angular/core';
import {lastValueFrom, defaultIfEmpty} from 'rxjs';
import {HoldsGridComponent} from  '@eg/staff/share/holds/grid.component';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {Location} from '@angular/common';
import {OrgService} from '@eg/core/org.service';
import {NetService} from '@eg/core/net.service';
import {StoreService} from '@eg/core/store.service';
import {NgbNav, NgbNavChangeEvent} from '@ng-bootstrap/ng-bootstrap';
import {DisallowItemComponent, DisallowDialogResult} from './disallow-item.component';
import {ILLService} from './ill.service';

@Component({
    templateUrl: 'my-requests.component.html',
    selector: 'ff-ill-my-requests'
})
export class MyRequestsComponent {

    @Input() contextOrg: number;
    @Input() ill_role: string;

    @ViewChild('disallowDialog') private disallowDialog: DisallowItemComponent;
    @ViewChild('canceledGrid') private canceledGrid: HoldsGridComponent;
    @ViewChild('suspendedGrid') private suspendedGrid: HoldsGridComponent;
    @ViewChild('overdueGrid') private overdueGrid: HoldsGridComponent;

    canceledActions: any[];
    frozenActions: any[];
    overdueActions: any[];

    constructor(
        private router: Router,
        private ill: ILLService,
        private ngLocation: Location,
        private org: OrgService,
        private net: NetService,
        private store: StoreService
    ) {
        this.frozenActions = [{
            group: 'ILL',
            label: $localize`Activate Requests`,
            method: (rows) => this.activate_holds(rows)
        }];

        this.overdueActions = [{
            group: 'ILL',
            label: $localize`Suspend Requests`,
            method: (rows) => this.suspend_holds(rows)
        }];

    }

    // Navigate, opening new tabs when requested via control-click.
    // NOTE: The nav items have routerLinks, but for some reason,
    // control-click on the links does not open them in a new tab.
    // Mouse middle-click does, though.  *shrug*
    navItemClick(tab: string, evt: PointerEvent) {
        evt.preventDefault();
        this.routeToTab(tab, evt.ctrlKey);
    }

    toggleHoldActive(rows: any[], frozen_value: string): Promise<any> {
        return this.ill.circAPIRequest(
            'open-ils.circ.hold.update.batch.atomic',
            null, [].concat(rows.map(r => { return {id: r.id, frozen: frozen_value} }))
        ).then( _ => this.suspendedGrid.handleModify(true));
    }

    activate_holds(rows: any[]): Promise<any> {
        return this.toggleHoldActive(rows, 'f');
    }

    suspend_holds(rows: any[]): Promise<any> {
        return this.toggleHoldActive(rows, 't');
    }

/*
    force_m_type_lender(rows: any[]): Promise<any> {
        return Promise.all(
            rows.map(r => this.ill.upgradeToMetarecordHold(r.id))
        ).then( _ => this.lenderGrid.handleModify(true));
    }

    force_m_type_borrower(rows: any[]): Promise<any> {
        return Promise.all(
            rows.map(r => this.ill.upgradeToMetarecordHold(r.id))
        ).then( _ => this.borrowerGrid.handleModify(true));
    }
*/

    beforeTabChange(evt: NgbNavChangeEvent) {
        // Prevent the nav component from changing tabs so we can
        // control the behaviour.
        evt.preventDefault();
    }

    routeToTab(tab?: string, newWindow?: boolean) {
        let url = `/staff/ill/my-requests/${tab}`;

        if (newWindow) {
            url = this.ngLocation.prepareExternalUrl(url);
            window.open(url);
        } else {
            this.router.navigate([url]);
        }
    }

    newHold() {
        this.router.navigate(['/staff/catalog/search']);
    }

    private daysFromNow(days: number): string {
        let d = new Date();
        d.setDate(Number(d.getDate()) + Number(days));
        return d.toISOString().substring(0,10);
    }

    async popup_block_ill(rows): Promise<any> {
        const promises = rows.map(row => {
            return this.ill.getTransactionDispositionByBarcode(row.cp_barcode)
                .then( dispoList => {
                    let disposition = dispoList[0];

                    if (disposition) {
                        this.disallowDialog.blockAmount = this.ill.defaultBlockAmount;
                        this.disallowDialog.blockStop = '';
                        this.disallowDialog.barcode = disposition.copy.barcode();
                        this.disallowDialog.willCancelTransit = !!disposition.open_transit;
                        this.disallowDialog.currentlyTargeted = !!disposition.open_hold;

                        return this.disallowDialog.open().pipe(
                            defaultIfEmpty({rejected: true})
                        ).toPromise().then( result => {
                            if (!result.rejected) {
                                const block_scope = result.blockAll ? 'block_all' : 'block_one';
                                let block_end = block_scope == 'block_all' ? result.blockStop || null : null;
                                const block_amount = block_scope == 'block_all' ? result.blockAmount || null : null;

                                if (!block_end && block_amount > 0) { // use block_amount instead of block_end
                                    block_end = this.daysFromNow(block_amount);
                                }

                                if (!!disposition.open_transit) {
                                    return this.ill.circAPIRequest(
                                        'open-ils.circ.transit.abort',
                                        {transitid : disposition.transit.id()}
                                    ).then(() => this[block_scope](result.blockReason, disposition, block_end));
                                } else {
                                    return this[block_scope](result.blockReason, disposition, block_end);
                                }
                            } else {
                                console.debug('hold blocking canceled');
                                return Promise.resolve(true);
                            }
                        });

                    }
                    return Promise.resolve(true);
                });
            }
        );

        return Promise.all(promises);
    }

    block_one(reason: string, disposition, block_end): Promise<any> {
        console.debug('blocking one hold: ' + disposition.hold.id());

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.block',
            disposition.copy.id(), reason, disposition.hold.id()
        );
    }

    block_all(reason: string, disposition, block_end): Promise<any> {
        console.debug('blocking all holds for barcode '+disposition.copy.barcode());

        return this.ill.circAPIRequest(
            'open-ils.circ.hold.block',
            disposition.copy.id(), reason, null, block_end
        );
    }
}

