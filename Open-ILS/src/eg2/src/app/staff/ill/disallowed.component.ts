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
    templateUrl: 'disallowed.component.html',
    selector: 'ff-ill-disallowed'
})
export class DisallowedComponent implements OnInit {

    @Input() direction: string;
    @Input() ill_role: string;
    @Input() contextOrg: number;

    liveFilter = {};
    customActions = [];

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

    JSONparse(j:string): any {
        return JSON.parse(j);
    }

    ngOnInit() {
        this.cellTextGenerator = {
            staff:      row => row.staff().usrname(),
            barcode:    row => row.item().barcode(),
            copy_lib:   row => row.item().circ_lib().shortname(),
            title:      row => JSON.parse(row.item().call_number().record().wide_display_entry().title())
        };

        const fullPath = this.org.fullPath(this.contextOrg, true);

        this.customActions.push({
            label: $localize`Cancel Requests`,
            method: (rows) => this.cancel_requests(rows)
        });

        this.liveFilter = {
            hold : null,
            block_stop : null,
            '-exists' : {
                select: {acp : ['id']},
                from : 'acp',
                where : {
                    deleted : 'f',
                    id : {'=' : {'+acbh' : 'item'}},
                    circ_lib : {'in' : this.org.fullPath(this.contextOrg, true)}
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
        let url = `/staff/ill/disallowed/${tab}`;

        if (newWindow) {
            url = this.ngLocation.prepareExternalUrl(url);
            window.open(url);
        } else {
            this.router.navigate([url]);
        }
    }
}
