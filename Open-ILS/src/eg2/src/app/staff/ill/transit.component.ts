import {Component, OnInit, Input} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {Location} from '@angular/common';
import {OrgService} from '@eg/core/org.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {StoreService} from '@eg/core/store.service';
import {NgbNav, NgbNavChangeEvent} from '@ng-bootstrap/ng-bootstrap';
import {AdminPageComponent} from '@eg/staff/share/admin-page/admin-page.component';
import {GridCellTextGenerator} from '@eg/share/grid/grid';
import {ILLService} from './ill.service';

@Component({
    templateUrl: 'transit.component.html',
    selector: 'ff-transits'
})
export class TransitComponent implements OnInit {

    @Input() direction: string;
    @Input() ill_role: string;
    @Input() contextOrg: number;

    liveFilters = { borrower: null, lender: null };
    linkLabels = { borrower: null, lender: null };
    customActions = { borrower: [], lender: [] };

    cellTextGenerator: GridCellTextGenerator;
    constructor(
        private router: Router,
        private ngLocation: Location,
        private org: OrgService,
        private pcrud: PcrudService,
        private ill: ILLService,
        private store: StoreService
    ) {}

    cancel_requests(rows: any[]) {
        rows.forEach(row => {
            this.pcrud.retrieve('ahtc', row.id())
                .toPromise()
                .then( ht => this.ill.cancel(ht.id()) )
        });
    }

    abort_transits(rows: any[]) {
        rows.forEach(row => {
            this.ill.circAPIRequest(
                'open-ils.circ.transit.abort',
                {transitid : row.id()}
            );
        });
    }

    JSONparse(j:string): any {
        return JSON.parse(j);
    }

    ngOnInit() {
        this.cellTextGenerator = {
            routing_code:   row => row.dest().routing_code(),
            barcode:        row => row.target_copy().barcode(),
            copy_lib:       row => row.target_copy().circ_lib().shortname(),
            title:          row => JSON.parse(row.target_copy().call_number().record().wide_display_entry().title())
        };

        const fullPath = this.org.fullPath(this.contextOrg, true);
        let dest: any = [...fullPath];      // inbound transits
        let circ_lib: any = [...fullPath];  // our copies
        let source: any = [...fullPath];    // source of transit

        if (this.direction === 'incoming') {
            this.linkLabels.borrower = $localize`ILLs For My Patrons`;
            this.linkLabels.lender = $localize`My Returns`;

            source = {'not in' : source};

            this.customActions.borrower.push({
                label: $localize`Cancel Requests`,
                method: (rows) => this.cancel_requests(rows)
            });
        } else {
            this.linkLabels.lender = $localize`ILLs to Other Libraries`;
            this.linkLabels.borrower = $localize`Returns to Other Libraries`;

            dest = {'not in' : dest};

            this.customActions.lender.push({
                label: $localize`Abort Transits`,
                method: (rows) => this.abort_transits(rows)
            });
        }

        this.liveFilters.borrower = {
            dest_recv_time : null,
            cancel_time : null,
            dest : dest,
            source : source,
            target_copy : {
                'in' : {
                    select: {acp : ['id']},
                    from : 'acp',
                    where : {
                        deleted : 'f',
                        id : {'=' : {'+atc' : 'target_copy'}},
                        circ_lib : {'not in' : circ_lib}
                    }
                }
            }
        };

        this.liveFilters.lender = {
            dest_recv_time : null,
            cancel_time : null,
            dest : dest,
            source : source,
            target_copy : {
                'in' : {
                    select: {acp : ['id']},
                    from : 'acp',
                    where : {
                        deleted : 'f',
                        id : {'=' : {'+atc' : 'target_copy'}},
                        circ_lib : circ_lib
                    }
                }
            }
        };
    }

    newHold() {
        this.router.navigate(['/staff/catalog/search']);
    }

    // Navigate, opening new tabs when requested via control-click.
    // NOTE: The nav items have routerLinks, but for some reason,
    // control-click on the links does not open them in a new tab.
    // Mouse middle-click does, though.  *shrug*
    navItemClick(tab: string, evt: PointerEvent) {
        evt.preventDefault();
        this.routeToTab(tab, evt.ctrlKey);
    }

    beforeTabChange(evt: NgbNavChangeEvent) {
        // Prevent the nav component from changing tabs so we can
        // control the behaviour.
        evt.preventDefault();
    }

    routeToTab(tab?: string, newWindow?: boolean) {
        let url = `/staff/ill/${this.direction}/${tab}`;

        if (newWindow) {
            url = this.ngLocation.prepareExternalUrl(url);
            window.open(url);
        } else {
            this.router.navigate([url]);
        }
    }
}
