import {Component, OnInit, Input, ViewChild} from '@angular/core';
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

const FLESH_PATRON_FIELDS = {
  flesh: 1,
  flesh_fields: {
    au: ['card', 'mailing_address', 'billing_address', 'addresses', 'settings']
  }
};

@Component({
  templateUrl: 'edit.component.html',
  selector: 'eg-patron-edit',
  styleUrls: ['edit.component.css']
})
export class EditComponent implements OnInit {

    @Input() patronId: number;
    @Input() cloneId: number;
    @Input() stageUsername: string;

    @ViewChild('profileSelect')
        private profileSelect: ProfileSelectComponent;
    @ViewChild('secondaryGroupsDialog')
        private secondaryGroupsDialog: SecondaryGroupsDialogComponent;

    patron: IdlObject;
    changeHandlerNeeded = false;
    nameTab = 'primary';
    loading = false;

    identTypes: ComboboxEntry[];
    userSettings: {[name: string]: any} = {};
    userSettingTypes: {[name: string]: IdlObject} = {};
    optInSettingTypes: {[name: string]: IdlObject} = {};
    expireDate: Date;
    secondaryGroups: IdlObject[];

    // All locations we have the specified permissions
    permOrgs: {[name: string]: number[]};

    // True if a given perm is grnated at the current home_ou of the
    // patron we are editing.
    hasPerm: {[name: string]: boolean} = {};

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
        private patronService: PatronService,
        public context: PatronContextService
    ) {}

    ngOnInit() {
        this.load();
    }

    load(): Promise<any> {
        this.loading = true;
        return this.loadPatron()
        .then(_ => this.getSecondaryGroups())
        .then(_ => this.applyPerms())
        .then(_ => this.setIdentTypes())
        .then(_ => this.setOptInSettings())
        .finally(() => this.loading = false);
    }

    getSecondaryGroups(): Promise<any> {

          return this.net.request(
              'open-ils.actor',
              'open-ils.actor.user.get_groups',
              this.auth.token(), this.patronId

          ).pipe(concatMap(maps => this.pcrud.search('pgt',
              {id: maps.map(m => m.grp())}, {}, {atomic: true})

          )).pipe(tap(grps => this.secondaryGroups = grps)).toPromise();
    }

    setIdentTypes(): Promise<any> {
        return this.patronService.getIdentTypes()
        .then(types => {
            this.identTypes = types.map(t => ({id: t.id(), label: t.name()}));
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
            return this.patronService.getById(this.patronId, FLESH_PATRON_FIELDS)
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

        this.expireDate = new Date(this.patron.expire_date());
    }

    createNewPatron() {
        const patron = this.idl.create('au');
        patron.isnew(true);
        patron.addresses([]);
        patron.settings([]);

        const card = this.idl.create('ac');
        card.isnew(true);
        card.usr(-1);
        patron.card(card);

        this.patron = patron;
    }

    objectFromPath(path: string): IdlObject {
        return path ? this.patron[path]() : this.patron;
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

    getFieldValue(path: string, field: string): any {
        return this.objectFromPath(path)[field]();
    }

    userSettingChange(name: string, value: any) {
        // TODO: set dirty
        this.userSettings[name] = value;
    }

    // Called as the model changes.
    // This may be called many times before the final value is applied,
    // so avoid any heavy lifting here.  See afterFieldChange();
    fieldValueChange(path: string, field: string, value: any) {
        if (typeof value === 'boolean') { value = value ? 't' : 'f'; }
        this.changeHandlerNeeded = true;
        this.objectFromPath(path)[field](value);
    }

    // Called after a change operation has completed (e.g. on blur)
    afterFieldChange(path: string, field: string) {
        if (!this.changeHandlerNeeded) { return; } // no changes applied
        this.changeHandlerNeeded = false;

        // TODO: set dirty


        const obj = path ? this.patron[path]() : this.patron;
        const value = obj[field]();

        console.debug(`Modifying field path=${path} field=${field} value=${value}`);

        switch (field) {
            // TODO: do many more

            case 'profile':
                this.setExpireDate();
                break;
        }
    }

    showField(idlClass: string, field: string): boolean {
      // TODO
      return true;
    }

    fieldRequired(idlClass: string, field: string): boolean {
        // TODO
        return false;
    }


    fieldPattern(idlClass: string, field: string): string {
        // TODO
        return null;
    }

    generatePassword() {
        this.fieldValueChange(null,
          'passwd', Math.floor(Math.random() * 9000) + 1000);

        // Normally this is called on (blur), but the input is not
        // focused when using the generate button.
        this.afterFieldChange(null, 'passwd');
    }


    cannotHaveUsersOrgs(): number[] {
        return this.org.list()
          .filter(org => org.ou_type().can_have_users() === 'f')
          .map(org => org.id());
    }

    setExpireDate() {
        const profile = this.profileSelect.profiles[this.patron.profile()];
        if (!profile) { return; }

        const seconds = DateUtil.intervalToSeconds(profile.perm_interval());
        const nowEpoch = new Date().getTime();
        const newDate = new Date(nowEpoch + (seconds * 1000 /* millis */));
        this.expireDate = newDate;
        this.fieldValueChange(null, 'profile', newDate.toISOString());
        this.afterFieldChange(null, 'profile');
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
}

