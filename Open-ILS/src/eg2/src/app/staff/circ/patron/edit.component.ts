import {Component, OnInit, AfterViewInit, Input, ViewChild} from '@angular/core';
import {Router, ActivatedRoute, ParamMap} from '@angular/router';
import {concatMap, tap} from 'rxjs/operators';
import {NgbNav, NgbNavChangeEvent} from '@ng-bootstrap/ng-bootstrap';
import {OrgService} from '@eg/core/org.service';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {NetService} from '@eg/core/net.service';
import {AuthService} from '@eg/core/auth.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {PatronService} from '@eg/staff/share/patron/patron.service';
import {PatronContextService} from './patron.service';
import {ComboboxComponent, ComboboxEntry} from '@eg/share/combobox/combobox.component';
import {DateUtil} from '@eg/share/util/date';
import {ProfileSelectComponent} from '@eg/staff/share/patron/profile-select.component';
import {ToastService} from '@eg/share/toast/toast.service';
import {StringService} from '@eg/share/string/string.service';
import {EventService} from '@eg/core/event.service';
import {PermService} from '@eg/core/perm.service';
import {SecondaryGroupsDialogComponent} from './secondary-groups.component';
import {ServerStoreService} from '@eg/core/server-store.service';
import {EditToolbarComponent, VisibilityLevel} from './edit-toolbar.component';
import {PatronSearchFieldSet} from '@eg/staff/share/patron/search.component';

const COMMON_USER_SETTING_TYPES = [
  'circ.holds_behind_desk',
  'circ.collections.exempt',
  'opac.hold_notify',
  'opac.default_phone',
  'opac.default_pickup_location',
  'opac.default_sms_carrier',
  'opac.default_sms_notify'
];

const PERMS_NEEDED = [
    'EDIT_SELF_IN_CLIENT',
    'UPDATE_USER',
    'CREATE_USER',
    'CREATE_USER_GROUP_LINK',
    'UPDATE_PATRON_COLLECTIONS_EXEMPT',
    'UPDATE_PATRON_CLAIM_RETURN_COUNT',
    'UPDATE_PATRON_CLAIM_NEVER_CHECKED_OUT_COUNT',
    'UPDATE_PATRON_ACTIVE_CARD',
    'UPDATE_PATRON_PRIMARY_CARD'
];

enum FieldVisibility {
    REQUIRED = 3,
    VISIBLE = 2,
    SUGGESTED = 1
}

// 3 == value universally required
// 2 == field is visible by default
// 1 == field is suggested by default
const DEFAULT_FIELD_VISIBILITY = {
    'ac.barcode': FieldVisibility.REQUIRED,
    'au.usrname': FieldVisibility.REQUIRED,
    'au.passwd': FieldVisibility.REQUIRED,
    'au.first_given_name': FieldVisibility.REQUIRED,
    'au.family_name': FieldVisibility.REQUIRED,
    'au.pref_first_given_name': FieldVisibility.VISIBLE,
    'au.pref_family_name': FieldVisibility.VISIBLE,
    'au.ident_type': FieldVisibility.REQUIRED,
    'au.ident_type2': FieldVisibility.VISIBLE,
    'au.home_ou': FieldVisibility.REQUIRED,
    'au.profile': FieldVisibility.REQUIRED,
    'au.expire_date': FieldVisibility.REQUIRED,
    'au.net_access_level': FieldVisibility.REQUIRED,
    'aua.address_type': FieldVisibility.REQUIRED,
    'aua.post_code': FieldVisibility.REQUIRED,
    'aua.street1': FieldVisibility.REQUIRED,
    'aua.street2': FieldVisibility.VISIBLE,
    'aua.city': FieldVisibility.REQUIRED,
    'aua.county': FieldVisibility.VISIBLE,
    'aua.state': FieldVisibility.VISIBLE,
    'aua.country': FieldVisibility.REQUIRED,
    'aua.valid': FieldVisibility.VISIBLE,
    'aua.within_city_limits': FieldVisibility.VISIBLE,
    'stat_cats': FieldVisibility.SUGGESTED,
    'surveys': FieldVisibility.SUGGESTED,
    'au.name_keywords': FieldVisibility.SUGGESTED
};

interface StatCat {
    cat: IdlObject;
    entries: ComboboxEntry[];
}

@Component({
  templateUrl: 'edit.component.html',
  selector: 'eg-patron-edit',
  styleUrls: ['edit.component.css']
})
export class EditComponent implements OnInit, AfterViewInit {

    @Input() patronId: number;
    @Input() cloneId: number;
    @Input() stageUsername: string;

    _toolbar: EditToolbarComponent;
    @Input() set toolbar(tb: EditToolbarComponent) {
        if (tb !== this._toolbar) {
            this._toolbar = tb;

            // Our toolbar component may not be available during init,
            // since it pops in and out of existence depending on which
            // patron tab is open.  Wait until we know it's defined.
            if (tb) {
                tb.saveClicked.subscribe(_ => this.save());
                tb.saveCloneClicked.subscribe(_ => this.saveClone());
                tb.printClicked.subscribe(_ => this.printPatron());
            }
        }
    }

    get toolbar(): EditToolbarComponent {
        return this._toolbar;
    }

    @ViewChild('profileSelect')
        private profileSelect: ProfileSelectComponent;
    @ViewChild('secondaryGroupsDialog')
        private secondaryGroupsDialog: SecondaryGroupsDialogComponent;

    autoId = -1;
    patron: IdlObject;
    modifiedPatron: IdlObject;
    changeHandlerNeeded = false;
    nameTab = 'primary';
    loading = false;

    surveys: IdlObject[];
    smsCarriers: ComboboxEntry[];
    identTypes: ComboboxEntry[];
    inetLevels: ComboboxEntry[];
    statCats: StatCat[] = [];
    userStatCats: {[statId: number]: ComboboxEntry} = {};
    userSettings: {[name: string]: any} = {};
    userSettingTypes: {[name: string]: IdlObject} = {};
    optInSettingTypes: {[name: string]: IdlObject} = {};
    secondaryGroups: IdlObject[];
    expireDate: Date;
    changesPending = false;

    fieldPatterns: {[cls: string]: {[field: string]: RegExp}} = {
        au: {},
        ac: {},
        aua: {}
    };

    fieldVisibility: {[key: string]: FieldVisibility} = {};

    // All locations we have the specified permissions
    permOrgs: {[name: string]: number[]};

    // True if a given perm is grnated at the current home_ou of the
    // patron we are editing.
    hasPerm: {[name: string]: boolean} = {};

    holdNotifyTypes: {email?: boolean, phone?: boolean, sms?: boolean} = {};

    constructor(
        private org: OrgService,
        private net: NetService,
        private auth: AuthService,
        private pcrud: PcrudService,
        private idl: IdlService,
        private strings: StringService,
        private toast: ToastService,
        private perms: PermService,
        private evt: EventService,
        private serverStore: ServerStoreService,
        private patronService: PatronService,
        public context: PatronContextService
    ) {}

    ngOnInit() {
        this.load();
    }

    ngAfterViewInit() {
    }

    load(): Promise<any> {
        this.loading = true;
        return this.setStatCats()
        .then(_ => this.setSurveys())
        .then(_ => this.loadPatron())
        .then(_ => this.getSecondaryGroups())
        .then(_ => this.applyPerms())
        .then(_ => this.setIdentTypes())
        .then(_ => this.setInetLevels())
        .then(_ => this.setOptInSettings())
        .then(_ => this.setSmsCarriers())
        .then(_ => this.setFieldPatterns())
        .then(_ => this.loading = false);
    }

    setupToolbar() {
    }

    setSurveys(): Promise<any> {
        return this.patronService.getSurveys()
        .then(surveys => this.surveys = surveys);
    }

    surveyQuestionAnswers(question: IdlObject): ComboboxEntry[] {
        return question.answers().map(
            a => ({id: a.id(), label: a.answer(), fm: a}));
    }

    setStatCats(): Promise<any> {
        this.statCats = [];
        return this.patronService.getStatCats().then(cats => {
            cats.forEach(cat => {
                cat.id(Number(cat.id()));
                cat.entries().forEach(entry => entry.id(Number(entry.id())));

                const entries = cat.entries().map(entry =>
                    ({id: entry.id(), label: entry.value()}));

                this.statCats.push({
                    cat: cat,
                    entries: entries
                });
            });
        });
    }

    setSmsCarriers(): Promise<any> {
        if (!this.context.settingsCache['sms.enable']) {
            return Promise.resolve();
        }

        return this.patronService.getSmsCarriers().then(carriers => {
            this.smsCarriers = carriers.map(carrier => {
                return {
                    id: carrier.id(),
                    label: carrier.name()
                };
            });
        });
    }

    getSecondaryGroups(): Promise<any> {
        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.user.get_groups',
            this.auth.token(), this.patronId

        ).pipe(concatMap(maps => {
            if (maps.length === 0) { return []; }

            return this.pcrud.search('pgt',
                {id: maps.map(m => m.grp())}, {}, {atomic: true});

        })).pipe(tap(grps => this.secondaryGroups = grps)).toPromise();
    }

    setIdentTypes(): Promise<any> {
        return this.patronService.getIdentTypes()
        .then(types => {
            this.identTypes = types.map(t => ({id: t.id(), label: t.name()}));
        });
    }

    setInetLevels(): Promise<any> {
        return this.patronService.getInetLevels()
        .then(levels => {
            this.inetLevels = levels.map(t => ({id: t.id(), label: t.name()}));
        });
    }

    applyPerms(): Promise<any> {

        const promise = this.permOrgs ?
            Promise.resolve(this.permOrgs) :
            this.perms.hasWorkPermAt(PERMS_NEEDED, true);

        return promise.then(permOrgs => {
            this.permOrgs = permOrgs;
            Object.keys(permOrgs).forEach(perm =>
                this.hasPerm[perm] =
                  permOrgs[perm].includes(this.patron.home_ou())
            );
        });
    }

    setOptInSettings(): Promise<any> {
        const orgIds = this.org.ancestors(this.auth.user().ws_ou(), true);

        const query = {
            '-or' : [
                {name : COMMON_USER_SETTING_TYPES},
                {name : { // opt-in notification user settings
                    'in': {
                        select : {atevdef : ['opt_in_setting']},
                        from : 'atevdef',
                        // we only care about opt-in settings for
                        // event_defs our users encounter
                        where : {'+atevdef' : {owner : orgIds}}
                    }
                }}
            ]
        };

        return this.pcrud.search('cust', query, {}, {atomic : true})
        .toPromise().then(types => {

            types.forEach(stype => {
                this.userSettingTypes[stype.name()] = stype;
                if (!COMMON_USER_SETTING_TYPES.includes(stype.name())) {
                    this.optInSettingTypes[stype.name()] = stype;
                }
            });
        });
    }

    loadPatron(): Promise<any> {
        if (this.patronId) {
            return this.patronService.getFleshedById(this.patronId)
            .then(patron => {
                this.patron = patron;
                this.absorbPatronData();
            });
        } else {
            return Promise.resolve(this.createNewPatron());
        }
    }

    absorbPatronData() {
        this.patron.settings().forEach(setting => {
            const value = setting.value();
            if (value !== '' && value !== null) {
                this.userSettings[setting.name()] = JSON.parse(value);
            }
        });

        const holdNotify = this.userSettings['opac.hold_notify'];
        if (holdNotify) {
            this.holdNotifyTypes.email = holdNotify.match(/email/) !== null;
            this.holdNotifyTypes.phone = holdNotify.match(/phone/) !== null;
            this.holdNotifyTypes.sms = holdNotify.match(/sms/) !== null;
        }

        if (this.userSettings['opac.default_sms_carrier']) {
            this.userSettings['opac.default_sms_carrier'] =
                Number(this.userSettings['opac.default_sms_carrier']);
        }

        if (this.userSettings['opac.default_pickup_location']) {
            this.userSettings['opac.default_pickup_location'] =
                Number(this.userSettings['opac.default_pickup_location']);
        }

        this.expireDate = new Date(this.patron.expire_date());

        // stat_cat_entries() are entry maps under the covers.
        this.patron.stat_cat_entries().forEach(map => {

            const stat: StatCat =
                this.statCats.filter(s => s.cat.id() === map.stat_cat())[0];

            let cboxEntry: ComboboxEntry =
                stat.entries.filter(e => e.label === map.stat_cat_entry())[0];

            if (!cboxEntry) {
                // If the applied value is not in the list of entries,
                // create a freetext combobox entry for it.
                cboxEntry = {
                    id: null,
                    freetext: true,
                    label: map.stat_cat_entry(),
                    fm: map
                };

                stat.entries.unshift(cboxEntry);
            }

            this.userStatCats[map.stat_cat()] = cboxEntry;
        });
    }

    createNewPatron() {
        const patron = this.idl.create('au');
        patron.isnew(true);
        patron.addresses([]);
        patron.settings([]);
        patron.cards([]);
        patron.waiver_entries([]);

        const card = this.idl.create('ac');
        card.isnew(true);
        card.usr(-1);
        patron.card(card);
        patron.cards().push(card);

        this.patron = patron;
    }

    objectFromPath(path: string, index: number): IdlObject {
        const base = path ? this.patron[path]() : this.patron;
        if (index === null || index === undefined) {
            return base;
        } else {
            // Some paths lead to an array of objects.
            return base[index];
        }
    }

    getFieldLabel(idlClass: string, field: string, override?: string): string {
        return override ? override :
            this.idl.classes[idlClass].field_map[field].label;
    }

    // With this, the 'cls' specifier is only needed in the template
    // when it's not 'au', which is the base/common class.
    getClass(cls: string): string {
        return cls || 'au';
    }

    getFieldValue(path: string, index: number, field: string): any {
        return this.objectFromPath(path, index)[field]();
    }

    adjustSaveSate() {
        // Avoid responding to any value changes while we are loading
        if (this.loading) { return; }

        // TODO other checks

        this.changesPending = true;
        const canSave = document.querySelector('.ng-invalid') === null;
        this.toolbar.disableSaveStateChanged.emit(!canSave);
    }

    userStatCatChange(cat: IdlObject, entry: ComboboxEntry) {
        let map = this.patron.stat_cat_entries()
            .filter(m => m.stat_cat() === cat.id())[0];

        if (map) {
            if (entry) {
                map.stat_cat_entry(entry.label);
                map.ischanged(true);
                map.isdeleted(false);
            } else {
                map.isdeleted(true);
            }
        } else {
            map = this.idl.create('actscecm');
            map.isnew(true);
            map.stat_cat(cat.id());
            map.stat_cat_entry(entry.label);
            map.target_usr(this.patronId);
            this.patron.stat_cat_entries().push(map);
        }

        this.adjustSaveSate();
    }

    userSettingChange(name: string, value: any) {
        this.userSettings[name] = value;
        this.adjustSaveSate();
    }

    applySurveyResponse(question: IdlObject, answer: ComboboxEntry) {
        if (!this.patron.survey_responses()) {
            this.patron.survey_responses([]);
        }

        const responses = this.patron.survey_responses()
            .filter(r => r.question() !== question.id());

        const resp = this.idl.create('asvr');
        resp.isnew(true);
        resp.survey(question.survey());
        resp.question(question.id());
        resp.answer(answer.id);
        resp.usr(this.patron.id());
        resp.answer_date('now');
        responses.push(resp);
        this.patron.survey_responses(responses);
    }

    // Called as the model changes.
    // This may be called many times before the final value is applied,
    // so avoid any heavy lifting here.  See afterFieldChange();
    fieldValueChange(path: string, index: number, field: string, value: any) {
        if (typeof value === 'boolean') { value = value ? 't' : 'f'; }

        // This can be called in cases where components fire up, even
        // though the actual value on the patron has not changed.
        // Exit early in that case so we don't mark the form as dirty.
        const oldValue = this.getFieldValue(path, index, field);
        if (oldValue === value) { return; }

        this.changeHandlerNeeded = true;
        this.objectFromPath(path, index)[field](value);
    }

    // Called after a change operation has completed (e.g. on blur)
    afterFieldChange(path: string, index: number, field: string) {
        if (!this.changeHandlerNeeded) { return; } // no changes applied
        this.changeHandlerNeeded = false;

        const obj = this.objectFromPath(path, index);
        const value = this.getFieldValue(path, index, field);
        obj.ischanged(true); // isnew() supersedes

        console.debug(
            `Modifying field path=${path || ''} field=${field} value=${value}`);

        switch (field) {
            // TODO: do many more
            // open-ils.actor.barcode.exists / ditto username

            case 'profile':
                this.setExpireDate();
                break;

            case 'day_phone':
                // TODO: patron.password.use_phone
                // TODO: hold related contact info
                this.dupeValueChange(field, value);
                break;

            case 'evening_phone':
            case 'other_phone':
                // TODO hold related contact info
                this.dupeValueChange(field, value);
                break;

            case 'ident_value':
            case 'ident_value2':
            case 'first_given_name':
            case 'family_name':
            case 'email':
                this.dupeValueChange(field, value);
                break;

            case 'street1':
            case 'street2':
            case 'city':
                // dupe search on address wants the address object as the value.
                this.dupeValueChange('address', obj);
                // TODO address_alert(obj);
                break;
        }

        this.adjustSaveSate();
    }

    dupeValueChange(name: string, value: any) {

        if (name.match(/phone/)) { name = 'phone'; }
        if (name.match(/name/)) { name = 'name'; }
        if (name.match(/ident/)) { name = 'ident'; }

        let search: PatronSearchFieldSet;
        switch (name) {

            case 'name':
                const fname = this.patron.first_given_name();
                const lname = this.patron.family_name();
                search = {
                    first_given_name : {value : fname, group : 0},
                    family_name : {value : lname, group : 0}
                };
                break;

            case 'email':
                search = {email : {value : value, group : 0}};
                break;

            case 'ident':
                search = {ident : {value : value, group : 2}};
                break;

            case 'phone':
                search = {phone : {value : value, group : 2}};
                break;

            case 'address':
                search = {};
                ['street1', 'street2', 'city', 'post_code'].forEach(field => {
                    if (value[field]()) {
                        search[field] = {value : value[field](), group: 1};
                    }
                });
                break;
        }

        this.toolbar.checkDupes(name, search);
    }

    showField(field: string): boolean {

        if (this.fieldVisibility[field] === undefined) {
            // Settings have not yet been applied for this field.
            // Calculate them now.

            // The preferred name fields use the primary name field settings
            let settingKey = field;
            let altName = false;
            if (field.match(/^au.alt_/)) {
                altName = true;
                settingKey = field.replace(/alt_/, '');
            }

            const required = `ui.patron.edit.${settingKey}.require`;
            const show = `ui.patron.edit.${settingKey}.show`;
            const suggest = `ui.patron.edit.${settingKey}.suggest`;

            if (this.context.settingsCache[required]) {
                if (altName) {
                    // Preferred name fields are never required.
                    this.fieldVisibility[field] = FieldVisibility.VISIBLE;
                } else {
                    this.fieldVisibility[field] = FieldVisibility.REQUIRED;
                }

            } else if (this.context.settingsCache[show]) {
                this.fieldVisibility[field] = FieldVisibility.VISIBLE;

            } else if (this.context.settingsCache[suggest]) {
                this.fieldVisibility[field] = FieldVisibility.SUGGESTED;
            }
        }

        if (this.fieldVisibility[field] === undefined) {
            // No org settings were applied above.  Use the default
            // settings if present or assume the field has no
            // visibility flags applied.
            this.fieldVisibility[field] = DEFAULT_FIELD_VISIBILITY[field] || 0;
        }

        return this.fieldVisibility[field] >= this.toolbar.visibilityLevel;
    }

    fieldRequired(field: string): boolean {

        // Password field is not required for existing patrons.
        if (field === 'au.passwd' && !this.patronId) {
            return false;
        }

        return this.fieldVisibility[field] === 3;
    }


    fieldPattern(idlClass: string, field: string): RegExp {
        if (!this.fieldPatterns[idlClass][field]) {
            this.fieldPatterns[idlClass][field] = new RegExp('.*');
        }
        return this.fieldPatterns[idlClass][field];
    }

    generatePassword() {
        this.fieldValueChange(null, null,
          'passwd', Math.floor(Math.random() * 9000) + 1000);

        // Normally this is called on (blur), but the input is not
        // focused when using the generate button.
        this.afterFieldChange(null, null, 'passwd');
    }


    cannotHaveUsersOrgs(): number[] {
        return this.org.list()
          .filter(org => org.ou_type().can_have_users() === 'f')
          .map(org => org.id());
    }

    cannotHaveVolsOrgs(): number[] {
        return this.org.list()
          .filter(org => org.ou_type().can_have_vols() === 'f')
          .map(org => org.id());
    }

    setExpireDate() {
        const profile = this.profileSelect.profiles[this.patron.profile()];
        if (!profile) { return; }

        const seconds = DateUtil.intervalToSeconds(profile.perm_interval());
        const nowEpoch = new Date().getTime();
        const newDate = new Date(nowEpoch + (seconds * 1000 /* millis */));
        this.expireDate = newDate;
        this.fieldValueChange(null, null, 'profile', newDate.toISOString());
        this.afterFieldChange(null, null, 'profile');
    }

    handleBoolResponse(success: boolean,
        msg: string, errMsg?: string): Promise<boolean> {

        if (success) {
            return this.strings.interpolate(msg)
            .then(str => this.toast.success(str))
            .then(_ => true);
        }

      console.error(errMsg);

      return this.strings.interpolate(msg)
      .then(str => this.toast.danger(str))
      .then(_ => false);
    }

    sendTestMessage(hook: string): Promise<boolean> {

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.event.test_notification',
            this.auth.token(), {hook: hook, target: this.patronId}
        ).toPromise().then(resp => {

            if (resp && resp.template_output && resp.template_output() &&
                resp.template_output().is_error() === 'f') {
                return this.handleBoolResponse(
                    true, 'circ.patron.edit.test_notify.success');

            } else {
                return this.handleBoolResponse(
                    false, 'circ.patron.edit.test_notify.fail',
                    'Test Notification Failed ' + resp);
            }
        });
    }

    invalidateField(field: string): Promise<boolean> {

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.invalidate.' + field,
            this.auth.token(), this.patronId, null, this.patron.home_ou()

        ).toPromise().then(resp => {
            const evt = this.evt.parse(resp);

            if (evt && evt.textcode !== 'SUCCESS') {
                return this.handleBoolResponse(false,
                    'circ.patron.edit.invalidate.fail',
                    'Field Invalidation Failed: ' + resp);
            }

            this.patron[field](null);

            // Keep this in sync for future updates.
            this.patron.last_xact_id(resp.payload.last_xact_id[this.patronId]);

            return this.handleBoolResponse(
              true, 'circ.patron.edit.invalidate.success');
        });
    }

    openGroupsDialog() {
        this.secondaryGroupsDialog.open({size: 'lg'}).subscribe(groups => {
            if (!groups) { return; }

            this.secondaryGroups = groups;

            if (this.patron.isnew()) {
                // Links will be applied after the patron is created.
                return;
            }

            // Apply the new links to an existing user in real time
            this.applySecondaryGroups();
        });
    }

    applySecondaryGroups(): Promise<boolean> {

        const groupIds = this.secondaryGroups.map(grp => grp.id());

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.user.set_groups',
            this.auth.token(), this.patronId, groupIds
        ).toPromise().then(resp => {

            if (Number(resp) === 1) {
                return this.handleBoolResponse(
                    true, 'circ.patron.edit.grplink.success');

            } else {
                return this.handleBoolResponse(
                    false, 'circ.patron.edit.grplink.fail',
                    'Failed to change group links: ' + resp);
            }
        });
    }

    // Set the mailing or billing address
    setAddrType(addrType: string, addr: IdlObject, selected: boolean) {
        if (selected) {
            this.patron[addrType + '_address'](addr);
        } else {
            // Unchecking mailing/billing means we have to randomly
            // select another address to fill that role.  Select the
            // first address in the list (that does not match the
            // modifed address)
            this.patron.addresses().some(a => {
                if (a.id() !== addr.id()) {
                    this.patron[addrType + '_address'](a);
                    return true;
                }
            });
        }
    }

    deleteAddr(addr: IdlObject) {
        const addresses = this.patron.addresses();
        let promise = Promise.resolve(false);

        if (this.patron.isnew() && addresses.length === 1) {
            promise = this.serverStore.getItem(
                'ui.patron.registration.require_address');
        }

        promise.then(required => {
            if (required) {
                // TODO alert and exit
                return;
            }

            // Roll the mailing/billing designation to another
            // address when needed.
            if (this.patron.mailing_address().id() === addr.id()) {
                this.setAddrType('mailing', addr, false);
            }

            if (this.patron.billing_address().id() === addr.id()) {
                this.setAddrType('billing', addr, false);
            }

            if (addr.isnew()) {
                let idx = 0;

                addresses.some((a, i) => {
                    if (a.id() === addr.id()) { idx = i; return true; }
                });

                // New addresses can be discarded
                addresses.splice(idx, 1);

            } else {
                addr.isdeleted(true);
            }
        });
    }

    newAddr() {
        const addr = this.idl.create('aua');
        addr.id(this.autoId--);
        addr.isnew(true);
        addr.valid('t');
        this.patron.addresses().push(addr);
    }

    nonDeletedAddresses(): IdlObject[] {
        return this.patron.addresses().filter(a => !a.isdeleted());
    }

    save(): Promise<any> {

        // TODO clear unload prompt

        this.loading = true;
        return this.saveUser()
        .then(_ => this.saveUserSettings())
        .then(_ => this.postSaveRedirect());
    }

    postSaveRedirect() {
        window.location.href = window.location.href;
    }

    saveClone() {
        // TODO
    }

    // Resolves on success, rejects on error
    saveUser(): Promise<IdlObject> {
        this.modifiedPatron = null;

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.patron.update',
            this.auth.token(), this.patron
        ).toPromise().then(result => {

            if (result && result.classname) {
                // Successful result returns the patron IdlObject.
                return this.modifiedPatron = result;
            }

            const evt = this.evt.parse(result);

            if (evt) {
                console.error('Patron update failed with', evt);
                if (evt.textcode === 'XACT_COLLISION') {
                    // TODO alert
                }
            }

            alert('Patron update failed:' + result);

            return Promise.reject('Save Failed');
        });
    }

    // Resolves on success, rejects on error
    saveUserSettings(): Promise<any> {

        let settings: any = {};

        if (this.patronId) {
            // Update all user editor setting values for existing
            // users regardless of whether a value changed.
            settings = this.userSettings;

        } else {

            // Create settings for all non-null setting values for new patrons.
            this.userSettings.forEach( (val, key) => {
                if (val !== null) { settings[key] = val; }
            });
        }

        if (Object.keys(settings).length === 0) { return Promise.resolve(); }

        return this.net.request(
            'open-ils.actor',
            'open-ils.actor.patron.settings.update',
            this.auth.token(), this.modifiedPatron.id(), settings
        ).toPromise();
    }

    printPatron() {
        // TODO
    }

    replaceBarcode() {
        // Disable current card
        this.patron.card().active('f');
        this.patron.card().ischanged(true);

        const card = this.idl.create('ac');
        card.isnew(true);
        card.id(this.autoId--);
        card.usr(this.patron.id());
        card.active('t');

        this.patron.card(card);
        this.patron.cards().push(card);
    }

    showBarcodes() {
    }

    canSave(): boolean {
        return document.querySelector('.ng-invalid') === null;
    }

    setFieldPatterns() {
        let regex;

        if (regex = this.context.settingsCache['opac.username_regex']) {
            this.fieldPatterns.au.usrname = new RegExp(regex);
        }

        if (regex =
            this.context.settingsCache['ui.patron.edit.ac.barcode.regex']) {
            this.fieldPatterns.ac.barcode = new RegExp(regex);
        }

        if (regex = this.context.settingsCache['global.password_regex']) {
            this.fieldPatterns.au.passwd = new RegExp(regex);
        }

        if (regex = this.context.settingsCache['ui.patron.edit.phone.regex']) {
            // apply generic phone regex first, replace below as needed.
            this.fieldPatterns.au.day_phone = new RegExp(regex);
            this.fieldPatterns.au.evening_phone = new RegExp(regex);
            this.fieldPatterns.au.other_phone = new RegExp(regex);
        }

        // the remaining this.fieldPatterns fit a well-known key name pattern

        Object.keys(this.context.settingsCache).forEach(key => {
            const val = this.context.settingsCache[key];
            if (!val) { return; }
            const parts = key.match(/ui.patron.edit\.(\w+)\.(\w+)\.regex/);
            if (!parts) { return; }
            const cls = parts[1];
            const name = parts[2];
            this.fieldPatterns[cls][name] = new RegExp(val);
        });
    }

    // The username must match either the configured regex or the
    // patron's barcode
    updateUsernameRegex() {
        const regex = this.context.settingsCache['opac.username_regex'];
        if (regex) {
            const barcode = this.patron.card().barcode();
            if (barcode) {
                this.fieldPatterns.au.usrname =
                    new RegExp(`${regex}|^${barcode}$`);
            } else {
                // username must match the regex
                this.fieldPatterns.au.usrname = new RegExp(regex);
            }
        } else {
            // username can be any format.
            this.fieldPatterns.au.usrname = new RegExp('.*');
        }
    }

}


