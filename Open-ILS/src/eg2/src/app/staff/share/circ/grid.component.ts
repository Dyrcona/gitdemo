import {Component, OnInit, Output, Input, ViewChild, EventEmitter} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {Observable, empty, of, from} from 'rxjs';
import {map, concat, ignoreElements, last, tap, mergeMap, switchMap, concatMap} from 'rxjs/operators';
import {IdlObject} from '@eg/core/idl.service';
import {OrgService} from '@eg/core/org.service';
import {NetService} from '@eg/core/net.service';
import {AuthService} from '@eg/core/auth.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {CheckoutParams, CheckoutResult, CheckinParams, CheckinResult,
    CircService} from './circ.service';
import {PromptDialogComponent} from '@eg/share/dialog/prompt.component';
import {ProgressDialogComponent} from '@eg/share/dialog/progress.component';
import {ConfirmDialogComponent} from '@eg/share/dialog/confirm.component';
import {GridDataSource, GridColumn, GridCellTextGenerator,
    GridRowFlairEntry} from '@eg/share/grid/grid';
import {GridComponent} from '@eg/share/grid/grid.component';
import {Pager} from '@eg/share/util/pager';
import {StoreService} from '@eg/core/store.service';
import {ServerStoreService} from '@eg/core/server-store.service';
import {AudioService} from '@eg/share/util/audio.service';
import {CopyAlertsDialogComponent
    } from '@eg/staff/share/holdings/copy-alerts-dialog.component';
import {ArrayUtil} from '@eg/share/util/array';
import {PrintService} from '@eg/share/print/print.service';
import {StringComponent} from '@eg/share/string/string.component';
import {DueDateDialogComponent} from './due-date-dialog.component';
import {MarkDamagedDialogComponent
    } from '@eg/staff/share/holdings/mark-damaged-dialog.component';
import {MarkMissingDialogComponent
    } from '@eg/staff/share/holdings/mark-missing-dialog.component';
import {ClaimsReturnedDialogComponent} from './claims-returned-dialog.component';

export interface CircGridEntry {
    index: string; // class + id -- row index
    title?: string;
    author?: string;
    isbn?: string;
    copy?: IdlObject;
    circ?: IdlObject;
    volume?: IdlObject;
    record?: IdlObject;
    dueDate?: string;
    copyAlertCount?: number;
    nonCatCount?: number;
    noticeCount?: number;
    lastNotice?: string; // iso date

    // useful for reporting precaculated values and avoiding
    // repetitive date creation on grid render.
    overdue?: boolean;
}

const CIRC_FLESH_DEPTH = 4;
const CIRC_FLESH_FIELDS = {
  circ: ['target_copy', 'workstation', 'checkin_workstation', 'circ_lib'],
  acp:  [
    'call_number',
    'holds_count',
    'status',
    'circ_lib',
    'location',
    'floating',
    'age_protect',
    'parts'
  ],
  acpm: ['part'],
  acn:  ['record', 'owning_lib', 'prefix', 'suffix'],
  bre:  ['wide_display_entry']
};

@Component({
  templateUrl: 'grid.component.html',
  selector: 'eg-circ-grid'
})
export class CircGridComponent implements OnInit {

    @Input() persistKey: string;
    @Input() printTemplate: string; // defaults to items_out

    // Emitted when a grid action modified data in a way that could
    // affect which cirulcations should appear in the grid.  Caller
    // should then refresh their data and call the load() or
    // appendGridEntry() function.
    @Output() reloadRequested: EventEmitter<void> = new EventEmitter<void>();

    entries: CircGridEntry[] = null;
    gridDataSource: GridDataSource = new GridDataSource();
    cellTextGenerator: GridCellTextGenerator;
    rowFlair: (row: CircGridEntry) => GridRowFlairEntry;
    rowClass: (row: CircGridEntry) => string;
    claimsNeverCount = 0;

    nowDate: number = new Date().getTime();

    @ViewChild('overdueString') private overdueString: StringComponent;
    @ViewChild('circGrid') private circGrid: GridComponent;
    @ViewChild('copyAlertsDialog')
        private copyAlertsDialog: CopyAlertsDialogComponent;
    @ViewChild('dueDateDialog') private dueDateDialog: DueDateDialogComponent;
    @ViewChild('markDamagedDialog')
        private markDamagedDialog: MarkDamagedDialogComponent;
    @ViewChild('markMissingDialog')
        private markMissingDialog: MarkMissingDialogComponent;
    @ViewChild('itemsOutConfirm')
        private itemsOutConfirm: ConfirmDialogComponent;
    @ViewChild('claimsReturnedConfirm')
        private claimsReturnedConfirm: ConfirmDialogComponent;
    @ViewChild('claimsNeverConfirm')
        private claimsNeverConfirm: ConfirmDialogComponent;
    @ViewChild('progressDialog')
        private progressDialog: ProgressDialogComponent;
    @ViewChild('claimsReturnedDialog')
        private claimsReturnedDialog: ClaimsReturnedDialogComponent;

    constructor(
        private org: OrgService,
        private net: NetService,
        private auth: AuthService,
        private pcrud: PcrudService,
        public circ: CircService,
        private audio: AudioService,
        private store: StoreService,
        private printer: PrintService,
        private serverStore: ServerStoreService
    ) {}

    ngOnInit() {

        // The grid never fetches data directly.
        // The caller is responsible initiating all data loads.
        this.gridDataSource.getRows = (pager: Pager, sort: any[]) => {
            return this.entries ? from(this.entries) : empty();
        };

        this.cellTextGenerator = {
            title: row => row.title,
            'copy.barcode': row => row.copy ? row.copy.barcode() : ''
        };

        this.rowFlair = (row: CircGridEntry) => {
            if (this.circIsOverdue(row)) {
                return {icon: 'error_outline', title: this.overdueString.text};
            }
        };

        this.rowClass = (row: CircGridEntry) => {
            if (this.circIsOverdue(row)) {
                return 'less-intense-alert';
            }
        };
    }

    // Ask the caller to update our data set.
    emitReloadRequest() {
        this.entries = null;
        this.reloadRequested.emit();
    }

    // Reload the grid without any data retrieval
    reloadGrid() {
        this.circGrid.reload();
    }

    // Fetch circulation data and make it available to the grid.
    load(circIds: number[]): Observable<CircGridEntry> {

        // No circs to load
        if (!circIds || circIds.length === 0) { return empty(); }

        // Return the circs we have already retrieved.
        if (this.entries) { return from(this.entries); }

        this.entries = [];

        // fetchCircs and fetchNotices both return observable of grid entries.
        // ignore the entries from fetchCircs so they are not duplicated.
        return this.fetchCircs(circIds)
            .pipe(ignoreElements(), concat(this.fetchNotices(circIds)));
    }

    fetchCircs(circIds: number[]): Observable<CircGridEntry> {

        return this.pcrud.search('circ', {id: circIds}, {
            flesh: CIRC_FLESH_DEPTH,
            flesh_fields: CIRC_FLESH_FIELDS,
            order_by : {circ : ['xact_start']},

            // Avoid fetching the MARC blob by specifying which
            // fields on the bre to select.  More may be needed.
            // Note that fleshed fields are explicitly selected.
            select: {bre : ['id']}

        }).pipe(map(circ => {

            const entry = this.gridify(circ);
            this.appendGridEntry(entry);
            return entry;
        }));
    }

    fetchNotices(circIds: number[]): Observable<CircGridEntry> {
        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.user.itemsout.notices',
            this.auth.token(), circIds
        ).pipe(tap(notice => {

            const entry = this.entries.filter(
                e => e.circ.id() === Number(notice.circ_id))[0];

            entry.noticeCount = notice.numNotices;
            entry.lastNotice = notice.lastDt;
            return entry;
        }));
    }

    // Also useful for manually appending circ-like things (e.g. noncat
    // circs) that can be massaged into CircGridEntry structs.
    appendGridEntry(entry: CircGridEntry) {
        if (!this.entries) { this.entries = []; }
        this.entries.push(entry);
    }

    gridify(circ: IdlObject): CircGridEntry {

        const entry: CircGridEntry = {
            index: `circ-${circ.id()}`,
            circ: circ,
            dueDate: circ.due_date(),
            copyAlertCount: 0 // TODO
        };

        const copy = circ.target_copy();
        entry.copy = copy;

        // Some values have to be manually extracted / normalized
        if (copy.call_number().id() === -1) {

            entry.title = copy.dummy_title();
            entry.author = copy.dummy_author();
            entry.isbn = copy.dummy_isbn();

        } else {

            entry.volume = copy.call_number();
            entry.record = entry.volume.record();

            // display entries are JSON-encoded and some are lists
            const display = entry.record.wide_display_entry();

            entry.title = JSON.parse(display.title());
            entry.author = JSON.parse(display.author());
            entry.isbn = JSON.parse(display.isbn());

            if (Array.isArray(entry.isbn)) {
                entry.isbn = entry.isbn.join(',');
            }
        }

        return entry;
    }

    selectedCopyIds(rows: CircGridEntry[]): number[] {
        return rows
            .filter(row => row.copy)
            .map(row => Number(row.copy.id()));
    }

    openItemAlerts(rows: CircGridEntry[], mode: string) {
        const copyIds = this.selectedCopyIds(rows);
        if (copyIds.length === 0) { return; }

        this.copyAlertsDialog.copyIds = copyIds;
        this.copyAlertsDialog.mode = mode;
        this.copyAlertsDialog.open({size: 'lg'}).subscribe(
            modified => {
                if (modified) {
                    // TODO: verify the modiifed alerts are present
                    // or go fetch them.
                    this.circGrid.reload();
                }
            }
        );
    }

    // Which copies in the grid are selected.
    getCopyIds(rows: CircGridEntry[], skipStatus?: number): number[] {
        return this.getCopies(rows, skipStatus).map(c => Number(c.id()));
    }

    getCopies(rows: CircGridEntry[], skipStatus?: number): IdlObject[] {
        let copies = rows.filter(r => r.copy).map(r => r.copy);
        if (skipStatus) {
            copies = copies.filter(
                c => Number(c.status().id()) !== Number(skipStatus));
        }
        return copies;
    }

    getCircIds(rows: CircGridEntry[]): number[] {
        return this.getCircs(rows).map(row => Number(row.id()));
    }

    getCircs(rows: any): IdlObject[] {
        return rows.filter(r => r.circ).map(r => r.circ);
    }

    printReceipts(rows: any) {
        if (rows.length > 0) {
            this.printer.print({
                templateName: this.printTemplate || 'items_out',
                contextData: {circulations: rows},
                printContext: 'default'
            });
        }
    }

    editDueDate(rows: any) {
        const circs = this.getCircs(rows);
        if (circs.length === 0) { return; }

        let refreshNeeded = false;
        this.dueDateDialog.circs = circs;
        this.dueDateDialog.open().subscribe(
            circ => {
                refreshNeeded = true;
                const row = rows.filter(r => r.circ.id() === circ.id())[0];
                row.circ.due_date(circ.due_date());
                row.dueDate = circ.due_date();
                delete row.overdue; // it will recalculate
            },
            err => console.error(err),
            () => {
                if (refreshNeeded) {
                    this.reloadGrid();
                }
            }
        );
    }

    circIsOverdue(row: CircGridEntry): boolean {
        const circ = row.circ;

        if (!circ) { return false; } // noncat

        if (row.overdue === undefined) {
            row.overdue = (Date.parse(circ.due_date()) < this.nowDate);
        }
        return row.overdue;
    }

    markDamaged(rows: CircGridEntry[]) {
        const copyIds = this.getCopyIds(rows, 14 /* ignore damaged */);

        if (copyIds.length === 0) { return; }

        let rowsModified = false;

        const markNext = (ids: number[]): Promise<any> => {
            if (ids.length === 0) {
                return Promise.resolve();
            }

            this.markDamagedDialog.copyId = ids.pop();

            return this.markDamagedDialog.open({size: 'lg'})
            .toPromise().then(ok => {
                if (ok) { rowsModified = true; }
                return markNext(ids);
            });
        };

        markNext(copyIds).then(_ => {
            if (rowsModified) {
                this.emitReloadRequest();
            }
        });
    }

    markMissing(rows: CircGridEntry[]) {
        const copyIds = this.getCopyIds(rows, 4 /* ignore missing */);

        if (copyIds.length === 0) { return; }

        // This assumes all of our items our checked out, since this is
        // a circ grid.  If we add support later for showing completed
        // circulations, there may be cases where we can skip the items
        // out confirmation alert and subsequent checkin
        this.itemsOutConfirm.open().subscribe(confirmed => {
            if (!confirmed) { return; }

            this.checkin(rows, {noop: true}, true).toPromise().then(_ => {

                this.markMissingDialog.copyIds = copyIds;
                this.markMissingDialog.open({}).subscribe(
                    rowsModified => {
                        if (rowsModified) {
                            this.emitReloadRequest();
                        }
                    }
                );
            });
        });
    }

    openProgressDialog(rows: CircGridEntry[]): ProgressDialogComponent {
        this.progressDialog.update({value: 0, max: rows.length});
        this.progressDialog.open();
        return this.progressDialog;
    }

    // Same params will be used for each copy
    checkin(rows: CircGridEntry[], params?:
        CheckinParams, noReload?: boolean): Observable<CheckinResult> {

        const dialog = this.openProgressDialog(rows);

        return this.circ.checkinBatch(this.getCopyIds(rows), params)
        .pipe(tap(
            result => dialog.increment(),
            err => null,
            () => {
                dialog.close();
                if (!noReload) { this.emitReloadRequest(); }
            }
        ));
    }

    markLost(rows: CircGridEntry[]) {
        const dialog = this.openProgressDialog(rows);
        const barcodes = this.getCopies(rows).map(c => c.barcode());

        from(barcodes).pipe(concatMap(barcode => {
            return this.net.request(
                'open-ils.circ',
                'open-ils.circ.circulation.set_lost',
                this.auth.token(), {barcode: barcode}
            );
        })).subscribe(
            result => dialog.increment(),
            err => console.error(err),
            () => {
                dialog.close();
                this.emitReloadRequest();
            }
        );
    }

    claimsReturned(rows: CircGridEntry[]) {
        this.claimsReturnedDialog.barcodes =
            this.getCopies(rows).map(c => c.barcode());

        this.claimsReturnedDialog.open().subscribe(
            rowsModified => {
                if (rowsModified) {
                    this.emitReloadRequest();
                }
            }
        );
    }

    claimsNeverCheckedOut(rows: CircGridEntry[]) {
        const dialog = this.openProgressDialog(rows);

        this.claimsNeverCount = rows.length;

        this.claimsNeverConfirm.open().subscribe(confirmed => {
            this.claimsNeverCount = 0;

            if (!confirmed) {
                dialog.close();
                return;
            }

            this.circ.checkinBatch(
                this.getCopyIds(rows), {claims_never_checked_out: true}
            ).subscribe(
                result => dialog.increment(),
                err => console.error(err),
                () => {
                    dialog.close();
                    this.emitReloadRequest();
                }
            );
        });
    }
}
