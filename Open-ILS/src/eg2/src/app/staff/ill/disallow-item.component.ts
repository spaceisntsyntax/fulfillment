import {Component, OnInit, Input} from '@angular/core';
import {IdlObject, IdlService} from '@eg/core/idl.service';
import {NetService} from '@eg/core/net.service';
import {EventService} from '@eg/core/event.service';
import {ToastService} from '@eg/share/toast/toast.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {AuthService} from '@eg/core/auth.service';
import {OrgService} from '@eg/core/org.service';
import {DialogComponent} from '@eg/share/dialog/dialog.component';
import {NgbModal} from '@ng-bootstrap/ng-bootstrap';


export interface DisallowDialogResult {
    rejected: boolean;
    blockAll?: boolean;
    blockReason?: string;
    blockStop?: string;
}

@Component({
    selector: 'ff-disallow-item',
    templateUrl: 'disallow-item.component.html'
})

export class DisallowItemComponent extends DialogComponent {

    @Input() barcode = '';
    @Input() willCancelTransit = false;
    @Input() currentlyTargeted = false;

    blockStop = '';
    blockAll = true;
    blockReason = 'policy';

    constructor(
        private modal: NgbModal,
        private toast: ToastService,
        private net: NetService,
        private idl: IdlService,
        private evt: EventService,
        private pcrud: PcrudService,
        private org: OrgService,
        private auth: AuthService
    ) {
        super(modal);
    }

    save() {
        const res = {
            rejected: false,
            blockAll: this.blockAll,
            blockStop: this.blockStop,
            blockReason: this.blockReason
        };

        this.close(res);
    }
    
}

