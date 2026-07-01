import {Component, OnInit} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {ILLModule} from './ill.module';
import {NgbNav, NgbNavChangeEvent} from '@ng-bootstrap/ng-bootstrap';
import {filter, pairwise} from 'rxjs';
import {AuthService} from '@eg/core/auth.service';
import {StoreService} from '@eg/core/store.service';
import {SingleScanComponent} from './singlescan.component';
import {PendingRequestsComponent} from './pending.component';
import {TransitComponent} from './transit.component';
import {OnShelfComponent} from './onshelf.component';
import {CirculatingComponent} from './circulating.component';
import {TopTitleListComponent} from './top-title-list.component';

@Component({
    templateUrl: 'ill.component.html',
    styleUrls: ['ill.component.css'],
})
export class ILLComponent implements OnInit {

    activeTab: string;
    ill_role = 'borrower';
    route_barcode: string;
    jumpLink = '';
    contextOrg: number;

    showNav = true;
    statusMode = false;

    constructor(
        private router: Router,
        private route: ActivatedRoute,
        private auth: AuthService,
        private store: StoreService
    ) {}

    ngOnInit() {
        this.contextOrg = this.auth.user().ws_ou();

        this.activeTab ||= this.route.snapshot.params.activeTab || 'singlescan';
        this.ill_role ||= this.route.snapshot.params.ill_role || 'borrower';
        this.route_barcode ||= this.route.snapshot.params.barcode;

        if (['singlescan','status'].includes(this.activeTab)) {
            this.statusMode = this.activeTab === 'status';
        }

        this.showNav = !this.store.getLocalItem('ff.ill.nav.collapse');

        this.watchForTabChange();
    }

    watchForTabChange() {

        this.route.paramMap.subscribe((params: ParamMap) => {
            this.activeTab = params.get('activeTab');
            this.ill_role = params.get('ill_role') || 'borrower';
            this.route_barcode = params.get('barcode');

            // set the statusMode flag as necessary, assuming
            // we will reuse SingleScanComponent
            if (['singlescan','status'].includes(this.activeTab)) {
                this.statusMode = this.activeTab === 'status';
            }

        });
    }

    toggleNavPane() {
        this.store.setLocalItem( // collapse is the opposite of show
            'ff.ill.nav.collapse', this.showNav);
        this.showNav = !this.showNav;
    }

    activateJumpLink() {
        if (!this.jumpLink) {
            return;
        }

        this.router.navigate([`/staff/ill/${this.jumpLink}`]);
    }
}

