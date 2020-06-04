import {Component, OnInit, AfterViewInit, ViewChild, Input, Renderer2, Output, EventEmitter} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {tap} from 'rxjs/operators';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {OrgService} from '@eg/core/org.service';
import {AuthService} from '@eg/core/auth.service';
import {NetService} from '@eg/core/net.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {VolCopyContext, HoldingsTreeNode} from './volcopy';
import {ComboboxEntry} from '@eg/share/combobox/combobox.component';
import {HoldingsService} from '@eg/staff/share/holdings/holdings.service';
import {ConfirmDialogComponent} from '@eg/share/dialog/confirm.component';
import {VolCopyService} from './volcopy.service';

@Component({
  selector: 'eg-vol-edit',
  templateUrl: 'vol-edit.component.html',
  styleUrls: ['vol-edit.component.css']
})


export class VolEditComponent implements OnInit {

    @Input() context: VolCopyContext;

    // There are 10 columns in the editor form.  Set the flex values
    // here so they don't have to be hard-coded and repeated in the
    // markup.  Changing a flex value here will propagate to all
    // rows in the form.  Column numbers are 1-based.
    flexSettings: {[column: number]: number} = {
        1: 1, 2: 1, 3: 2, 4: 1, 5: 2, 6: 1, 7: 1, 8: 2, 9: 1, 10: 1};

    // If a column is specified as the expand field, its flex value
    // will magically grow.
    expand: number;

    batchVolClass: ComboboxEntry;
    batchVolPrefix: ComboboxEntry;
    batchVolSuffix: ComboboxEntry;
    batchVolLabel: ComboboxEntry;

    autoBarcodeInProgress = false;
    useCheckdigit = false;

    deleteVolCount: number = null;
    deleteCopyCount: number = null;

    recordVolLabels: string[] = [];

    @ViewChild('confirmDelVol', {static: false})
        confirmDelVol: ConfirmDialogComponent;

    @ViewChild('confirmDelCopy', {static: false})
        confirmDelCopy: ConfirmDialogComponent;

    // Emitted when the save-ability of this form changes.
    @Output() canSaveChange: EventEmitter<boolean> = new EventEmitter<boolean>();

    constructor(
        private renderer: Renderer2,
        private idl: IdlService,
        private org: OrgService,
        private pcrud: PcrudService,
        private net: NetService,
        private auth: AuthService,
        private holdings: HoldingsService,
        public  volcopy: VolCopyService
    ) {}

    ngOnInit() {

        this.deleteVolCount = null;
        this.deleteCopyCount = null;
        this.useCheckdigit = this.volcopy.defaults.values.use_checkdigit;

        this.volcopy.fetchRecordVolLabels(this.context.recordId)
        .then(labels => this.recordVolLabels = labels)
        .then(_ => this.volcopy.fetchBibParts(this.context.getRecordIds()))
        .then(_ => this.addStubCopies());
    }

    copyStatLabel(copy: IdlObject): string {
        if (copy) {
            const statId = copy.status();
            if (statId in this.volcopy.copyStatuses) {
                return this.volcopy.copyStatuses[statId].name();
            }
        }
        return '';
    }

    recordHasParts(bibId: number): boolean {
        return this.volcopy.bibParts[bibId] &&
            this.volcopy.bibParts[bibId].length > 0;
    }

    // Column width (flex:x) for column by column number.
    flexAt(column: number): number {
        return this.flexSpan(column, column);
    }

    // Returns the flex amount occupied by a span of columns.
    flexSpan(column1: number, column2: number): number {
        let flex = 0;
        for (let i = column1; i <= column2; i++) {
            let value = this.flexSettings[i];
            if (this.expand === i) { value = value * 3; }
            flex += value;
        }
        return flex;
    }

    volCountChanged(orgNode: HoldingsTreeNode, count: number) {
        if (count === null) { return; }
        const diff = count - orgNode.children.length;
        if (diff > 0) {
            this.createVols(orgNode, diff);
        } else if (diff < 0) {
            this.deleteVols(orgNode, -diff);
        }
    }


    addVol(org: IdlObject) {
        if (!org) { return; }
        const orgNode = this.context.findOrCreateOrgNode(org.id());
        this.createVols(orgNode, 1);
    }

    existingVolCount(orgNode: HoldingsTreeNode): number {
        return orgNode.children.filter(volNode => !volNode.target.isnew()).length;
    }

    existingCopyCount(volNode: HoldingsTreeNode): number {
        return volNode.children.filter(copyNode => !copyNode.target.isnew()).length;
    }

    copyCountChanged(volNode: HoldingsTreeNode, count: number) {
        if (count === null) { return; }
        const diff = count - volNode.children.length;
        if (diff > 0) {
            this.createCopies(volNode, diff);
        } else if (diff < 0) {
            this.deleteCopies(volNode, -diff);
        }
    }

    // This only removes copies that were created during the
    // current editing session and have not yet been saved in the DB.
    deleteCopies(volNode: HoldingsTreeNode, count: number) {
        for (let i = 0;  i < count; i++) {
            const copyNode = volNode.children[volNode.children.length - 1];
            if (copyNode && copyNode.target.isnew()) {
                volNode.children.pop();
            } else {
                break;
            }
        }
    }

    createCopies(volNode: HoldingsTreeNode, count: number) {
        for (let i = 0; i < count; i++) {

            // Our context assumes copies are fleshed with volumes
            const vol = volNode.target;
            const copy = this.volcopy.createStubCopy(vol);
            copy.call_number(vol);
            this.context.findOrCreateCopyNode(copy);
        }
    }


    createVols(orgNode: HoldingsTreeNode, count: number) {
        const vols = [];
        for (let i = 0; i < count; i++) {

            // This will vivify the volNode if needed.
            const vol = this.volcopy.createStubVol(
                this.context.recordId, orgNode.target.id());

            vols.push(vol);

            // Our context assumes copies are fleshed with volumes
            const copy = this.volcopy.createStubCopy(vol);
            copy.call_number(vol);
            this.context.findOrCreateCopyNode(copy);
        }

        this.volcopy.setVolClassLabels(vols);
    }

    // This only removes vols that were created during the
    // current editing session and have not yet been saved in the DB.
    deleteVols(orgNode: HoldingsTreeNode, count: number) {
        for (let i = 0;  i < count; i++) {
            const volNode = orgNode.children[orgNode.children.length - 1];
            if (volNode && volNode.target.isnew()) {
                orgNode.children.pop();
            } else {
                break;
            }
        }
    }

    // When editing existing vols, be sure each has at least one copy.
    addStubCopies(volNode?: HoldingsTreeNode) {
        const nodes = volNode ? [volNode] : this.context.volNodes();

        nodes.forEach(vNode => {
            if (vNode.children.length === 0) {
                const vol = vNode.target;
                const copy = this.volcopy.createStubCopy(vol);
                copy.call_number(vol);
                this.context.findOrCreateCopyNode(copy);
            }
        });
    }

    applyVolValue(vol: IdlObject, key: string, value: any) {

        if (value === null && (key === 'prefix' || key === 'suffix')) {
            // -1 is the empty prefix/suffix value.
            value = -1;
        }

        if (vol[key]() !== value) {
            vol[key](value);
            vol.ischanged(true);
        }

        this.emitSaveChange();
    }

    applyCopyValue(copy: IdlObject, key: string, value: any) {
        if (copy[key]() !== value) {
            copy[key](value);
            copy.ischanged(true);
        }
    }

    copyPartChanged(copyNode: HoldingsTreeNode, entry: ComboboxEntry) {
        const copy = copyNode.target;
        const part = copyNode.target.parts()[0];

        if (entry) {

            const newPart =
                this.volcopy.bibParts[copy.call_number().record()]
                .filter(p => p.id() === entry.id)[0];

            // Nothing to change?
            if (part && part.id() === newPart.id()) { return; }

            copy.parts([newPart]);
            copy.ischanged(true);

        } else if (part) { // Part map no longer needed.

            copy.parts([]);
            copy.ischanged(true);
        }
    }

    batchVolApply() {
        this.context.volNodes().forEach(volNode => {
            const vol = volNode.target;
            if (this.batchVolClass) {
                this.applyVolValue(vol, 'label_class', this.batchVolClass.id);
            }
            if (this.batchVolPrefix) {
                this.applyVolValue(vol, 'prefix', this.batchVolPrefix.id);
            }
            if (this.batchVolSuffix) {
                this.applyVolValue(vol, 'suffix', this.batchVolSuffix.id);
            }
            if (this.batchVolLabel) {
                // Use label; could be freetext.
                this.applyVolValue(vol, 'label', this.batchVolLabel.label);
            }
        });
    }

    // Focus and select the next editable barcode.
    selectNextBarcode(id: number, previous?: boolean) {
        let found = false;
        let nextId: number = null;
        let firstId: number = null;

        let copies = this.context.copyList();
        if (previous) { copies = copies.reverse(); }

        // Find the ID of the next item.  If this is the last item,
        // loop back to the first item.
        copies.forEach(copy => {
            if (nextId !== null) { return; }

            // In case we have to loop back to the first copy.
            if (firstId === null && this.barcodeCanChange(copy)) {
                firstId = copy.id();
            }

            if (found) {
                if (nextId === null && this.barcodeCanChange(copy)) {
                    nextId = copy.id();
                }
            } else if (copy.id() === id) {
                found = true;
            }
        });

        this.renderer.selectRootElement(
                '#barcode-input-' + (nextId || firstId)).select();
    }

    barcodeCanChange(copy: IdlObject): boolean {
        return !this.volcopy.copyStatIsMagic(copy.status());
    }

    generateBarcodes() {
        this.autoBarcodeInProgress = true;

        // Autogen only replaces barcodes for items which are in
        // certain statuses.
        const copies = this.context.copyList()
        .filter((copy, idx) => {
            // During autogen we do not replace the first item,
            // so it's status is not relevant.
            return idx === 0 || this.barcodeCanChange(copy);
        });

        if (copies.length > 1) { // seed barcode will always be present
            this.proceedWithAutogen(copies)
            .then(_ => this.autoBarcodeInProgress = false);
        }
    }

    proceedWithAutogen(copyList: IdlObject[]): Promise<any> {

        const seedBarcode: string = copyList[0].barcode();
        copyList.shift(); // Avoid replacing the seed barcode

        const count = copyList.length;

        return this.net.request('open-ils.cat',
            'open-ils.cat.item.barcode.autogen',
            this.auth.token(), seedBarcode, count, {
                checkdigit: this.useCheckdigit,
                skip_dupes: true
            }
        ).pipe(tap(barcodes => {

            copyList.forEach(copy => {
                if (copy.barcode() !== barcodes[0]) {
                    copy.barcode(barcodes[0]);
                    copy.ischanged(true);
                }
                barcodes.shift();
            });

        })).toPromise();
    }

    barcodeChanged(copy: IdlObject, barcode: string) {
        // note: copy.barcode(barcode) applied via ngModel
        copy.ischanged(true);
        copy._dupe_barcode = false;

        if (!barcode) {
            this.emitSaveChange();
            return;
        }

        if (!this.autoBarcodeInProgress) {
            // Manual barcode entry requires dupe check

            copy._dupe_barcode = false;
            this.pcrud.search('acp', {
                deleted: 'f',
                barcode: barcode,
                id: {'!=': copy.id()}
            }).subscribe(
                resp => {
                    if (resp) { copy._dupe_barcode = true; }
                },
                err => {},
                () => this.emitSaveChange()
            );
        }
    }

    deleteCopy(copyNode: HoldingsTreeNode) {

        if (copyNode.target.isnew()) {
            // Confirmation not required when deleting brand new copies.
            this.deleteOneCopy(copyNode);
            return;
        }

        this.deleteCopyCount = 1;
        this.confirmDelCopy.open().toPromise().then(confirmed => {
            if (confirmed) { this.deleteOneCopy(copyNode); }
        });
    }

    deleteOneCopy(copyNode: HoldingsTreeNode) {
        const targetCopy = copyNode.target;

        const orgNodes = this.context.orgNodes();
        for (let orgIdx = 0; orgIdx < orgNodes.length; orgIdx++) {
            const orgNode = orgNodes[orgIdx];

            for (let volIdx = 0; volIdx < orgNode.children.length; volIdx++) {
                const volNode = orgNode.children[volIdx];

                for (let copyIdx = 0; copyIdx < volNode.children.length; copyIdx++) {
                    const copy = volNode.children[copyIdx].target;

                    if (copy.id() === targetCopy.id()) {
                        volNode.children.splice(copyIdx, 1);
                        if (!copy.isnew()) {
                            copy.isdeleted(true);
                            this.context.copiesToDelete.push(copy);
                        }

                        if (volNode.children.length === 0) {
                            // When removing the last copy, add a stub copy.
                            this.addStubCopies();
                        }

                        return;
                    }
                }
            }
        }
    }


    deleteVol(volNode: HoldingsTreeNode) {

        if (volNode.target.isnew()) {
            // Confirmation not required when deleting brand new vols.
            this.deleteOneVol(volNode);
            return;
        }

        this.deleteVolCount = 1;
        this.deleteCopyCount = volNode.children.length;

        this.confirmDelVol.open().toPromise().then(confirmed => {
            if (confirmed) { this.deleteOneVol(volNode); }
        });
    }

    deleteOneVol(volNode: HoldingsTreeNode) {

        let deleteVolIdx = null;
        const targetVol = volNode.target;

        // FOR loops allow for early exit
        const orgNodes = this.context.orgNodes();
        for (let orgIdx = 0; orgIdx < orgNodes.length; orgIdx++) {
            const orgNode = orgNodes[orgIdx];

            for (let volIdx = 0; volIdx < orgNode.children.length; volIdx++) {
                const vol = orgNode.children[volIdx].target;

                if (vol.id() === targetVol.id()) {
                    deleteVolIdx = volIdx;

                    if (vol.isnew()) {
                        // New volumes, which can only have new copies
                        // may simply be removed from the holdings
                        // tree to delete them.
                        break;
                    }

                    // Mark volume and attached copies as deleted
                    // and track for later deletion.
                    targetVol.isdeleted(true);
                    this.context.volsToDelete.push(targetVol);

                    // When deleting vols, no need to delete the linked
                    // copies.  They'll be force deleted via the API.
                }

                if (deleteVolIdx !== null) { break; }
            }

            if (deleteVolIdx !== null) {
                orgNode.children.splice(deleteVolIdx, 1);
                break;
            }
        }
    }

    displayColumn(field: string): boolean {
        return this.volcopy.defaults.hidden[field] !== true;
    }

    saveUseCheckdigit() {
        this.volcopy.defaults.values.use_checkdigit = this.useCheckdigit === true;
        this.volcopy.saveDefaults();
    }

    canSave(): boolean {

        const copies = this.context.copyList();

        const badCopies = copies.filter(copy => {
            return copy._dupe_barcode || (!copy.isnew() && !copy.barcode());
        }).length > 0;

        if (badCopies) { return false; }

        const badVols = this.context.volNodes().filter(volNode => {
            const vol = volNode.target;
            return !(
                vol.prefix() && vol.label() && vol.suffix && vol.label_class()
            );
        }).length > 0;

        return !badVols;
    }

    // Called any time a change occurs that could affect the
    // save-ability of the form.
    emitSaveChange() {
        setTimeout(() => {
            this.canSaveChange.emit(this.canSave());
        });
    }
}

