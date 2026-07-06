import {Component, Input, OnInit, ViewChild} from '@angular/core';
import {Observable, EMPTY, from, switchMap} from 'rxjs';
import {Pager} from '@eg/share/util/pager';
import {NetService} from '@eg/core/net.service';
import {AuthService} from '@eg/core/auth.service';
import {ServerStoreService} from '@eg/core/server-store.service';
import {GridComponent} from '@eg/share/grid/grid.component';
import {GridDataSource, GridCellTextGenerator} from '@eg/share/grid/grid';


type Orientation = 'to_patrons' | 'from_items';

@Component({
    templateUrl: 'top-titles.component.html',
    selector: 'eg-top-titles'
})
export class TopTitlesComponent implements OnInit {


    @Input() orientation: Orientation = 'from_items';
    @Input() contextOrg: number;
    @Input() gridPersistKey: string;
    @Input() illMode = true;

    // long unfilled filtering
    @Input() ageHorizonSetting: string;
    @Input() ageHorizon = '1 year';

    dataSource: GridDataSource;
    cellTextGenerator: GridCellTextGenerator;

    @ViewChild('grid', {static: false}) grid: GridComponent;

    constructor(
        private net: NetService,
        private auth: AuthService,
        private store: ServerStoreService
    ) {
    }

    saveHorizonFilter() {
        if (this.ageHorizonSetting) {
            this.store.setItem(this.ageHorizonSetting, this.ageHorizon);
        }
        this.grid.reload();
    }

    ngOnInit() {
        this.dataSource = new GridDataSource();

        if (this.ageHorizonSetting) {
            this.store.getItem(this.ageHorizonSetting).then(
                applied => this.ageHorizon = applied ? applied : this.ageHorizon
            );
        }

        this.dataSource.getRows = (pager: Pager, sort: any): Observable<any> => {

            return this.net.request(
                'open-ils.circ',
                `open-ils.circ.statistics.top_title_counts.${this.orientation}`,
                this.auth.token(),
                this.ageHorizon,
                pager.limit, pager.offset,
                this.contextOrg || this.auth.user().ws_ou(),
                sort.map(s => { let x = {}; x[s.name] = s.dir; return x; })
            );
        };

        this.cellTextGenerator = {
            title: row => row.title,
            series_title: row => row.series_title?.join(', '),
            identifiers: row => [].concat(['isbn','issn','upc'].map(p => row[p])).flat().filter(i => !!i).map(i => i.trim()).filter(i => i.length).join(', ')
        };
    }
}


