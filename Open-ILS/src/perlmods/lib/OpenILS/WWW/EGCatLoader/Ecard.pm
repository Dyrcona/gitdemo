package OpenILS::WWW::EGCatLoader;
use strict; use warnings;
use Apache2::Const -compile => qw(OK FORBIDDEN HTTP_INTERNAL_SERVER_ERROR);
use OpenSRF::Utils::Logger qw/$logger/;
use OpenSRF::Utils::JSON;
use OpenSRF::Utils qw/:datetime/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Application::AppUtils;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Event;
use Data::Dumper;
use LWP::UserAgent;
use DateTime;
use Digest::MD5 qw(md5_hex);
$Data::Dumper::Indent = 0;
my $U = 'OpenILS::Application::AppUtils';

my @api_fields = (
    {name => 'vendor_username', required => 1},
    {name => 'vendor_password', required => 1},
    {name => 'first_given_name', class => 'au', required => 1},
    {name => 'second_given_name', class => 'au'},
    {name => 'family_name', class => 'au', required => 1},
    {name => 'suffix', class => 'au'},
    {name => 'email', class => 'au', required => 1},
    {name => 'passwd', class => 'au', required => 1},
    {name => 'day_phone', class => 'au', required => 0},
    {name => 'dob', class => 'au', required => 1},
    {name => 'home_ou', class => 'au', required => 1},
    {name => 'ident_type', class => 'au', required => 0},
    {name => 'ident_value', class => 'au', required => 0},
    {name => 'guardian',
     class => 'au', 
     notes => "AKA parent/guardian",
     required_if => 'Patron is less than 18 years old'
    },
    {name => 'pref_first_given_name', class => 'au'},
    {name => 'pref_second_given_name', class => 'au'},
    {name => 'pref_family_name', class => 'au'},
    {name => 'pref_suffix', class => 'au'},
    {name => 'physical_street1', class => 'aua', required => 1},
    {name => 'physical_street1_name'},
    {name => 'physical_street2', class => 'aua'},
    {name => 'physical_city', class => 'aua', required => 1},
    {name => 'physical_post_code', class => 'aua', required => 1},
    {name => 'physical_county', class => 'aua', required => 1},
    {name => 'physical_state', class => 'aua', required => 1},
    {name => 'physical_country', class => 'aua', required => 1},
    {name => 'mailing_street1', class => 'aua', required => 1},
    {name => 'mailing_street1_name'},
    {name => 'mailing_street2', class => 'aua'},
    {name => 'mailing_city', class => 'aua', required => 1},
    {name => 'mailing_post_code', class => 'aua', required => 1},
    {name => 'mailing_county', class => 'aua', required => 1},
    {name => 'mailing_state', class => 'aua', required => 1},
    {name => 'mailing_country', class => 'aua', required => 1},
    {name => 'voter_registration', class => 'asvr', required => 0},
    {name => 'in_house_registration', required => 0},
    {name => 'newsletter', required => 0},
);


sub load_ecard_form {
    my $self = shift;
    my $path = shift; # Give us the path to determine the language
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;

    my $ctx_org = $ctx->{physical_loc} || $self->_get_search_lib();
    $ctx->{ecard} = {};
    $ctx->{ecard}->{enabled} = $U->is_true($U->ou_ancestor_setting_value(
        $ctx_org, 'opac.ecard_registration_enabled'
    ));
    $ctx->{ecard}->{quipu_id} = $U->ou_ancestor_setting_value(
        $ctx_org, 'lib.ecard_quipu_id'
    ) || 0;

    # Determine the language code from the path
    $ctx->{ecard}->{lang} = 'en'; # English is default
    if ($path =~ m|opac/ecard/form_([a-z]{2})|) {
        $ctx->{ecard}->{lang} = $1;
    }

    return Apache2::Const::OK;
}

# TODO: wrap the following in a check for a library setting as to whether or not
# to require emailed verification

## Random 6-character alpha-numeric code that avoids look-alike characters
## https://ux.stackexchange.com/questions/53341/are-there-any-letters-numbers-that-should-be-avoided-in-an-id
## Also exclude vowels to avoid creating any real (potentially offensive) words.
#my @code_chars = ('C','D','F','H','J'..'N','P','R','T','V','W','X','3','4','7','9');
#sub generate_verify_code {
#    my $string = '';
#    $string .= $code_chars[rand @code_chars] for 1..6;
#    return $string;
#}
#
#
## only if we're verifying the card via email
#sub load_ecard_verify {
#    my $self = shift;
#    my $cgi = $self->cgi;
#    $self->collect_header_footer;
#
#    # Loading the form.
#    return Apache2::Const::OK if $cgi->request_method eq 'GET';
#
#    #$self->verify_ecard;
#    return Apache2::Const::OK;
#}
#
#sub verify_ecard {
#    my $self = shift;
#    my $cgi = $self->cgi;
#    my $ctx = $self->ctx;
#    $self->log_params;
#
#    my $verify_code = $ctx->{verify_code} = $cgi->param('verification_code');
#    my $barcode = $ctx->{barcode} = $cgi->param('barcode');
#
#    $ctx->{verify_failed} = 1;
#
#    my $e = new_editor();
#
#    my $au = $e->search_actor_user({
#        profile => $PROVISIONAL_ECARD_GRP,
#        ident_type => $ECARD_VERIFY_IDENT,
#        ident_value => $verify_code
#    })->[0];
#
#    if (!$au) {
#        $logger->warn(
#            "ECARD: No provisional ecard found with code $verify_code");
#        sleep 2; # Mitigate brute-force attacks
#        return;
#    }
#
#    my $card = $e->search_actor_card({
#        usr => $au->id,
#        barcode => $barcode
#    })->[0];
#
#    if (!$card) {
#        $logger->warn("ECARD: Failed to match verify code ".
#            "($verify_code) with provided barcode ($barcode)");
#        sleep 2; # Mitigate brute-force attacks
#        return;
#    }
#
#    # Verification looks good.  Update the account.
#
#    my $grp = new_editor()->retrieve_permission_grp_tree($FULL_ECARD_GRP);
#
#    $au->profile($grp->id);
#    $au->expire_date(
#        DateTime->now(time_zone => 'local')->add(
#            seconds => interval_to_seconds($grp->perm_interval))->iso8601()
#    );
#
#    $e->xact_begin;
#
#    unless ($e->update_actor_user($au)) {
#        $logger->error("ECARD update failed for $barcode: " . $e->die_event);
#        return;
#    }
#    
#    $e->commit;
#    $logger->info("ECARD: Update to full ecard succeeded for $barcode");
#
#    $ctx->{verify_success} = 1;
#    $ctx->{verify_failed} = 0;
#
#    return;
#}


sub log_params {
    my $self = shift;
    my $cgi = $self->cgi;
    my @params = $cgi->param;

    my $msg = '';
    for my $p (@params) {
        next if $p =~ /pass/;
        $msg .= "|" if $msg; 
        $msg .= "$p=".$cgi->param($p);
    }

    $logger->info("ECARD: Submit params: $msg");
}

sub handle_testmode_api {
    my $self = shift;
    my $ctx = $self->ctx;

    # Strip data we don't want to publish.
    my @doc_fields;
    for my $field_info (@api_fields) {
        my $doc_info = {};
        for my $info_key (keys %$field_info) {
            $doc_info->{$info_key} = $field_info->{$info_key} 
                unless $info_key eq 'class';
        }
        push(@doc_fields, $doc_info);
    }

    $ctx->{response}->{messages} = [fields => \@doc_fields];
    $ctx->{response}->{status} = 'API_OK';
    return $self->compile_response;
}

sub handle_datamode_api {
    my $self = shift;
    my $datamode = shift;
    my $ctx = $self->ctx;

    if ($datamode =~ /org_units/) {
        my $orgs = new_editor()->search_actor_org_unit({opac_visible => 't'});
        my $list = [
            map { 
                {name => $_->name, id => $_->id, parent_ou => $_->parent_ou} 
            } @$orgs
        ];
        $ctx->{response}->{messages} = [org_units => $list];
    }

    $ctx->{response}->{status} = 'DATA_OK';
    return $self->compile_response;
}

sub load_ecard_submit {
    my $self = shift;
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;

    $self->log_params;

    my $testmode = $cgi->param('testmode') || '';
    my $datamode = $cgi->param('datamode') || '';

    my $e = $ctx->{editor} = new_editor();
    $ctx->{response} = {messages => []};

    if ($testmode eq 'CONNECT') {
        $ctx->{response}->{status} = 'CONNECT_OK';
        return $self->compile_response;
    }

    return Apache2::Const::FORBIDDEN unless 
        $cgi->request_method eq 'POST' &&
        $self->verify_vendor_host &&
        $self->login_vendor;

    if ($testmode eq 'AUTH') {
        # If we got this far, the caller is authorized.
        $ctx->{response}->{status} = 'AUTH_OK';
        return $self->compile_response;
    }

    return $self->handle_testmode_api if $testmode eq 'API';
    return $self->handle_datamode_api($datamode) if $datamode;

    return $self->compile_response unless $self->make_user;
    return $self->compile_response unless $self->add_addresses;
    return $self->compile_response unless $self->add_stat_cats;
    return $self->compile_response unless $self->check_dupes;
    return $self->compile_response unless $self->add_card;
    # Add survey responses commented out because it is not universal.
    # We should come up with a way to configure it before uncommenting
    # it globally.
    #return $self->compile_response unless $self->add_survey_responses;
    return $self->compile_response unless $self->save_user;
    return $self->compile_response unless $self->add_usr_settings;
    return $self->compile_response if $ctx->{response}->{status};

    # The code below does nothing in a stock Evergreen installation.
    # It is included in case a site wishes to set up action trigger
    # events to do some additional verification or notification for
    # patrons who have signed up for an eCard.
    $U->create_events_for_hook(
        'au.create.ecard', $ctx->{user}, $ctx->{user}->home_ou);

    $ctx->{response}->{status} = 'OK';
    $ctx->{response}->{barcode} = $ctx->{user}->card->barcode;
    $ctx->{response}->{expiration_date} = substr($ctx->{user}->expire_date, 0, 10);

    return $self->compile_response;
}

# E-card vendor is not a regular account.  They must have an entry in 
# the password table with password type ecard_vendor.
sub login_vendor {
    my $self = shift;
    my $username = $self->cgi->param('vendor_username');
    my $password = $self->cgi->param('vendor_password');
    my $home_ou = $self->cgi->param('home_ou');

    my $e = new_editor();
    my $vendor = $e->search_actor_user({usrname => $username})->[0];
    return 0 unless $vendor;

    return unless $U->verify_user_password(
        $e, $vendor->id, $password, 'ecard_vendor');

    # Auth checks out OK.  Manually create an authtoken
    my %admin_settings = $U->ou_ancestor_setting_batch_insecure(
        $home_ou,
        [
            'lib.ecard_admin_usrname',
            'lib.ecard_admin_org_unit'
        ]
    );
    my $admin_usr = $e->search_actor_user({usrname => $admin_settings{'lib.ecard_admin_usrname'}->{'value'}})->[0]
        || $vendor;
    my $admin_org = $admin_settings{'lib.ecard_admin_org_unit'}->{'value'} || 1;
    my $auth = $U->simplereq(
        'open-ils.auth_internal',
        'open-ils.auth_internal.session.create',
        {user_id => $admin_usr->id(), org_unit => $admin_org, login_type => 'temp'}
    );

    return unless $auth && $auth->{textcode} eq 'SUCCESS';

    $self->ctx->{authtoken} = $auth->{payload}->{authtoken};

    return 1;
}

sub verify_vendor_host {
    my $self = shift;
    # TODO
    # Confirm calling host matches AOUS ecard.vendor.host
    # NOTE: we may not have that information inside the firewall.
    return 1;
}


sub compile_response {
    my $self = shift;
    my $ctx = $self->ctx;
    $self->apache->content_type("application/json; charset=utf-8");
    $ctx->{response} = OpenSRF::Utils::JSON->perl2JSON($ctx->{response});
    $logger->info("ECARD responding with " . $ctx->{response});
    return Apache2::Const::OK;
}

my %keep_case = (usrname => 1, passwd => 1, email => 1);
sub upperclense {
    my $self = shift;
    my $field = shift;
    my $value = shift;
    $value = uc($value) unless $keep_case{$field};
    $value = lc($value) if $field eq 'email'; # force it
    $value =~ s/(^\s*|\s*$)//g;
    return $value;
}

# Create actor.usr perl object and populate column data
sub make_user {
    my $self = shift;
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;

    my $au = Fieldmapper::actor::user->new;

    $au->isnew(1);
    $au->net_access_level(1); # Filtered
    my $home_ou = $cgi->param('home_ou');

    my $perm_grp = $U->ou_ancestor_setting_value(
        $home_ou,
        'lib.ecard_patron_profile'
    );

    $au->profile($perm_grp);
    my $grp = new_editor()->retrieve_permission_grp_tree($perm_grp);

    $au->expire_date(
        DateTime->now(time_zone => 'local')->add(
            seconds => interval_to_seconds($grp->perm_interval))->iso8601()
    );

    for my $field_info (@api_fields) {
        my $field = $field_info->{name};
        next unless $field_info->{class} eq 'au';

        my $val = $cgi->param($field);

        $au->juvenile(1) if $field eq 'guardian' && $val;
        $au->day_phone(undef) if $field eq 'day_phone' && $val eq '--';

        if ($field_info->{required} && !$val) {
            my $msg = "Value required for field: '$field'";
            $ctx->{response}->{status} = 'INVALID_PARAMS';
            push(@{$ctx->{response}->{messages}}, $msg);
            $logger->error("ECARD $msg");
        }

        $self->verify_dob($val) if $field eq 'dob' && $val;
        $au->$field($val);
    }

    # CW MARS: Force ident_type to 1.
    $au->ident_type(1);

    return undef if $ctx->{response}->{status}; 
    return $ctx->{user} = $au;
}

sub add_card {
    my $self = shift;
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;
    my $user = $ctx->{user};
    my $home_ou = $cgi->param('home_ou');

    my %settings = $U->ou_ancestor_setting_batch_insecure(
        $home_ou,
        [
            'lib.ecard_barcode_prefix',
            'lib.ecard_barcode_length',
            'lib.ecard_barcode_calculate_checkdigit'
        ]
    );
    my $prefix = $settings{'lib.ecard_barcode_prefix'}->{'value'}
        || 'AUTO';
    my $length = $settings{'lib.card_barcode_length'}->{'value'}
        || 14;
    my $cd = $settings{'lib.ecard_barcode_calculate_checkdigit'}->{'value'}
        || 0;

    my $barcode = $U->generate_barcode(
        $prefix,
        $length,
        $U->is_true($cd),
        'actor.auto_barcode_ecard_seq'
    );

    $logger->info("ECARD using generated barcode: $barcode");

    my $card = Fieldmapper::actor::card->new;
    $card->id(-1);
    $card->isnew(1);
    $card->usr($user->id);
    $card->barcode($barcode);

    # username defaults to barcode
    $user->usrname($barcode);
    $user->card($card);
    $user->cards([$card]);

    return 1;
}

# Returns 1 on success, undef on error.
sub verify_dob {
    my $self = shift;
    my $dob = shift;
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;

    my @parts = split(/-/, $dob);
    my $dob_date;

    eval { # avoid dying on funky dates
        $dob_date = DateTime->new(
            year => $parts[0], month => $parts[1], day => $parts[2]);
    };

    if (!$dob_date || $dob_date > DateTime->now) {
        my $msg = "Invalid dob: '$dob'";
        $ctx->{response}->{status} = 'INVALID_PARAMS';
        push(@{$ctx->{response}->{messages}}, $msg);
        $logger->error("ECARD $msg");
        return undef;
    }

    # Check if guardian required for underage patrons.
    # TODO: Add our own setting for this.
    my $guardian_required = $U->ou_ancestor_setting_value(
        $cgi->param('home_ou'),
        'ui.patron.edit.guardian_required_for_juv'
    );

    my $comp_date = DateTime->now;
    $comp_date->set_hour(0);
    $comp_date->set_minute(0);
    $comp_date->set_second(0);
    # The juvenile age should be configurable.
    $comp_date->subtract(years => 18); # juv age

    if ($U->is_true($guardian_required)
        && $dob_date > $comp_date
        && !$cgi->param('guardian')) {

        my $msg = "Parent/Guardian (guardian) is required for patrons ".
            "under 18 years of age. dob=$dob";
        $ctx->{response}->{status} = 'INVALID_PARAMS';
        push(@{$ctx->{response}->{messages}}, $msg);
        $logger->error("ECARD $msg");
        return undef;
    }

    return 1;
}

# returns true if the addresses contain all of the same values.
sub addrs_match {
    my ($self, $addr1, $addr2) = @_;
    for my $field ($addr1->real_fields) {
        return 0 if ($addr1->$field() || '') ne ($addr2->$field() || '');
    }
    return 1;
}


sub add_addresses {
    my $self = shift;
    my $cgi = $self->cgi;
    my $ctx = $self->ctx;
    my $e = $ctx->{editor};
    my $user = $ctx->{user};

    my $physical_addr = Fieldmapper::actor::user_address->new;
    $physical_addr->isnew(1);
    $physical_addr->usr($user->id);
    $physical_addr->address_type('PHYSICAL');
    $physical_addr->within_city_limits('f');

    my $mailing_addr = Fieldmapper::actor::user_address->new;
    $mailing_addr->isnew(1);
    $mailing_addr->usr($user->id);
    $mailing_addr->address_type('MAILING');
    $mailing_addr->within_city_limits('f');

   # Use as both billing and mailing via virtual ID.
    $physical_addr->id(-1);
    $mailing_addr->id(-2);
    $user->billing_address(-1);
    $user->mailing_address(-2);

    # Confirm we have values for all of the required fields.
    # Apply values to our in-progress address object.
    for my $field_info (@api_fields) {
        my $field = $field_info->{name};
        next unless $field =~ /physical|mailing/;
        next if $field =~ /street1_/;

        my $val = $cgi->param($field);

        if ($field_info->{required} && !$val) {
            my $msg = "Value required for field: '$field'";
            $ctx->{response}->{status} = 'INVALID_PARAMS';
            push(@{$ctx->{response}->{messages}}, $msg);
            $logger->error("ECARD $msg");
        }

        if ($field =~ /physical/) {
            (my $col_field = $field) =~ s/physical_//g;
            $physical_addr->$col_field($val);
        } else {
            (my $col_field = $field) =~ s/mailing_//g;
            $mailing_addr->$col_field($val);
        }

    }

    # exit if there were any errors above.
    return undef if $ctx->{response}->{status}; 

    $user->billing_address($physical_addr);
    $user->mailing_address($mailing_addr);
    $user->addresses([$physical_addr, $mailing_addr]);

    return 1;
}

# TODO: The code in add_usr_settings is totally arbitrary and should
# be modified to look up settings in the database.
sub add_usr_settings {
    my $self = shift;
    my $cgi = $self->cgi;
    my $ctx = $self->ctx;
    my $user = $ctx->{user};
    my %settings = (
        'opac.hold_notify' => 'email'
    );

    $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.patron.settings.update',
        $self->ctx->{authtoken}, $user->id, \%settings);

    return 1;
}

# TODO: This implementation of add_survey_responses is PINES-specific.
# KCLS does something else.  The line that calls this subroutine is
# commented out above.  This should be modified to look up settings in
# the database.
sub add_survey_responses {
    my $self = shift;
    my $cgi = $self->cgi;
    my $user = $self->ctx->{user};
    my $answer = $cgi->param('voter_registration');

    my $survey_response = Fieldmapper::action::survey_response->new;
    $survey_response->id(-1);
    $survey_response->isnew(1);
    $survey_response->survey(1); # voter registration survey
    $survey_response->question(1);
    $survey_response->answer($answer);

    $user->survey_responses([$survey_response]);
    return 1;
}

# TODO: this is CW MARS-specific, but maybe we can make it something
# generic for adding stat cats to the patron

sub add_stat_cats {
   my $self = shift;
   my $cgi = $self->cgi;
   my $user = $self->ctx->{user};

   my $newsletter = $cgi->param('newsletter');
   my $map = Fieldmapper::actor::stat_cat_entry_user_map->new;
   $map->isnew(1);
   $map->stat_cat(28);
   $map->stat_cat_entry($newsletter ? 'Yes' : 'No');

   $user->stat_cat_entries([$map]);
   return 1;
}

# Returns true if no dupes found, false if dupes are found.
sub check_dupes {
    my $self = shift;
    my $ctx  = $self->ctx;
    my $user = $ctx->{user};
    my $addr = $user->addresses->[0];
    my $e = new_editor();

    #TODO: This list of fields should be configurable so that code
    #changes are not required for different sites with different
    #criteria.
    my @dupe_patron_fields = 
        qw/first_given_name family_name dob/;

    my $search = {
        first_given_name => {value => $user->first_given_name, group => 0},
        family_name => {value => $user->family_name, group => 0},
        dob => {value => substr($user->dob, 0, 4), group => 0} # birth year
    };

    my $root_org = $e->search_actor_org_unit({parent_ou => undef})->[0];

    my $ids = $U->storagereq(
        "open-ils.storage.actor.user.crazy_search", 
        $search,
        1000,           # search limit
        undef,          # sort
        1,              # include inactive
        $root_org->id,  # ws_ou
        $root_org->id   # search_ou
    );

    return 1 if @$ids == 0;

    $logger->info("ECARD found potential duplicate patrons: @$ids");

    if (my $streetname = $self->cgi->param('physical_street1_name')) {
        # We found matching patrons.  Perform a secondary check on the
        # address street name only.

        $logger->info("ECARD secondary search on street name: $streetname");

        my $addr_ids = $e->search_actor_user_address(
            {   usr => $ids,
                street1 => {'~*' => "(^| )$streetname( |\$)"}
            }, {idlist => 1}
        );

        if (@$addr_ids) {
            # we don't really care what patrons match at this point,
            # only whether a match is found.
            $ids = [1];
            $logger->info("ECARD secondary address check match(es) ".
                "found on address(es) @$addr_ids");

        } else {
            $ids = [];
            $logger->info(
                "ECARD secondary address check found no matches");
        }

    } else {
        $ids = [];
        # unclear if this is a possibility -- err on the side of allowing
        # the registration.
        $logger->info("ECARD found possible patron match but skipping ".
            "secondary street name check -- no street name was provided");
    }

    return 1 if @$ids == 0;

    $ctx->{response}->{status} = 'DUPLICATE';
    $ctx->{response}->{messages} = ['first_given_name', 
        'family_name', 'dob_year', 'billing_street1_name'];
    return undef;
}


sub save_user {
    my $self = shift;
    my $ctx = $self->ctx;
    my $cgi = $self->cgi;
    my $user = $ctx->{user};

    my $resp = $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.patron.update',
        $self->ctx->{authtoken}, $user
    );

    $resp = {textcode => 'UNKNOWN_ERROR'} unless $resp;

    if ($U->is_event($resp)) {

        my $msg = "Error creating user account: " . $resp->{textcode};
        $logger->error("ECARD: $msg");

        $ctx->{response}->{status} = 'CREATE_ERR';
        $ctx->{response}->{messages} = [{msg => $msg, pid => $$}];

        return 0;
    }

    $ctx->{user} = $resp;
    return 1;
}

1;

