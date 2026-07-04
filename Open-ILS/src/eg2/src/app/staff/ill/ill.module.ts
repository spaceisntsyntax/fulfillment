import {NgModule} from '@angular/core';
import {StaffCommonModule} from '@eg/staff/common.module';
import {ILLComponent} from './ill.component';
import {ILLRoutingModule} from './routing.module';
import {SingleScanComponent} from './singlescan.component';
import {PendingRequestsComponent} from './pending.component';
import {TransitComponent} from './transit.component';
import {OnShelfComponent} from './onshelf.component';
import {DisallowItemComponent} from './disallow-item.component';
import {ILLService} from './ill.service';
import {CirculatingComponent} from './circulating.component';
import {TopTitleListComponent} from './top-title-list.component';
import {MyRequestsComponent} from './my-requests.component';
import {BarcodesModule} from '@eg/staff/share/barcodes/barcodes.module';
import {HoldsModule} from '@eg/staff/share/holds/holds.module';
import {CircModule} from '@eg/staff/share/circ/circ.module';
import {AdminPageModule} from '@eg/staff/share/admin-page/admin-page.module';
import {PatronModule} from '@eg/staff/share/patron/patron.module';
import {TopTitlesModule} from '@eg/staff/share/top-titles/top-titles.module';

@NgModule({
    declarations: [
        ILLComponent,
        SingleScanComponent,
        PendingRequestsComponent,
        TransitComponent,
        OnShelfComponent,
        CirculatingComponent,
        DisallowItemComponent,
        TopTitleListComponent,
        MyRequestsComponent,
    ],
    imports: [
        StaffCommonModule,
        ILLRoutingModule,
        HoldsModule,
        CircModule,
        AdminPageModule,
        PatronModule,
        TopTitlesModule,
    ],
    providers: [
        ILLService,
    ]
})

export class ILLModule {}

