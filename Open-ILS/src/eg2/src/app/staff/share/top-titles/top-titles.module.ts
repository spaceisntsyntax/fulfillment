import {NgModule} from '@angular/core';
import {StaffCommonModule} from '@eg/staff/common.module';
import {TopTitlesComponent} from './top-titles.component';

@NgModule({
    declarations: [
        TopTitlesComponent
    ],
    imports: [
        StaffCommonModule
    ],
    exports: [
        TopTitlesComponent
    ],
    providers: [
    ]
})

export class TopTitlesModule {}

