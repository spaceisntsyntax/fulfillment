import {NgModule} from '@angular/core';
import {RouterModule, Routes} from '@angular/router';
import {ILLComponent} from './ill.component';

const routes: Routes = [{
    // Default ILL route is SSTS
    path: '',
    pathMatch: 'full',
    redirectTo: 'singlescan'
}, {
    path: 'singlescan',
    component: ILLComponent,
    data: { activeTab: 'singlescan' }
}, {
    path: 'singlescan/:barcode',
    component: ILLComponent,
    data: { activeTab: 'singlescan' }
}, {
    path: 'status',
    component: ILLComponent,
    data: { activeTab: 'status' }
}, {
    path: 'status/:barcode',
    component: ILLComponent,
    data: { activeTab: 'status' }
}, {
    path: 'pending',
    pathMatch: 'full',
    redirectTo: 'pending/borrower'
}, {
    path: 'incoming',
    pathMatch: 'full',
    redirectTo: 'incoming/borrower'
}, {
    path: 'outgoing',
    pathMatch: 'full',
    redirectTo: 'outgoing/borrower'
}, {
    path: 'onshelf',
    pathMatch: 'full',
    redirectTo: 'onshelf/borrower'
}, {
    path: 'circulating',
    pathMatch: 'full',
    redirectTo: 'circulating/borrower'
}, {
    path: 'top-title-list',
    pathMatch: 'full',
    redirectTo: 'top-title-list/borrower'
}, {
    path: ':activeTab/:ill_role',
    component: ILLComponent
}];

@NgModule({
    imports: [RouterModule.forChild(routes)],
    exports: [RouterModule]
})

export class ILLRoutingModule {}
