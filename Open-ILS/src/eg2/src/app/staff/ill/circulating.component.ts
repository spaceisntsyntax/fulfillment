import {Component, OnInit, Input, ViewChild} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {Location} from '@angular/common';
import {OrgService} from '@eg/core/org.service';
import {NetService} from '@eg/core/net.service';
import {StoreService} from '@eg/core/store.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {NgbNav, NgbNavChangeEvent} from '@ng-bootstrap/ng-bootstrap';
import {CircGridComponent} from  '@eg/staff/share/circ/grid.component';

@Component({
    templateUrl: 'circulating.component.html',
    selector: 'ff-ill-circulating'
})
export class CirculatingComponent implements OnInit{

    @Input() contextOrg: number;
    @Input() ill_role: string;

    @ViewChild('toMyPatrons') private toMyPatrons: CircGridComponent;
    @ViewChild('toOtherLibraries') private toOtherLibraries: CircGridComponent;

    constructor(
        private router: Router,
        private ngLocation: Location,
        private org: OrgService,
        private net: NetService,
        private pcrud: PcrudService,
        private store: StoreService
    ) {}

    ngOnInit() {
        this.load(this.ill_role);
    }

    load(which) {
        if (which === 'borrower') {
            this.loadHere();
        } else {
            this.loadThere();
        }
    }

    loadHere(): Promise<any> {
        return this.getCircIds('borrower')
            .then(circs => this.toMyPatrons?.load(circs).toPromise())
            .then(_ => this.toMyPatrons?.reloadGrid());
    }

    loadThere(): Promise<any> {
        return this.getCircIds('lender')
            .then(circs => this.toOtherLibraries?.load(circs).toPromise())
            .then(_ => this.toOtherLibraries?.reloadGrid());
    }

    getCircIds(location: string): Promise<any> {

        const fullPath = this.org.fullPath(this.contextOrg, true);

        let copy_circ_lib: any = [...fullPath]; // our copies
        let circ_circ_lib: any = [...fullPath]; // circulating here

        if (location === 'borrower') { // "not my copies"
            copy_circ_lib = {'not in': [...copy_circ_lib]};
        } else {
            circ_circ_lib = {'not in': [...circ_circ_lib]};
        }

        return this.pcrud.search('circ', {
            checkin_time: null,
            circ_lib : circ_circ_lib,
            target_copy : {
                'in' : {
                    select: {acp : ['id']},
                    from : 'acp',
                    where : {
                        deleted : 'f',
                        id : {'=' : {'+circ' : 'target_copy'}},
                        circ_lib : copy_circ_lib
                    }
                }
            }
        },{},{ idlist: true, atomic: true }).toPromise();
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
        let url = `/staff/ill/circulating/${tab}`;

        if (newWindow) {
            url = this.ngLocation.prepareExternalUrl(url);
            window.open(url);
        } else {
            this.router.navigate([url]);
            setTimeout(() => this.load(tab));
        }
    }
}

