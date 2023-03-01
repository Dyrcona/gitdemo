-- No pager for reingest selects
\pset pager off
--Upgrade Script for 3.7.3 to 3.10.1
\set eg_version '''3.10.1'''
BEGIN;
INSERT INTO config.upgrade_log (version, applied_to) VALUES ('3.10.1', :eg_version);

SELECT evergreen.upgrade_deps_block_check('1260', :eg_version);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'ui.patron.edit.au.photo_url.require',
        'gui',
        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.require',
            'Require Photo URL field on patron registration',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.require',
            'The Photo URL field will be required on the patron registration screen.',
            'coust',
            'description'
        ),
        'bool'
    );

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'ui.patron.edit.au.photo_url.show',
        'gui',
        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.show',
            'Show Photo URL field on patron registration',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.show',
            'The Photo URL field will be shown on the patron registration screen. Showing a field makes it appear with required fields even when not required. If the field is required this setting is ignored.',
            'coust',
            'description'
        ),
        'bool'
    );

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'ui.patron.edit.au.photo_url.suggest',
        'gui',
        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.suggest',
            'Suggest Photo URL field on patron registration',
            'coust',
            'label'
        ),

        oils_i18n_gettext(
            'ui.patron.edit.au.photo_url.suggest',
            'The Photo URL field will be suggested on the patron registration screen. Suggesting a field makes it appear when suggested fields are shown. If the field is shown or required this setting is ignored.',
            'coust',
            'description'
        ),
        'bool'
    );

INSERT INTO permission.perm_list ( id, code, description ) VALUES
( 632, 'UPDATE_USER_PHOTO_URL', oils_i18n_gettext( 632,
   'Update the user photo url field in patron registration and editor', 'ppl', 'description' ))
;

INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
        SELECT
                pgt.id, perm.id, aout.depth, FALSE
        FROM
                permission.grp_tree pgt,
                permission.perm_list perm,
                actor.org_unit_type aout
        WHERE
                pgt.name = 'Circulators' AND
                aout.name = 'System' AND
                perm.code = 'UPDATE_USER_PHOTO_URL'
;


SELECT evergreen.upgrade_deps_block_check('1267', :eg_version);

SELECT auditor.create_auditor ( 'acq', 'fund_debit' );



SELECT evergreen.upgrade_deps_block_check('1271', :eg_version);

INSERT INTO config.org_unit_setting_type
    (grp, name, datatype, label, description, update_perm, view_perm)
VALUES (
    'credit',
    'credit.processor.stripe.currency', 'string',
    oils_i18n_gettext(
        'credit.processor.stripe.currency',
        'Stripe ISO 4217 currency code',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'credit.processor.stripe.currency',
        'Use an all lowercase version of a Stripe-supported ISO 4217 currency code.  Defaults to "usd"',
        'coust',
        'description'
    ),
    (SELECT id FROM permission.perm_list WHERE code = 'ADMIN_CREDIT_CARD_PROCESSING'),
    (SELECT id FROM permission.perm_list WHERE code = 'VIEW_CREDIT_CARD_PROCESSING')
);


SELECT evergreen.upgrade_deps_block_check('1274', :eg_version);

CREATE INDEX poi_fund_debit_idx ON acq.po_item (fund_debit);
CREATE INDEX ii_fund_debit_idx ON acq.invoice_item (fund_debit);


SELECT evergreen.upgrade_deps_block_check('1275', :eg_version);

CREATE OR REPLACE FUNCTION acq.transfer_fund(
	old_fund   IN INT,
	old_amount IN NUMERIC,     -- in currency of old fund
	new_fund   IN INT,
	new_amount IN NUMERIC,     -- in currency of new fund
	user_id    IN INT,
	xfer_note  IN TEXT         -- to be recorded in acq.fund_transfer
	-- ,funding_source_in IN INT  -- if user wants to specify a funding source (see notes)
) RETURNS VOID AS $$
/* -------------------------------------------------------------------------------

Function to transfer money from one fund to another.

A transfer is represented as a pair of entries in acq.fund_allocation, with a
negative amount for the old (losing) fund and a positive amount for the new
(gaining) fund.  In some cases there may be more than one such pair of entries
in order to pull the money from different funding sources, or more specifically
from different funding source credits.  For each such pair there is also an
entry in acq.fund_transfer.

Since funding_source is a non-nullable column in acq.fund_allocation, we must
choose a funding source for the transferred money to come from.  This choice
must meet two constraints, so far as possible:

1. The amount transferred from a given funding source must not exceed the
amount allocated to the old fund by the funding source.  To that end we
compare the amount being transferred to the amount allocated.

2. We shouldn't transfer money that has already been spent or encumbered, as
defined by the funding attribution process.  We attribute expenses to the
oldest funding source credits first.  In order to avoid transferring that
attributed money, we reverse the priority, transferring from the newest funding
source credits first.  There can be no guarantee that this approach will
avoid overcommitting a fund, but no other approach can do any better.

In this context the age of a funding source credit is defined by the
deadline_date for credits with deadline_dates, and by the effective_date for
credits without deadline_dates, with the proviso that credits with deadline_dates
are all considered "older" than those without.

----------

In the signature for this function, there is one last parameter commented out,
named "funding_source_in".  Correspondingly, the WHERE clause for the query
driving the main loop has an OR clause commented out, which references the
funding_source_in parameter.

If these lines are uncommented, this function will allow the user optionally to
restrict a fund transfer to a specified funding source.  If the source
parameter is left NULL, then there will be no such restriction.

------------------------------------------------------------------------------- */ 
DECLARE
	same_currency      BOOLEAN;
	currency_ratio     NUMERIC;
	old_fund_currency  TEXT;
	old_remaining      NUMERIC;  -- in currency of old fund
	new_fund_currency  TEXT;
	new_fund_active    BOOLEAN;
	new_remaining      NUMERIC;  -- in currency of new fund
	curr_old_amt       NUMERIC;  -- in currency of old fund
	curr_new_amt       NUMERIC;  -- in currency of new fund
	source_addition    NUMERIC;  -- in currency of funding source
	source_deduction   NUMERIC;  -- in currency of funding source
	orig_allocated_amt NUMERIC;  -- in currency of funding source
	allocated_amt      NUMERIC;  -- in currency of fund
	source             RECORD;
    old_fund_row       acq.fund%ROWTYPE;
    new_fund_row       acq.fund%ROWTYPE;
    old_org_row        actor.org_unit%ROWTYPE;
    new_org_row        actor.org_unit%ROWTYPE;
BEGIN
	--
	-- Sanity checks
	--
	IF old_fund IS NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: old fund id is NULL';
	END IF;
	--
	IF old_amount IS NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: amount to transfer is NULL';
	END IF;
	--
	-- The new fund and its amount must be both NULL or both not NULL.
	--
	IF new_fund IS NOT NULL AND new_amount IS NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: amount to transfer to receiving fund is NULL';
	END IF;
	--
	IF new_fund IS NULL AND new_amount IS NOT NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: receiving fund is NULL, its amount is not NULL';
	END IF;
	--
	IF user_id IS NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: user id is NULL';
	END IF;
	--
	-- Initialize the amounts to be transferred, each denominated
	-- in the currency of its respective fund.  They will be
	-- reduced on each iteration of the loop.
	--
	old_remaining := old_amount;
	new_remaining := new_amount;
	--
	-- RAISE NOTICE 'Transferring % in fund % to % in fund %',
	--	old_amount, old_fund, new_amount, new_fund;
	--
	-- Get the currency types of the old and new funds.
	--
	SELECT
		currency_type
	INTO
		old_fund_currency
	FROM
		acq.fund
	WHERE
		id = old_fund;
	--
	IF old_fund_currency IS NULL THEN
		RAISE EXCEPTION 'acq.transfer_fund: old fund id % is not defined', old_fund;
	END IF;
	--
	IF new_fund IS NOT NULL THEN
		SELECT
			currency_type,
			active
		INTO
			new_fund_currency,
			new_fund_active
		FROM
			acq.fund
		WHERE
			id = new_fund;
		--
		IF new_fund_currency IS NULL THEN
			RAISE EXCEPTION 'acq.transfer_fund: new fund id % is not defined', new_fund;
		ELSIF NOT new_fund_active THEN
			--
			-- No point in putting money into a fund from whence you can't spend it
			--
			RAISE EXCEPTION 'acq.transfer_fund: new fund id % is inactive', new_fund;
		END IF;
		--
		IF new_amount = old_amount THEN
			same_currency := true;
			currency_ratio := 1;
		ELSE
			--
			-- We'll have to translate currency between funds.  We presume that
			-- the calling code has already applied an appropriate exchange rate,
			-- so we'll apply the same conversion to each sub-transfer.
			--
			same_currency := false;
			currency_ratio := new_amount / old_amount;
		END IF;
	END IF;

    -- Fetch old and new fund's information
    -- in order to construct the allocation notes
    SELECT INTO old_fund_row * FROM acq.fund WHERE id = old_fund;
    SELECT INTO old_org_row * FROM actor.org_unit WHERE id = old_fund_row.org;
    SELECT INTO new_fund_row * FROM acq.fund WHERE id = new_fund;
    SELECT INTO new_org_row * FROM actor.org_unit WHERE id = new_fund_row.org;

	--
	-- Identify the funding source(s) from which we want to transfer the money.
	-- The principle is that we want to transfer the newest money first, because
	-- we spend the oldest money first.  The priority for spending is defined
	-- by a sort of the view acq.ordered_funding_source_credit.
	--
	FOR source in
		SELECT
			ofsc.id,
			ofsc.funding_source,
			ofsc.amount,
			ofsc.amount * acq.exchange_ratio( fs.currency_type, old_fund_currency )
				AS converted_amt,
			fs.currency_type
		FROM
			acq.ordered_funding_source_credit AS ofsc,
			acq.funding_source fs
		WHERE
			ofsc.funding_source = fs.id
			and ofsc.funding_source IN
			(
				SELECT funding_source
				FROM acq.fund_allocation
				WHERE fund = old_fund
			)
			-- and
			-- (
			-- 	ofsc.funding_source = funding_source_in
			-- 	OR funding_source_in IS NULL
			-- )
		ORDER BY
			ofsc.sort_priority desc,
			ofsc.sort_date desc,
			ofsc.id desc
	LOOP
		--
		-- Determine how much money the old fund got from this funding source,
		-- denominated in the currency types of the source and of the fund.
		-- This result may reflect transfers from previous iterations.
		--
		SELECT
			COALESCE( sum( amount ), 0 ),
			COALESCE( sum( amount )
				* acq.exchange_ratio( source.currency_type, old_fund_currency ), 0 )
		INTO
			orig_allocated_amt,     -- in currency of the source
			allocated_amt           -- in currency of the old fund
		FROM
			acq.fund_allocation
		WHERE
			fund = old_fund
			and funding_source = source.funding_source;
		--	
		-- Determine how much to transfer from this credit, in the currency
		-- of the fund.   Begin with the amount remaining to be attributed:
		--
		curr_old_amt := old_remaining;
		--
		-- Can't attribute more than was allocated from the fund:
		--
		IF curr_old_amt > allocated_amt THEN
			curr_old_amt := allocated_amt;
		END IF;
		--
		-- Can't attribute more than the amount of the current credit:
		--
		IF curr_old_amt > source.converted_amt THEN
			curr_old_amt := source.converted_amt;
		END IF;
		--
		curr_old_amt := trunc( curr_old_amt, 2 );
		--
		old_remaining := old_remaining - curr_old_amt;
		--
		-- Determine the amount to be deducted, if any,
		-- from the old allocation.
		--
		IF old_remaining > 0 THEN
			--
			-- In this case we're using the whole allocation, so use that
			-- amount directly instead of applying a currency translation
			-- and thereby inviting round-off errors.
			--
			source_deduction := - curr_old_amt;
		ELSE 
			source_deduction := trunc(
				( - curr_old_amt ) *
					acq.exchange_ratio( old_fund_currency, source.currency_type ),
				2 );
		END IF;
		--
		IF source_deduction <> 0 THEN
			--
			-- Insert negative allocation for old fund in fund_allocation,
			-- converted into the currency of the funding source
			--
			INSERT INTO acq.fund_allocation (
				funding_source,
				fund,
				amount,
				allocator,
				note
			) VALUES (
				source.funding_source,
				old_fund,
				source_deduction,
				user_id,
				'Transfer to fund ' || new_fund_row.code || ' ('
                                    || new_fund_row.year || ') ('
                                    || new_org_row.shortname || ')'
			);
		END IF;
		--
		IF new_fund IS NOT NULL THEN
			--
			-- Determine how much to add to the new fund, in
			-- its currency, and how much remains to be added:
			--
			IF same_currency THEN
				curr_new_amt := curr_old_amt;
			ELSE
				IF old_remaining = 0 THEN
					--
					-- This is the last iteration, so nothing should be left
					--
					curr_new_amt := new_remaining;
					new_remaining := 0;
				ELSE
					curr_new_amt := trunc( curr_old_amt * currency_ratio, 2 );
					new_remaining := new_remaining - curr_new_amt;
				END IF;
			END IF;
			--
			-- Determine how much to add, if any,
			-- to the new fund's allocation.
			--
			IF old_remaining > 0 THEN
				--
				-- In this case we're using the whole allocation, so use that amount
				-- amount directly instead of applying a currency translation and
				-- thereby inviting round-off errors.
				--
				source_addition := curr_new_amt;
			ELSIF source.currency_type = old_fund_currency THEN
				--
				-- In this case we don't need a round trip currency translation,
				-- thereby inviting round-off errors:
				--
				source_addition := curr_old_amt;
			ELSE 
				source_addition := trunc(
					curr_new_amt *
						acq.exchange_ratio( new_fund_currency, source.currency_type ),
					2 );
			END IF;
			--
			IF source_addition <> 0 THEN
				--
				-- Insert positive allocation for new fund in fund_allocation,
				-- converted to the currency of the founding source
				--
				INSERT INTO acq.fund_allocation (
					funding_source,
					fund,
					amount,
					allocator,
					note
				) VALUES (
					source.funding_source,
					new_fund,
					source_addition,
					user_id,
				    'Transfer from fund ' || old_fund_row.code || ' ('
                                          || old_fund_row.year || ') ('
                                          || old_org_row.shortname || ')'
				);
			END IF;
		END IF;
		--
		IF trunc( curr_old_amt, 2 ) <> 0
		OR trunc( curr_new_amt, 2 ) <> 0 THEN
			--
			-- Insert row in fund_transfer, using amounts in the currency of the funds
			--
			INSERT INTO acq.fund_transfer (
				src_fund,
				src_amount,
				dest_fund,
				dest_amount,
				transfer_user,
				note,
				funding_source_credit
			) VALUES (
				old_fund,
				trunc( curr_old_amt, 2 ),
				new_fund,
				trunc( curr_new_amt, 2 ),
				user_id,
				xfer_note,
				source.id
			);
		END IF;
		--
		if old_remaining <= 0 THEN
			EXIT;                   -- Nothing more to be transferred
		END IF;
	END LOOP;
END;
$$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1276', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.acq.fund.fund_debit', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.fund.fund_debit',
        'Grid Config: eg.grid.acq.fund.fund_debit',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.fund.fund_transfer', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.fund.fund_transfer',
        'Grid Config: eg.grid.acq.fund.fund_transfer',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.fund.fund_allocation', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.fund.fund_allocation',
        'Grid Config: eg.grid.acq.fund.fund_allocation',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.acq.fund', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.acq.fund',
        'Grid Config: eg.grid.admin.acq.fund',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.acq.funding_source', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.acq.funding_source',
        'Grid Config: eg.grid.admin.acq.funding_source',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.funding_source.fund_allocation', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.funding_source.fund_allocation',
        'Grid Config: eg.grid.acq.funding_source.fund_allocation',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.funding_source.credit', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.funding_source.credit',
        'Grid Config: eg.grid.acq.funding_source.credit',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1277', :eg_version);

-- if there are any straggling funds without a code set, fix that
UPDATE acq.fund
SET code = 'FUND-WITH-ID-' || id
WHERE code IS NULL;

ALTER TABLE acq.fund
    ALTER COLUMN code SET NOT NULL;


SELECT evergreen.upgrade_deps_block_check('1278', :eg_version);

CREATE OR REPLACE VIEW reporter.asset_call_number_dewey AS
  SELECT id AS call_number,
    call_number_dewey(label) AS dewey,
    CASE WHEN call_number_dewey(label) ~ '^[0-9]+\.?[0-9]*$'::text
      THEN btrim(to_char(10::double precision * floor(call_number_dewey(label)::double precision / 10::double precision), '000'::text))
      ELSE NULL::text
    END AS dewey_block_tens,
    CASE WHEN call_number_dewey(label) ~ '^[0-9]+\.?[0-9]*$'::text
      THEN btrim(to_char(100::double precision * floor(call_number_dewey(label)::double precision / 100::double precision), '000'::text))
      ELSE NULL::text
    END AS dewey_block_hundreds,
    CASE WHEN call_number_dewey(label) ~ '^[0-9]+\.?[0-9]*$'::text
      THEN (btrim(to_char(10::double precision * floor(call_number_dewey(label)::double precision / 10::double precision), '000'::text)) || '-'::text)
      || btrim(to_char(10::double precision * floor(call_number_dewey(label)::double precision / 10::double precision) + 9::double precision, '000'::text))
      ELSE NULL::text
    END AS dewey_range_tens,
    CASE WHEN call_number_dewey(label) ~ '^[0-9]+\.?[0-9]*$'::text
      THEN (btrim(to_char(100::double precision * floor(call_number_dewey(label)::double precision / 100::double precision), '000'::text)) || '-'::text)
      || btrim(to_char(100::double precision * floor(call_number_dewey(label)::double precision / 100::double precision) + 99::double precision, '000'::text))
      ELSE NULL::text
    END AS dewey_range_hundreds
  FROM asset.call_number
  WHERE call_number_dewey(label) ~ '^[0-9]'::text;



SELECT evergreen.upgrade_deps_block_check('1281', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.cat.volcopy.defaults', 'cat', 'object',
    oils_i18n_gettext(
        'eg.cat.volcopy.defaults',
        'Holdings Editor Default Values and Visibility',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1284', :eg_version); -- blake / terranm / jboyer

INSERT INTO config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'circ.void_item_deposit', 'circ',
    oils_i18n_gettext('circ.void_item_deposit',
        'Void item deposit fee on checkin',
        'coust', 'label'),
    oils_i18n_gettext('circ.void_item_deposit',
        'If a deposit was charged when checking out an item, void it when the item is returned',
        'coust', 'description'),
    'bool', null);



SELECT evergreen.upgrade_deps_block_check('1285', :eg_version);

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'circ.primary_item_value_field',
        'circ',
        oils_i18n_gettext(
            'circ.primary_item_value_field',
            'Use Item Price or Cost as Primary Item Value',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'circ.primary_item_value_field',
            'Expects "price" or "cost" and defaults to price.  This refers to the corresponding field on the item record and gets used in such contexts as notices, max fine values when using item price caps (setting or fine rules), and long overdue, damaged, and lost billings.',
            'coust',
            'description'
        ),
        'string'
    );

INSERT into config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'circ.secondary_item_value_field',
        'circ',
        oils_i18n_gettext(
            'circ.secondary_item_value_field',
            'Use Item Price or Cost as Backup Item Value',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'circ.secondary_item_value_field',
            'Expects "price" or "cost", but defaults to neither.  This refers to the corresponding field on the item record and is used as a second-pass fall-through value when determining an item value.  If needed, Evergreen will still look at the "Default Item Price" setting as a final fallback.',
            'coust',
            'description'
        ),
        'string'
    );


SELECT evergreen.upgrade_deps_block_check('1286', :eg_version);

INSERT INTO config.org_unit_setting_type
( name, grp, label, description, datatype )
VALUES
( 'eg.staffcat.search_filters', 'gui',
  oils_i18n_gettext(
    'eg.staffcat.search_filters',
    'Staff Catalog Search Filters',
    'coust', 'label'),
  oils_i18n_gettext(
    'eg.staffcat.search_filters',
    'Array of advanced search filters to display, e.g. ["item_lang","audience","lit_form"]',
    'coust', 'description'),
  'array' );





SELECT evergreen.upgrade_deps_block_check('1287', :eg_version);

 INSERT into config.org_unit_setting_type
 ( name, grp, label, description, datatype, fm_class ) VALUES
 ( 'lib.my_account_url', 'lib',
     oils_i18n_gettext('lib.my_account_url',
         'My Account URL (such as "https://example.com/eg/opac/login")',
         'coust', 'label'),
     oils_i18n_gettext('lib.my_account_url',
         'URL for a My Account link. Use a complete URL, such as "https://example.com/eg/opac/login".',
         'coust', 'description'),
     'string', null)
 ;


SELECT evergreen.upgrade_deps_block_check('1288', :eg_version);

-- stage a copy of notes, temporarily setting
-- the id to the negative value for later ausp
-- id munging
CREATE TABLE actor.XXXX_penalty_notes AS
    SELECT id * -1 AS id, usr, org_unit, set_date, note
    FROM actor.usr_standing_penalty
    WHERE NULLIF(BTRIM(note),'') IS NOT NULL;

ALTER TABLE actor.usr_standing_penalty ALTER COLUMN id SET DEFAULT nextval('actor.usr_message_id_seq'::regclass);
ALTER TABLE actor.usr_standing_penalty ADD COLUMN usr_message BIGINT REFERENCES actor.usr_message(id);
CREATE INDEX usr_standing_penalty_usr_message_idx ON actor.usr_standing_penalty (usr_message);
ALTER TABLE actor.usr_standing_penalty DROP COLUMN note;

-- munge ausp IDs and aum IDs so that they're disjoint sets
UPDATE actor.usr_standing_penalty SET id = id * -1; -- move them out of the way to avoid mid-statement collisions

WITH messages AS ( SELECT COALESCE(MAX(id), 0) AS max_id FROM actor.usr_message )
UPDATE actor.usr_standing_penalty SET id = id * -1 + messages.max_id FROM messages;

-- doing the same thing to the staging table because
-- we had to grab a copy of ausp.note first. We had
-- to grab that copy first because we're both ALTERing
-- and UPDATEing ausp, and all of the ALTER TABLEs
-- have to be done before we can modify data in the table
-- lest ALTER TABLE gets blocked by a pending trigger
-- event
WITH messages AS ( SELECT COALESCE(MAX(id), 0) AS max_id FROM actor.usr_message )
UPDATE actor.XXXX_penalty_notes SET id = id * -1 + messages.max_id FROM messages;

SELECT SETVAL('actor.usr_message_id_seq'::regclass, COALESCE((SELECT MAX(id) FROM actor.usr_standing_penalty) + 1, 1), FALSE);

ALTER TABLE actor.usr_message ADD COLUMN pub BOOL NOT NULL DEFAULT FALSE;
ALTER TABLE actor.usr_message ADD COLUMN stop_date TIMESTAMP WITH TIME ZONE;
ALTER TABLE actor.usr_message ADD COLUMN editor	BIGINT REFERENCES actor.usr (id);
ALTER TABLE actor.usr_message ADD COLUMN edit_date TIMESTAMP WITH TIME ZONE;

DROP VIEW actor.usr_message_limited;
CREATE VIEW actor.usr_message_limited
AS SELECT * FROM actor.usr_message WHERE pub AND NOT deleted;

-- alright, let's set all existing user messages to public

UPDATE actor.usr_message SET pub = TRUE;

-- alright, let's migrate penalty notes to usr_messages and link the messages back to the penalties:

-- here is our staging table which will be shaped exactly like
-- actor.usr_message and use the same id sequence
CREATE TABLE actor.XXXX_usr_message_for_penalty_notes (
    LIKE actor.usr_message INCLUDING DEFAULTS 
);

INSERT INTO actor.XXXX_usr_message_for_penalty_notes (
    usr,
    title,
    message,
    create_date,
    sending_lib,
    pub
) SELECT
    usr,
    'Penalty Note ID ' || id,
    note,
    set_date,
    org_unit,
    FALSE
FROM
    actor.XXXX_penalty_notes
;

-- so far so good, let's push this into production

INSERT INTO actor.usr_message
    SELECT * FROM actor.XXXX_usr_message_for_penalty_notes;

-- and link the production penalties to these new user messages

UPDATE actor.usr_standing_penalty p SET usr_message = m.id
    FROM actor.XXXX_usr_message_for_penalty_notes m
    WHERE m.title = 'Penalty Note ID ' || p.id;

-- and remove the temporary overloading of the message title we used for this:

UPDATE
    actor.usr_message
SET
    title = message
WHERE
    id IN (SELECT id FROM actor.XXXX_usr_message_for_penalty_notes)
;

-- probably redundant here, but the spec calls for an assertion before removing
-- the note column from actor.usr_standing_penalty, so being extra cautious:
/*
do $$ begin
    assert (
        select count(*)
        from actor.XXXX_usr_message_for_penalty_notes
        where id not in (
            select id from actor.usr_message
        )
    ) = 0, 'failed migrating to actor.usr_message';
end; $$;
*/

-- combined view of actor.usr_standing_penalty and actor.usr_message for populating
-- staff Notes (formerly Messages) interface

CREATE VIEW actor.usr_message_penalty AS
SELECT -- ausp with or without messages
    ausp.id AS "id",
    ausp.id AS "ausp_id",
    aum.id AS "aum_id",
    ausp.org_unit AS "org_unit",
    ausp.org_unit AS "ausp_org_unit",
    aum.sending_lib AS "aum_sending_lib",
    ausp.usr AS "usr",
    ausp.usr as "ausp_usr",
    aum.usr as "aum_usr",
    ausp.standing_penalty AS "standing_penalty",
    ausp.staff AS "staff",
    ausp.set_date AS "create_date",
    ausp.set_date AS "ausp_set_date",
    aum.create_date AS "aum_create_date",
    ausp.stop_date AS "stop_date",
    ausp.stop_date AS "ausp_stop_date",
    aum.stop_date AS "aum_stop_date",
    ausp.usr_message AS "ausp_usr_message",
    aum.title AS "title",
    aum.message AS "message",
    aum.deleted AS "deleted",
    aum.read_date AS "read_date",
    aum.pub AS "pub",
    aum.editor AS "editor",
    aum.edit_date AS "edit_date"
FROM
    actor.usr_standing_penalty ausp
    LEFT JOIN actor.usr_message aum ON (ausp.usr_message = aum.id)
        UNION ALL
SELECT -- aum without penalties
    aum.id AS "id",
    NULL::INT AS "ausp_id",
    aum.id AS "aum_id",
    aum.sending_lib AS "org_unit",
    NULL::INT AS "ausp_org_unit",
    aum.sending_lib AS "aum_sending_lib",
    aum.usr AS "usr",
    NULL::INT as "ausp_usr",
    aum.usr as "aum_usr",
    NULL::INT AS "standing_penalty",
    NULL::INT AS "staff",
    aum.create_date AS "create_date",
    NULL::TIMESTAMPTZ AS "ausp_set_date",
    aum.create_date AS "aum_create_date",
    aum.stop_date AS "stop_date",
    NULL::TIMESTAMPTZ AS "ausp_stop_date",
    aum.stop_date AS "aum_stop_date",
    NULL::INT AS "ausp_usr_message",
    aum.title AS "title",
    aum.message AS "message",
    aum.deleted AS "deleted",
    aum.read_date AS "read_date",
    aum.pub AS "pub",
    aum.editor AS "editor",
    aum.edit_date AS "edit_date"
FROM
    actor.usr_message aum
    LEFT JOIN actor.usr_standing_penalty ausp ON (ausp.usr_message = aum.id)
WHERE NOT aum.deleted AND ausp.id IS NULL
;

-- fun part where we migrate the following alert messages:

CREATE TABLE actor.XXXX_note_and_message_consolidation AS
    SELECT id, home_ou, alert_message
    FROM actor.usr
    WHERE NOT deleted AND NULLIF(BTRIM(alert_message),'') IS NOT NULL;

-- here is our staging table which will be shaped exactly like
-- actor.usr_message and use the same id sequence
CREATE TABLE actor.XXXX_usr_message (
    LIKE actor.usr_message INCLUDING DEFAULTS 
);

INSERT INTO actor.XXXX_usr_message (
    usr,
    title,
    message,
    create_date,
    sending_lib,
    pub
) SELECT
    id,
    'converted Alert Message, real date unknown',
    alert_message,
    NOW(), -- best we can do
    1, -- it's this or home_ou
    FALSE
FROM
    actor.XXXX_note_and_message_consolidation
;

-- another staging table, but for actor.usr_standing_penalty
CREATE TABLE actor.XXXX_usr_standing_penalty (
    LIKE actor.usr_standing_penalty INCLUDING DEFAULTS 
);

INSERT INTO actor.XXXX_usr_standing_penalty (
    org_unit,
    usr,
    standing_penalty,
    staff,
    set_date,
    usr_message
) SELECT
    sending_lib,
    usr,
    20, -- ALERT_NOTE
    1, -- admin user, usually; best we can do
    create_date,
    id
FROM
    actor.XXXX_usr_message
;

-- so far so good, let's push these into production

INSERT INTO actor.usr_message
    SELECT * FROM actor.XXXX_usr_message;
INSERT INTO actor.usr_standing_penalty
    SELECT * FROM actor.XXXX_usr_standing_penalty;

-- probably redundant here, but the spec calls for an assertion before removing
-- the alert message column from actor.usr, so being extra cautious:
/*
do $$ begin
    assert (
        select count(*)
        from actor.XXXX_usr_message
        where id not in (
            select id from actor.usr_message
        )
    ) = 0, 'failed migrating to actor.usr_message';
end; $$;

do $$ begin
    assert (
        select count(*)
        from actor.XXXX_usr_standing_penalty
        where id not in (
            select id from actor.usr_standing_penalty
        )
    ) = 0, 'failed migrating to actor.usr_standing_penalty';
end; $$;
*/

-- WARNING: we're going to lose the history of alert_message
ALTER TABLE actor.usr DROP COLUMN alert_message CASCADE;
SELECT auditor.update_auditors();

-- fun part where we migrate actor.usr_notes as penalties to preserve
-- their creator, and then the private ones to private user messages.
-- For public notes, we try to link to existing user messages if we
-- can, but if we can't, we'll create new, but archived, user messages
-- for the note contents.

CREATE TABLE actor.XXXX_usr_message_for_private_notes (
    LIKE actor.usr_message INCLUDING DEFAULTS 
);
ALTER TABLE actor.XXXX_usr_message_for_private_notes ADD COLUMN orig_id BIGINT;
CREATE INDEX ON actor.XXXX_usr_message_for_private_notes (orig_id);

INSERT INTO actor.XXXX_usr_message_for_private_notes (
    orig_id,
    usr,
    title,
    message,
    create_date,
    sending_lib,
    pub
) SELECT
    id,
    usr,
    title,
    value,
    create_date,
    (select home_ou from actor.usr where id = creator), -- best we can do
    FALSE
FROM
    actor.usr_note
WHERE
    NOT pub
;

CREATE TABLE actor.XXXX_usr_message_for_unmatched_public_notes (
    LIKE actor.usr_message INCLUDING DEFAULTS 
);
ALTER TABLE actor.XXXX_usr_message_for_unmatched_public_notes ADD COLUMN orig_id BIGINT;
CREATE INDEX ON actor.XXXX_usr_message_for_unmatched_public_notes (orig_id);

INSERT INTO actor.XXXX_usr_message_for_unmatched_public_notes (
    orig_id,
    usr,
    title,
    message,
    create_date,
    deleted,
    sending_lib,
    pub
) SELECT
    id,
    usr,
    title,
    value,
    create_date,
    TRUE, -- the patron has likely already seen and deleted the corresponding usr_message
    (select home_ou from actor.usr where id = creator), -- best we can do
    FALSE
FROM
    actor.usr_note n
WHERE
    pub AND NOT EXISTS (SELECT 1 FROM actor.usr_message m WHERE n.usr = m.usr AND n.create_date = m.create_date)
;

-- now, in order to preserve the creator from usr_note, we want to create standing SILENT_NOTE penalties for
--  1) actor.XXXX_usr_message_for_private_notes and associated usr_note entries
--  2) actor.XXXX_usr_message_for_unmatched_public_notes and associated usr_note entries, but archive these
--  3) usr_note and usr_message entries that can be matched

CREATE TABLE actor.XXXX_usr_standing_penalties_for_notes (
    LIKE actor.usr_standing_penalty INCLUDING DEFAULTS 
);

--  1) actor.XXXX_usr_message_for_private_notes and associated usr_note entries
INSERT INTO actor.XXXX_usr_standing_penalties_for_notes (
    org_unit,
    usr,
    standing_penalty,
    staff,
    set_date,
    stop_date,
    usr_message
) SELECT
    m.sending_lib,
    m.usr,
    21, -- SILENT_NOTE
    n.creator,
    m.create_date,
    m.stop_date,
    m.id
FROM
    actor.usr_note n,
    actor.XXXX_usr_message_for_private_notes m
WHERE
    n.usr = m.usr AND n.id = m.orig_id AND NOT n.pub AND NOT m.pub
;

--  2) actor.XXXX_usr_message_for_unmatched_public_notes and associated usr_note entries, but archive these
INSERT INTO actor.XXXX_usr_standing_penalties_for_notes (
    org_unit,
    usr,
    standing_penalty,
    staff,
    set_date,
    stop_date,
    usr_message
) SELECT
    m.sending_lib,
    m.usr,
    21, -- SILENT_NOTE
    n.creator,
    m.create_date,
    m.stop_date,
    m.id
FROM
    actor.usr_note n,
    actor.XXXX_usr_message_for_unmatched_public_notes m
WHERE
    n.usr = m.usr AND n.id = m.orig_id AND n.pub AND m.pub
;

--  3) usr_note and usr_message entries that can be matched
INSERT INTO actor.XXXX_usr_standing_penalties_for_notes (
    org_unit,
    usr,
    standing_penalty,
    staff,
    set_date,
    stop_date,
    usr_message
) SELECT
    m.sending_lib,
    m.usr,
    21, -- SILENT_NOTE
    n.creator,
    m.create_date,
    m.stop_date,
    m.id
FROM
    actor.usr_note n
    JOIN actor.usr_message m ON (n.usr = m.usr AND n.id = m.id)
WHERE
    NOT EXISTS ( SELECT 1 FROM actor.XXXX_usr_message_for_private_notes WHERE id = m.id )
    AND NOT EXISTS ( SELECT 1 FROM actor.XXXX_usr_message_for_unmatched_public_notes WHERE id = m.id )
;

-- so far so good, let's push these into production

INSERT INTO actor.usr_message
    SELECT id, usr, title, message, create_date, deleted, read_date, sending_lib, pub, stop_date, editor, edit_date FROM actor.XXXX_usr_message_for_private_notes
    UNION SELECT id, usr, title, message, create_date, deleted, read_date, sending_lib, pub, stop_date, editor, edit_date FROM actor.XXXX_usr_message_for_unmatched_public_notes;
INSERT INTO actor.usr_standing_penalty
    SELECT * FROM actor.XXXX_usr_standing_penalties_for_notes;

-- probably redundant here, but the spec calls for an assertion before dropping
-- the actor.usr_note table, so being extra cautious:
/*
do $$ begin
    assert (
        select count(*)
        from actor.XXXX_usr_message_for_private_notes
        where id not in (
            select id from actor.usr_message
        )
    ) = 0, 'failed migrating to actor.usr_message';
end; $$;
*/

DROP TABLE actor.usr_note CASCADE;

-- preserve would-be collisions for migrating
-- ui.staff.require_initials.patron_info_notes
-- to ui.staff.require_initials.patron_standing_penalty

\o ui.staff.require_initials.patron_info_notes.collisions.txt
SELECT a.*
FROM actor.org_unit_setting a
WHERE
        a.name = 'ui.staff.require_initials.patron_info_notes'
    -- hits on org_unit
    AND a.org_unit IN (
        SELECT b.org_unit
        FROM actor.org_unit_setting b
        WHERE b.name = 'ui.staff.require_initials.patron_standing_penalty'
    )
    -- but doesn't hit on org_unit + value
    AND CONCAT_WS('|',a.org_unit::TEXT,a.value::TEXT) NOT IN (
        SELECT CONCAT_WS('|',b.org_unit::TEXT,b.value::TEXT)
        FROM actor.org_unit_setting b
        WHERE b.name = 'ui.staff.require_initials.patron_standing_penalty'
    );
\o

-- and preserve the _log data

\o ui.staff.require_initials.patron_info_notes.log_data.txt
SELECT *
FROM config.org_unit_setting_type_log
WHERE field_name = 'ui.staff.require_initials.patron_info_notes';
\o

-- migrate the non-collisions

INSERT INTO actor.org_unit_setting (org_unit, name, value)
SELECT a.org_unit, 'ui.staff.require_initials.patron_standing_penalty', a.value
FROM actor.org_unit_setting a
WHERE
        a.name = 'ui.staff.require_initials.patron_info_notes'
    AND a.org_unit NOT IN (
        SELECT b.org_unit
        FROM actor.org_unit_setting b
        WHERE b.name = 'ui.staff.require_initials.patron_standing_penalty'
    )
;

-- and now delete the old patron_info_notes settings

DELETE FROM actor.org_unit_setting
    WHERE name = 'ui.staff.require_initials.patron_info_notes';
DELETE FROM config.org_unit_setting_type_log
    WHERE field_name = 'ui.staff.require_initials.patron_info_notes';
DELETE FROM config.org_unit_setting_type
    WHERE name = 'ui.staff.require_initials.patron_info_notes';

-- relabel the org unit setting type

UPDATE config.org_unit_setting_type
SET
    label = oils_i18n_gettext('ui.staff.require_initials.patron_standing_penalty',
        'Require staff initials for entry/edit of patron standing penalties and notes.',
        'coust', 'label'),
    description = oils_i18n_gettext('ui.staff.require_initials.patron_standing_penalty',
        'Require staff initials for entry/edit of patron standing penalties and notes.',
        'coust', 'description')
WHERE
    name = 'ui.staff.require_initials.patron_standing_penalty'
;

-- preserve _log data for some different settings on their way out

\o ui.patron.edit.au.alert_message.show_suggest.log_data.txt
SELECT *
FROM config.org_unit_setting_type_log
WHERE field_name IN (
    'ui.patron.edit.au.alert_message.show',
    'ui.patron.edit.au.alert_message.suggest'
);
\o

-- remove patron editor alert message settings

DELETE FROM actor.org_unit_setting
    WHERE name = 'ui.patron.edit.au.alert_message.show';
DELETE FROM config.org_unit_setting_type_log
    WHERE field_name = 'ui.patron.edit.au.alert_message.show';
DELETE FROM config.org_unit_setting_type
    WHERE name = 'ui.patron.edit.au.alert_message.show';

DELETE FROM actor.org_unit_setting
    WHERE name = 'ui.patron.edit.au.alert_message.suggest';
DELETE FROM config.org_unit_setting_type_log
    WHERE field_name = 'ui.patron.edit.au.alert_message.suggest';
DELETE FROM config.org_unit_setting_type
    WHERE name = 'ui.patron.edit.au.alert_message.suggest';

-- comment these out if you want the staging tables to stick around
DROP TABLE actor.XXXX_note_and_message_consolidation;
DROP TABLE actor.XXXX_penalty_notes;
DROP TABLE actor.XXXX_usr_message_for_penalty_notes;
DROP TABLE actor.XXXX_usr_message;
DROP TABLE actor.XXXX_usr_standing_penalty;
DROP TABLE actor.XXXX_usr_message_for_private_notes;
DROP TABLE actor.XXXX_usr_message_for_unmatched_public_notes;
DROP TABLE actor.XXXX_usr_standing_penalties_for_notes;



SELECT evergreen.upgrade_deps_block_check('1289', :eg_version);


ALTER TABLE biblio.record_note ADD COLUMN deleted BOOLEAN DEFAULT FALSE;

INSERT INTO permission.perm_list ( id, code, description ) VALUES
( 633, 'CREATE_RECORD_NOTE', oils_i18n_gettext(633,
   'Allow the user to create a record note', 'ppl', 'description')),
( 634, 'UPDATE_RECORD_NOTE', oils_i18n_gettext(634,
   'Allow the user to update a record note', 'ppl', 'description')),
( 635, 'DELETE_RECORD_NOTE', oils_i18n_gettext(635,
   'Allow the user to delete a record note', 'ppl', 'description'));

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.catalog.record.notes', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.catalog.record.notes',
        'Grid Config: eg.grid.catalog.record.notes',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1290', :eg_version);

-- Add an active flag column

ALTER TABLE acq.funding_source ADD COLUMN active BOOL;

UPDATE acq.funding_source SET active = 't';

ALTER TABLE acq.funding_source ALTER COLUMN active SET DEFAULT TRUE;
ALTER TABLE acq.funding_source ALTER COLUMN active SET NOT NULL;


SELECT evergreen.upgrade_deps_block_check('1291', :eg_version);

--    context_usr_path        TEXT, -- for optimizing action_trigger.event
--    context_library_path    TEXT, -- '''
--    context_bib_path        TEXT, -- '''
ALTER TABLE action_trigger.event_definition ADD COLUMN context_usr_path TEXT;
ALTER TABLE action_trigger.event_definition ADD COLUMN context_library_path TEXT;
ALTER TABLE action_trigger.event_definition ADD COLUMN context_bib_path TEXT;

--    context_user    INT         REFERENCES actor.usr (id),
--    context_library INT         REFERENCES actor.org_unit (id),
--    context_bib     BIGINT      REFERENCES biblio.record_entry (id)
ALTER TABLE action_trigger.event ADD COLUMN context_user INT REFERENCES actor.usr (id);
ALTER TABLE action_trigger.event ADD COLUMN context_library INT REFERENCES actor.org_unit (id);
ALTER TABLE action_trigger.event ADD COLUMN context_bib BIGINT REFERENCES biblio.record_entry (id);
CREATE INDEX atev_context_user ON action_trigger.event (context_user);
CREATE INDEX atev_context_library ON action_trigger.event (context_library);

UPDATE
    action_trigger.event_definition
SET
    context_usr_path = 'usr',
    context_library_path = 'circ_lib',
    context_bib_path = 'target_copy.call_number.record'
WHERE
    hook IN (
        SELECT key FROM action_trigger.hook WHERE core_type = 'circ'
    )
;

UPDATE
    action_trigger.event_definition
SET
    context_usr_path = 'usr',
    context_library_path = 'pickup_lib',
    context_bib_path = 'bib_rec'
WHERE
    hook IN (
        SELECT key FROM action_trigger.hook WHERE core_type = 'ahr'
    )
;

-- Retroactively setting context_user and context_library on existing rows in action_trigger.event:
-- This is not done by default because it'll likely take a long time depending on the Evergreen
-- installation.  You may want to do this out-of-band with the upgrade if you want to do this at all.
--
-- \pset format unaligned
-- \t
-- \o update_action_trigger_events_for_circs.sql
-- SELECT 'UPDATE action_trigger.event e SET context_user = c.usr, context_library = c.circ_lib, context_bib = cn.record FROM action.circulation c, asset.copy i, asset.call_number cn WHERE c.id = e.target AND c.target_copy = i.id AND i.call_number = cn.id AND e.id = ' || e.id || ' RETURNING ' || e.id || ';' FROM action_trigger.event e, action.circulation c WHERE e.target = c.id AND e.event_def IN (SELECT id FROM action_trigger.event_definition WHERE hook in (SELECT key FROM action_trigger.hook WHERE core_type = 'circ')) ORDER BY e.id DESC;
-- \o
-- \o update_action_trigger_events_for_holds.sql
-- SELECT 'UPDATE action_trigger.event e SET context_user = h.usr, context_library = h.pickup_lib, context_bib = r.bib_record FROM action.hold_request h, reporter.hold_request_record r WHERE h.id = e.target AND h.id = r.id AND e.id = ' || e.id || ' RETURNING ' || e.id || ';' FROM action_trigger.event e, action.hold_request h WHERE e.target = h.id AND e.event_def IN (SELECT id FROM action_trigger.event_definition WHERE hook in (SELECT key FROM action_trigger.hook WHERE core_type = 'ahr')) ORDER BY e.id DESC;
-- \o



SELECT evergreen.upgrade_deps_block_check('1292', :eg_version);

CREATE OR REPLACE FUNCTION action.age_circ_on_delete () RETURNS TRIGGER AS $$
DECLARE
found char := 'N';
BEGIN

    -- If there are any renewals for this circulation, don't archive or delete
    -- it yet.   We'll do so later, when we archive and delete the renewals.

    SELECT 'Y' INTO found
    FROM action.circulation
    WHERE parent_circ = OLD.id
    LIMIT 1;

    IF found = 'Y' THEN
        RETURN NULL;  -- don't delete
	END IF;

    -- Archive a copy of the old row to action.aged_circulation

    INSERT INTO action.aged_circulation
        (id,usr_post_code, usr_home_ou, usr_profile, usr_birth_year, copy_call_number, copy_location,
        copy_owning_lib, copy_circ_lib, copy_bib_record, xact_start, xact_finish, target_copy,
        circ_lib, circ_staff, checkin_staff, checkin_lib, renewal_remaining, grace_period, due_date,
        stop_fines_time, checkin_time, create_time, duration, fine_interval, recurring_fine,
        max_fine, phone_renewal, desk_renewal, opac_renewal, duration_rule, recurring_fine_rule,
        max_fine_rule, stop_fines, workstation, checkin_workstation, checkin_scan_time, parent_circ,
        auto_renewal, auto_renewal_remaining)
      SELECT
        id,usr_post_code, usr_home_ou, usr_profile, usr_birth_year, copy_call_number, copy_location,
        copy_owning_lib, copy_circ_lib, copy_bib_record, xact_start, xact_finish, target_copy,
        circ_lib, circ_staff, checkin_staff, checkin_lib, renewal_remaining, grace_period, due_date,
        stop_fines_time, checkin_time, create_time, duration, fine_interval, recurring_fine,
        max_fine, phone_renewal, desk_renewal, opac_renewal, duration_rule, recurring_fine_rule,
        max_fine_rule, stop_fines, workstation, checkin_workstation, checkin_scan_time, parent_circ,
        auto_renewal, auto_renewal_remaining
        FROM action.all_circulation WHERE id = OLD.id;

    -- Migrate billings and payments to aged tables

    SELECT 'Y' INTO found FROM config.global_flag 
        WHERE name = 'history.money.age_with_circs' AND enabled;

    IF found = 'Y' THEN
        PERFORM money.age_billings_and_payments_for_xact(OLD.id);
    END IF;

    -- Break the link with the user in action_trigger.event (warning: event_output may essentially have this information)
    UPDATE
        action_trigger.event e
    SET
        context_user = NULL
    FROM
        action.all_circulation c
    WHERE
            c.id = OLD.id
        AND e.context_user = c.usr
        AND e.target = c.id
        AND e.event_def IN (
            SELECT id
            FROM action_trigger.event_definition
            WHERE hook in (SELECT key FROM action_trigger.hook WHERE core_type = 'circ')
        )
    ;

    RETURN OLD;
END;
$$ LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION actor.usr_purge_data(
	src_usr  IN INTEGER,
	specified_dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	renamable_row RECORD;
	dest_usr INTEGER;
BEGIN

	IF specified_dest_usr IS NULL THEN
		dest_usr := 1; -- Admin user on stock installs
	ELSE
		dest_usr := specified_dest_usr;
	END IF;

    -- action_trigger.event (even doing this, event_output may--and probably does--contain PII and should have a retention/removal policy)
    UPDATE action_trigger.event SET context_user = dest_usr WHERE context_user = src_usr;

	-- acq.*
	UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.lineitem SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.lineitem SET selector = dest_usr WHERE selector = src_usr;
	UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;
	DELETE FROM acq.lineitem_usr_attr_definition WHERE usr = src_usr;

	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE acq.picklist SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.picklist SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
	UPDATE acq.purchase_order SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.purchase_order SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.claim_event SET creator = dest_usr WHERE creator = src_usr;

	-- action.*
	DELETE FROM action.circulation WHERE usr = src_usr;
	UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
	UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
	UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;
	UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
	UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
	DELETE FROM action.hold_request WHERE usr = src_usr;
	UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
	UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.non_cataloged_circulation WHERE patron = src_usr;
	UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.survey_response WHERE usr = src_usr;
	UPDATE action.fieldset SET owner = dest_usr WHERE owner = src_usr;
	DELETE FROM action.usr_circ_history WHERE usr = src_usr;

	-- actor.*
	DELETE FROM actor.card WHERE usr = src_usr;
	DELETE FROM actor.stat_cat_entry_usr_map WHERE target_usr = src_usr;
	DELETE FROM actor.usr_privacy_waiver WHERE usr = src_usr;

	-- The following update is intended to avoid transient violations of a foreign
	-- key constraint, whereby actor.usr_address references itself.  It may not be
	-- necessary, but it does no harm.
	UPDATE actor.usr_address SET replaces = NULL
		WHERE usr = src_usr AND replaces IS NOT NULL;
	DELETE FROM actor.usr_address WHERE usr = src_usr;
	DELETE FROM actor.usr_note WHERE usr = src_usr;
	UPDATE actor.usr_note SET creator = dest_usr WHERE creator = src_usr;
	DELETE FROM actor.usr_org_unit_opt_in WHERE usr = src_usr;
	UPDATE actor.usr_org_unit_opt_in SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM actor.usr_setting WHERE usr = src_usr;
	DELETE FROM actor.usr_standing_penalty WHERE usr = src_usr;
	UPDATE actor.usr_standing_penalty SET staff = dest_usr WHERE staff = src_usr;

	-- asset.*
	UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;

	-- auditor.*
	DELETE FROM auditor.actor_usr_address_history WHERE id = src_usr;
	DELETE FROM auditor.actor_usr_history WHERE id = src_usr;
	UPDATE auditor.asset_call_number_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_call_number_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.asset_copy_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_copy_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.biblio_record_entry_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.biblio_record_entry_history SET editor  = dest_usr WHERE editor  = src_usr;

	-- biblio.*
	UPDATE biblio.record_entry SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_entry SET editor = dest_usr WHERE editor = src_usr;
	UPDATE biblio.record_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_note SET editor = dest_usr WHERE editor = src_usr;

	-- container.*
	-- Update buckets with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	DELETE FROM container.user_bucket_item WHERE target_user = src_usr;

	-- money.*
	DELETE FROM money.billable_xact WHERE usr = src_usr;
	DELETE FROM money.collections_tracker WHERE usr = src_usr;
	UPDATE money.collections_tracker SET collector = dest_usr WHERE collector = src_usr;

	-- permission.*
	DELETE FROM permission.usr_grp_map WHERE usr = src_usr;
	DELETE FROM permission.usr_object_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_work_ou_map WHERE usr = src_usr;

	-- reporter.*
	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
	-- do nothing
	END;

	-- vandelay.*
	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- NULL-ify addresses last so other cleanup (e.g. circ anonymization)
    -- can access the information before deletion.
	UPDATE actor.usr SET
		active = FALSE,
		card = NULL,
		mailing_address = NULL,
		billing_address = NULL
	WHERE id = src_usr;

END;
$$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1293', :eg_version);

INSERT INTO config.workstation_setting_type
    (name, grp, datatype, label)
VALUES (
    'eg.grid.item.event_grid', 'gui', 'object',
    oils_i18n_gettext(
    'eg.grid.item.event_grid',
    'Grid Config: item.event_grid',
    'cwst', 'label')
), (
    'eg.grid.patron.event_grid', 'gui', 'object',
    oils_i18n_gettext(
    'eg.grid.patron.event_grid',
    'Grid Config: patron.event_grid',
    'cwst', 'label')
);

DROP TRIGGER IF EXISTS action_trigger_event_context_item_trig ON action_trigger.event;

-- Create a NULLABLE version of the fake-copy-fkey trigger function.
CREATE OR REPLACE FUNCTION evergreen.fake_fkey_tgr () RETURNS TRIGGER AS $F$
DECLARE
    copy_id BIGINT;
BEGIN
    EXECUTE 'SELECT ($1).' || quote_ident(TG_ARGV[0]) INTO copy_id USING NEW;
    IF copy_id IS NOT NULL THEN
        PERFORM * FROM asset.copy WHERE id = copy_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Key (%.%=%) does not exist in asset.copy', TG_TABLE_SCHEMA, TG_TABLE_NAME, copy_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$F$ LANGUAGE PLPGSQL;


--    context_item_path        TEXT, -- for optimizing action_trigger.event
ALTER TABLE action_trigger.event_definition ADD COLUMN context_item_path TEXT;

--    context_item     BIGINT      REFERENCES asset.copy (id)
ALTER TABLE action_trigger.event ADD COLUMN context_item BIGINT;
CREATE INDEX atev_context_item ON action_trigger.event (context_item);

UPDATE
    action_trigger.event_definition
SET
    context_item_path = 'target_copy'
WHERE
    hook IN (
        SELECT key FROM action_trigger.hook WHERE core_type = 'circ'
    )
;

UPDATE
    action_trigger.event_definition
SET
    context_item_path = 'current_copy'
WHERE
    hook IN (
        SELECT key FROM action_trigger.hook WHERE core_type = 'ahr'
    )
;

-- Retroactively setting context_item on existing rows in action_trigger.event:
-- This is not done by default because it'll likely take a long time depending on the Evergreen
-- installation.  You may want to do this out-of-band with the upgrade if you want to do this at all.
--
-- \pset format unaligned
-- \t
-- \o update_action_trigger_events_for_circs.sql
-- SELECT 'UPDATE action_trigger.event e SET context_item = c.target_copy FROM action.circulation c WHERE c.id = e.target AND e.id = ' || e.id || ' RETURNING ' || e.id || ';' FROM action_trigger.event e, action.circulation c WHERE e.target = c.id AND e.event_def IN (SELECT id FROM action_trigger.event_definition WHERE hook in (SELECT key FROM action_trigger.hook WHERE core_type = 'circ')) ORDER BY e.id DESC;
-- \o
-- \o update_action_trigger_events_for_holds.sql
-- SELECT 'UPDATE action_trigger.event e SET context_item = h.current_copy FROM action.hold_request h WHERE h.id = e.target AND e.id = ' || e.id || ' RETURNING ' || e.id || ';' FROM action_trigger.event e, action.hold_request h WHERE e.target = h.id AND e.event_def IN (SELECT id FROM action_trigger.event_definition WHERE hook in (SELECT key FROM action_trigger.hook WHERE core_type = 'ahr')) ORDER BY e.id DESC;
-- \o


CREATE TRIGGER action_trigger_event_context_item_trig
  AFTER INSERT OR UPDATE ON action_trigger.event
  FOR EACH ROW EXECUTE PROCEDURE evergreen.fake_fkey_tgr('context_item');


SELECT evergreen.upgrade_deps_block_check('1295', :eg_version);

ALTER TABLE vandelay.merge_profile
    ADD COLUMN update_bib_editor BOOLEAN NOT NULL DEFAULT FALSE;

-- By default, updating bib source means updating the editor.
UPDATE vandelay.merge_profile SET update_bib_editor = update_bib_source;

CREATE OR REPLACE FUNCTION vandelay.overlay_bib_record 
    ( import_id BIGINT, eg_id BIGINT, merge_profile_id INT ) RETURNS BOOL AS $$
DECLARE
    editor_string   TEXT;
    editor_id       INT;
    v_marc          TEXT;
    v_bib_source    INT;
    update_fields   TEXT[];
    update_query    TEXT;
    update_bib_source BOOL;
    update_bib_editor BOOL;
BEGIN

    SELECT  q.marc, q.bib_source INTO v_marc, v_bib_source
      FROM  vandelay.queued_bib_record q
            JOIN vandelay.bib_match m ON (m.queued_record = q.id AND q.id = import_id)
      LIMIT 1;

    IF v_marc IS NULL THEN
        -- RAISE NOTICE 'no marc for vandelay or bib record';
        RETURN FALSE;
    END IF;

    IF NOT vandelay.template_overlay_bib_record( v_marc, eg_id, merge_profile_id) THEN
        -- no update happened, get outta here.
        RETURN FALSE;
    END IF;

    UPDATE  vandelay.queued_bib_record
      SET   imported_as = eg_id,
            import_time = NOW()
      WHERE id = import_id;

    SELECT q.update_bib_source INTO update_bib_source 
        FROM vandelay.merge_profile q where q.id = merge_profile_Id;

    IF update_bib_source AND v_bib_source IS NOT NULL THEN
        update_fields := ARRAY_APPEND(update_fields, 'source = ' || v_bib_source);
    END IF;

    SELECT q.update_bib_editor INTO update_bib_editor 
        FROM vandelay.merge_profile q where q.id = merge_profile_Id;

    IF update_bib_editor THEN

        editor_string := (oils_xpath('//*[@tag="905"]/*[@code="u"]/text()',v_marc))[1];

        IF editor_string IS NOT NULL AND editor_string <> '' THEN
            SELECT usr INTO editor_id FROM actor.card WHERE barcode = editor_string;

            IF editor_id IS NULL THEN
                SELECT id INTO editor_id FROM actor.usr WHERE usrname = editor_string;
            END IF;

            IF editor_id IS NOT NULL THEN
                --only update the edit date if we have a valid editor
                update_fields := ARRAY_APPEND(
                    update_fields, 'editor = ' || editor_id || ', edit_date = NOW()');
            END IF;
        END IF;
    END IF;

    IF ARRAY_LENGTH(update_fields, 1) > 0 THEN
        update_query := 'UPDATE biblio.record_entry SET ' || 
            ARRAY_TO_STRING(update_fields, ',') || ' WHERE id = ' || eg_id || ';';
        EXECUTE update_query;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE PLPGSQL;



SELECT evergreen.upgrade_deps_block_check('1296', :eg_version);

CREATE OR REPLACE VIEW reporter.demographic AS
SELECT  u.id,
    u.dob,
    CASE
        WHEN u.dob IS NULL
            THEN 'Adult'
        WHEN AGE(u.dob) > '18 years'::INTERVAL
            THEN 'Adult'
        ELSE 'Juvenile'
    END AS general_division,
    CASE
        WHEN u.dob IS NULL
            THEN 'No Date of Birth Entered'::text
        WHEN age(u.dob::timestamp with time zone) >= '0 years'::interval and age(u.dob::timestamp with time zone) < '6 years'::interval
            THEN 'Child 0-5 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '6 years'::interval and age(u.dob::timestamp with time zone) < '13 years'::interval
            THEN 'Child 6-12 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '13 years'::interval and age(u.dob::timestamp with time zone) < '18 years'::interval
            THEN 'Teen 13-17 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '18 years'::interval and age(u.dob::timestamp with time zone) < '26 years'::interval
            THEN 'Adult 18-25 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '26 years'::interval and age(u.dob::timestamp with time zone) < '50 years'::interval
            THEN 'Adult 26-49 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '50 years'::interval and age(u.dob::timestamp with time zone) < '60 years'::interval
            THEN 'Adult 50-59 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '60 years'::interval and age(u.dob::timestamp with time zone) < '70  years'::interval
            THEN 'Adult 60-69 Years Old'::text
        WHEN age(u.dob::timestamp with time zone) >= '70 years'::interval
            THEN 'Adult 70+'::text
        ELSE NULL::text
    END AS age_division
    FROM actor.usr u;


SELECT evergreen.upgrade_deps_block_check('1297', :eg_version);

INSERT INTO config.org_unit_setting_type (
    name, grp, label, description, datatype
) VALUES (
    'circ.staff_placed_holds_default_to_ws_ou',
    'circ',
    oils_i18n_gettext(
        'circ.staff_placed_holds_default_to_ws_ou',
        'Workstation OU is the default for staff-placed holds',
        'coust',
        'label'
    ),
    oils_i18n_gettext(
        'circ.staff_placed_holds_default_to_ws_ou',
        'For staff-placed holds, regardless of the patron preferred pickup location, the staff workstation OU is the default pickup location',
        'coust',
        'description'
    ),
    'bool'
);


SELECT evergreen.upgrade_deps_block_check('1298', :eg_version);

ALTER TYPE metabib.field_entry_template ADD ATTRIBUTE browse_nocase BOOL CASCADE;

ALTER TABLE config.metabib_field ADD COLUMN browse_nocase BOOL NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION biblio.extract_metabib_field_entry (
    rid BIGINT,
    default_joiner TEXT,
    field_types TEXT[],
    only_fields INT[]
) RETURNS SETOF metabib.field_entry_template AS $func$
DECLARE
    bib     biblio.record_entry%ROWTYPE;
    idx     config.metabib_field%ROWTYPE;
    xfrm        config.xml_transform%ROWTYPE;
    prev_xfrm   TEXT;
    transformed_xml TEXT;
    xml_node    TEXT;
    xml_node_list   TEXT[];
    facet_text  TEXT;
    display_text TEXT;
    browse_text TEXT;
    sort_value  TEXT;
    raw_text    TEXT;
    curr_text   TEXT;
    joiner      TEXT := default_joiner; -- XXX will index defs supply a joiner?
    authority_text TEXT;
    authority_link BIGINT;
    output_row  metabib.field_entry_template%ROWTYPE;
    process_idx BOOL;
BEGIN

    -- Start out with no field-use bools set
    output_row.browse_nocase = FALSE;
    output_row.browse_field = FALSE;
    output_row.facet_field = FALSE;
    output_row.display_field = FALSE;
    output_row.search_field = FALSE;

    -- Get the record
    SELECT INTO bib * FROM biblio.record_entry WHERE id = rid;

    -- Loop over the indexing entries
    FOR idx IN SELECT * FROM config.metabib_field WHERE id = ANY (only_fields) ORDER BY format LOOP
        CONTINUE WHEN idx.xpath IS NULL OR idx.xpath = ''; -- pure virtual field

        process_idx := FALSE;
        IF idx.display_field AND 'display' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.browse_field AND 'browse' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.search_field AND 'search' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.facet_field AND 'facet' = ANY (field_types) THEN process_idx = TRUE; END IF;
        CONTINUE WHEN process_idx = FALSE; -- disabled for all types

        joiner := COALESCE(idx.joiner, default_joiner);

        SELECT INTO xfrm * from config.xml_transform WHERE name = idx.format;

        -- See if we can skip the XSLT ... it's expensive
        IF prev_xfrm IS NULL OR prev_xfrm <> xfrm.name THEN
            -- Can't skip the transform
            IF xfrm.xslt <> '---' THEN
                transformed_xml := oils_xslt_process(bib.marc,xfrm.xslt);
            ELSE
                transformed_xml := bib.marc;
            END IF;

            prev_xfrm := xfrm.name;
        END IF;

        xml_node_list := oils_xpath( idx.xpath, transformed_xml, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );

        raw_text := NULL;
        FOR xml_node IN SELECT x FROM unnest(xml_node_list) AS x LOOP
            CONTINUE WHEN xml_node !~ E'^\\s*<';

            -- XXX much of this should be moved into oils_xpath_string...
            curr_text := ARRAY_TO_STRING(evergreen.array_remove_item_by_value(evergreen.array_remove_item_by_value(
                oils_xpath( '//text()', -- get the content of all the nodes within the main selected node
                    REGEXP_REPLACE( xml_node, E'\\s+', ' ', 'g' ) -- Translate adjacent whitespace to a single space
                ), ' '), ''),  -- throw away morally empty (bankrupt?) strings
                joiner
            );

            CONTINUE WHEN curr_text IS NULL OR curr_text = '';

            IF raw_text IS NOT NULL THEN
                raw_text := raw_text || joiner;
            END IF;

            raw_text := COALESCE(raw_text,'') || curr_text;

            -- autosuggest/metabib.browse_entry
            IF idx.browse_field THEN
                output_row.browse_nocase = idx.browse_nocase;

                IF idx.browse_xpath IS NOT NULL AND idx.browse_xpath <> '' THEN
                    browse_text := oils_xpath_string( idx.browse_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    browse_text := curr_text;
                END IF;

                IF idx.browse_sort_xpath IS NOT NULL AND
                    idx.browse_sort_xpath <> '' THEN

                    sort_value := oils_xpath_string(
                        idx.browse_sort_xpath, xml_node, joiner,
                        ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]]
                    );
                ELSE
                    sort_value := browse_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(browse_text, E'\\s+', ' ', 'g'));
                output_row.sort_value :=
                    public.naco_normalize(sort_value);

                output_row.authority := NULL;

                IF idx.authority_xpath IS NOT NULL AND idx.authority_xpath <> '' THEN
                    authority_text := oils_xpath_string(
                        idx.authority_xpath, xml_node, joiner,
                        ARRAY[
                            ARRAY[xfrm.prefix, xfrm.namespace_uri],
                            ARRAY['xlink','http://www.w3.org/1999/xlink']
                        ]
                    );

                    IF authority_text ~ '^\d+$' THEN
                        authority_link := authority_text::BIGINT;
                        PERFORM * FROM authority.record_entry WHERE id = authority_link;
                        IF FOUND THEN
                            output_row.authority := authority_link;
                        END IF;
                    END IF;

                END IF;

                output_row.browse_field = TRUE;
                -- Returning browse rows with search_field = true for search+browse
                -- configs allows us to retain granularity of being able to search
                -- browse fields with "starts with" type operators (for example, for
                -- titles of songs in music albums)
                IF idx.search_field THEN
                    output_row.search_field = TRUE;
                END IF;
                RETURN NEXT output_row;
                output_row.browse_nocase = FALSE;
                output_row.browse_field = FALSE;
                output_row.search_field = FALSE;
                output_row.sort_value := NULL;
            END IF;

            -- insert raw node text for faceting
            IF idx.facet_field THEN

                IF idx.facet_xpath IS NOT NULL AND idx.facet_xpath <> '' THEN
                    facet_text := oils_xpath_string( idx.facet_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    facet_text := curr_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = -1 * idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(facet_text, E'\\s+', ' ', 'g'));

                output_row.facet_field = TRUE;
                RETURN NEXT output_row;
                output_row.facet_field = FALSE;
            END IF;

            -- insert raw node text for display
            IF idx.display_field THEN

                IF idx.display_xpath IS NOT NULL AND idx.display_xpath <> '' THEN
                    display_text := oils_xpath_string( idx.display_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    display_text := curr_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = -1 * idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(display_text, E'\\s+', ' ', 'g'));

                output_row.display_field = TRUE;
                RETURN NEXT output_row;
                output_row.display_field = FALSE;
            END IF;

        END LOOP;

        CONTINUE WHEN raw_text IS NULL OR raw_text = '';

        -- insert combined node text for searching
        IF idx.search_field THEN
            output_row.field_class = idx.field_class;
            output_row.field = idx.id;
            output_row.source = rid;
            output_row.value = BTRIM(REGEXP_REPLACE(raw_text, E'\\s+', ' ', 'g'));

            output_row.search_field = TRUE;
            RETURN NEXT output_row;
            output_row.search_field = FALSE;
        END IF;

    END LOOP;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries( 
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE, 
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE, 
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                -- RAISE NOTICE 'Emptying out %', fclass.name;
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id;
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

	-- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN
            -- A caveat about this SELECT: this should take care of replacing
            -- old mbe rows when data changes, but not if normalization (by
            -- which I mean specifically the output of
            -- evergreen.oils_tsearch2()) changes.  It may or may not be
            -- expensive to add a comparison of index_vector to index_vector
            -- to the WHERE clause below.

            CONTINUE WHEN ind_data.sort_value IS NULL;

            value_prepped := metabib.browse_normalize(ind_data.value, ind_data.field);
            IF ind_data.browse_nocase THEN
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE evergreen.lowercase(value) = evergreen.lowercase(value_prepped) AND sort_value = ind_data.sort_value
                    ORDER BY sort_value, value LIMIT 1; -- gotta pick something, I guess
            ELSE
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE value = value_prepped AND sort_value = ind_data.sort_value;
            END IF;

            IF FOUND THEN
                mbe_id := mbe_row.id;
            ELSE
                INSERT INTO metabib.browse_entry
                    ( value, sort_value ) VALUES
                    ( value_prepped, ind_data.sort_value );

                mbe_id := CURRVAL('metabib.browse_entry_id_seq'::REGCLASS);
            END IF;

            INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
                VALUES (mbe_id, ind_data.field, ind_data.source, ind_data.authority);
        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;



SELECT evergreen.upgrade_deps_block_check('1299', :eg_version);

CREATE OR REPLACE FUNCTION vandelay.strip_field(xml text, field text) RETURNS text AS $f$

    use MARC::Record;
    use MARC::File::XML (BinaryEncoding => 'UTF-8');
    use MARC::Charset;
    use strict;

    MARC::Charset->assume_unicode(1);

    my $xml = shift;
    my $r = MARC::Record->new_from_xml( $xml );

    return $xml unless ($r);

    my $field_spec = shift;
    my @field_list = split(',', $field_spec);

    my %fields;
    for my $f (@field_list) {
        $f =~ s/^\s*//; $f =~ s/\s*$//;
        if ($f =~ /^(.{3})(\w*)(?:\[([^]]*)\])?$/) {
            my $field = $1;
            $field =~ s/\s+//;
            my $sf = $2;
            $sf =~ s/\s+//;
            my $matches = $3;
            $matches =~ s/^\s*//; $matches =~ s/\s*$//;
            $fields{$field} = { sf => [ split('', $sf) ] };
            if ($matches) {
                for my $match (split('&&', $matches)) {
                    $match =~ s/^\s*//; $match =~ s/\s*$//;
                    my ($msf,$mre) = split('~', $match);
                    if (length($msf) > 0 and length($mre) > 0) {
                        $msf =~ s/^\s*//; $msf =~ s/\s*$//;
                        $mre =~ s/^\s*//; $mre =~ s/\s*$//;
                        $fields{$field}{match}{$msf} = qr/$mre/;
                    }
                }
            }
        }
    }

    for my $f ( keys %fields) {
        for my $to_field ($r->field( $f )) {
            if (exists($fields{$f}{match})) {
                my @match_list = grep { $to_field->subfield($_) =~ $fields{$f}{match}{$_} } keys %{$fields{$f}{match}};
                next unless (scalar(@match_list) == scalar(keys %{$fields{$f}{match}}));
            }

            if ( @{$fields{$f}{sf}} ) {
                $to_field->delete_subfield(code => $fields{$f}{sf});
            } else {
                $r->delete_field( $to_field );
            }
        }
    }

    $xml = $r->as_xml_record;
    $xml =~ s/^<\?.+?\?>$//mo;
    $xml =~ s/\n//sgo;
    $xml =~ s/>\s+</></sgo;

    return $xml;

$f$ LANGUAGE plperlu;




SELECT evergreen.upgrade_deps_block_check('1300', :eg_version);

-- NOTE: If the template ID requires changing, beware it appears in
-- 3 places below.

INSERT INTO config.print_template 
    (id, name, locale, active, owner, label, template) 
VALUES (
    4, 'hold_pull_list', 'en-US', TRUE,
    (SELECT id FROM actor.org_unit WHERE parent_ou IS NULL),
    oils_i18n_gettext(4, 'Hold Pull List ', 'cpt', 'label'),
    ''
);

UPDATE config.print_template SET template = 
$TEMPLATE$
[%-
    USE date;
    SET holds = template_data;
    # template_data is an arry of wide_hold hashes.
-%]
<div>
  <style>
    #holds-pull-list-table td { 
      padding: 5px; 
      border: 1px solid rgba(0,0,0,.05);
    }
  </style>
  <table id="holds-pull-list-table">
    <thead>
      <tr>
        <th>Type</th>
        <th>Title</th>
        <th>Author</th>
        <th>Shelf Location</th>
        <th>Call Number</th>
        <th>Barcode/Part</th>
      </tr>
    </thead>
    <tbody>
      [% FOR hold IN holds %]
      <tr>
        <td>[% hold.hold_type %]</td>
        <td style="width: 30%">[% hold.title %]</td>
        <td style="width: 25%">[% hold.author %]</td>
        <td>[% hold.acpl_name %]</td>
        <td>[% hold.cn_full_label %]</td>
        <td>[% hold.cp_barcode %][% IF hold.p_label %]/[% hold.p_label %][% END %]</td>
      </tr>
      [% END %]
    </tbody>
  </table>
</div>
$TEMPLATE$ WHERE id = 4;

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.circ.holds.pull_list', 'gui', 'object', 
    oils_i18n_gettext(
        'circ.holds.pull_list',
        'Hold Pull List Grid Settings',
        'cwst', 'label'
    )
), (
    'circ.holds.pull_list.prefetch', 'gui', 'bool', 
    oils_i18n_gettext(
        'circ.holds.pull_list.prefetch',
        'Hold Pull List Prefetch Preference',
        'cwst', 'label'
    )
);



SELECT evergreen.upgrade_deps_block_check('1301', :eg_version);

CREATE OR REPLACE FUNCTION biblio.extract_metabib_field_entry (
    rid BIGINT,
    default_joiner TEXT,
    field_types TEXT[],
    only_fields INT[]
) RETURNS SETOF metabib.field_entry_template AS $func$
DECLARE
    bib     biblio.record_entry%ROWTYPE;
    idx     config.metabib_field%ROWTYPE;
    xfrm        config.xml_transform%ROWTYPE;
    prev_xfrm   TEXT;
    transformed_xml TEXT;
    xml_node    TEXT;
    xml_node_list   TEXT[];
    facet_text  TEXT;
    display_text TEXT;
    browse_text TEXT;
    sort_value  TEXT;
    raw_text    TEXT;
    curr_text   TEXT;
    joiner      TEXT := default_joiner; -- XXX will index defs supply a joiner?
    authority_text TEXT;
    authority_link BIGINT;
    output_row  metabib.field_entry_template%ROWTYPE;
    process_idx BOOL;
BEGIN

    -- Start out with no field-use bools set
    output_row.browse_nocase = FALSE;
    output_row.browse_field = FALSE;
    output_row.facet_field = FALSE;
    output_row.display_field = FALSE;
    output_row.search_field = FALSE;

    -- Get the record
    SELECT INTO bib * FROM biblio.record_entry WHERE id = rid;

    -- Loop over the indexing entries
    FOR idx IN SELECT * FROM config.metabib_field WHERE id = ANY (only_fields) ORDER BY format LOOP
        CONTINUE WHEN idx.xpath IS NULL OR idx.xpath = ''; -- pure virtual field

        process_idx := FALSE;
        IF idx.display_field AND 'display' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.browse_field AND 'browse' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.search_field AND 'search' = ANY (field_types) THEN process_idx = TRUE; END IF;
        IF idx.facet_field AND 'facet' = ANY (field_types) THEN process_idx = TRUE; END IF;
        CONTINUE WHEN process_idx = FALSE; -- disabled for all types

        joiner := COALESCE(idx.joiner, default_joiner);

        SELECT INTO xfrm * from config.xml_transform WHERE name = idx.format;

        -- See if we can skip the XSLT ... it's expensive
        IF prev_xfrm IS NULL OR prev_xfrm <> xfrm.name THEN
            -- Can't skip the transform
            IF xfrm.xslt <> '---' THEN
                transformed_xml := oils_xslt_process(bib.marc,xfrm.xslt);
            ELSE
                transformed_xml := bib.marc;
            END IF;

            prev_xfrm := xfrm.name;
        END IF;

        xml_node_list := oils_xpath( idx.xpath, transformed_xml, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );

        raw_text := NULL;
        FOR xml_node IN SELECT x FROM unnest(xml_node_list) AS x LOOP
            CONTINUE WHEN xml_node !~ E'^\\s*<';

            -- XXX much of this should be moved into oils_xpath_string...
            curr_text := ARRAY_TO_STRING(array_remove(array_remove(
                oils_xpath( '//text()', -- get the content of all the nodes within the main selected node
                    REGEXP_REPLACE( xml_node, E'\\s+', ' ', 'g' ) -- Translate adjacent whitespace to a single space
                ), ' '), ''),  -- throw away morally empty (bankrupt?) strings
                joiner
            );

            CONTINUE WHEN curr_text IS NULL OR curr_text = '';

            IF raw_text IS NOT NULL THEN
                raw_text := raw_text || joiner;
            END IF;

            raw_text := COALESCE(raw_text,'') || curr_text;

            -- autosuggest/metabib.browse_entry
            IF idx.browse_field THEN
                output_row.browse_nocase = idx.browse_nocase;

                IF idx.browse_xpath IS NOT NULL AND idx.browse_xpath <> '' THEN
                    browse_text := oils_xpath_string( idx.browse_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    browse_text := curr_text;
                END IF;

                IF idx.browse_sort_xpath IS NOT NULL AND
                    idx.browse_sort_xpath <> '' THEN

                    sort_value := oils_xpath_string(
                        idx.browse_sort_xpath, xml_node, joiner,
                        ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]]
                    );
                ELSE
                    sort_value := browse_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(browse_text, E'\\s+', ' ', 'g'));
                output_row.sort_value :=
                    public.naco_normalize(sort_value);

                output_row.authority := NULL;

                IF idx.authority_xpath IS NOT NULL AND idx.authority_xpath <> '' THEN
                    authority_text := oils_xpath_string(
                        idx.authority_xpath, xml_node, joiner,
                        ARRAY[
                            ARRAY[xfrm.prefix, xfrm.namespace_uri],
                            ARRAY['xlink','http://www.w3.org/1999/xlink']
                        ]
                    );

                    IF authority_text ~ '^\d+$' THEN
                        authority_link := authority_text::BIGINT;
                        PERFORM * FROM authority.record_entry WHERE id = authority_link;
                        IF FOUND THEN
                            output_row.authority := authority_link;
                        END IF;
                    END IF;

                END IF;

                output_row.browse_field = TRUE;
                -- Returning browse rows with search_field = true for search+browse
                -- configs allows us to retain granularity of being able to search
                -- browse fields with "starts with" type operators (for example, for
                -- titles of songs in music albums)
                IF idx.search_field THEN
                    output_row.search_field = TRUE;
                END IF;
                RETURN NEXT output_row;
                output_row.browse_nocase = FALSE;
                output_row.browse_field = FALSE;
                output_row.search_field = FALSE;
                output_row.sort_value := NULL;
            END IF;

            -- insert raw node text for faceting
            IF idx.facet_field THEN

                IF idx.facet_xpath IS NOT NULL AND idx.facet_xpath <> '' THEN
                    facet_text := oils_xpath_string( idx.facet_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    facet_text := curr_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = -1 * idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(facet_text, E'\\s+', ' ', 'g'));

                output_row.facet_field = TRUE;
                RETURN NEXT output_row;
                output_row.facet_field = FALSE;
            END IF;

            -- insert raw node text for display
            IF idx.display_field THEN

                IF idx.display_xpath IS NOT NULL AND idx.display_xpath <> '' THEN
                    display_text := oils_xpath_string( idx.display_xpath, xml_node, joiner, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );
                ELSE
                    display_text := curr_text;
                END IF;

                output_row.field_class = idx.field_class;
                output_row.field = -1 * idx.id;
                output_row.source = rid;
                output_row.value = BTRIM(REGEXP_REPLACE(display_text, E'\\s+', ' ', 'g'));

                output_row.display_field = TRUE;
                RETURN NEXT output_row;
                output_row.display_field = FALSE;
            END IF;

        END LOOP;

        CONTINUE WHEN raw_text IS NULL OR raw_text = '';

        -- insert combined node text for searching
        IF idx.search_field THEN
            output_row.field_class = idx.field_class;
            output_row.field = idx.id;
            output_row.source = rid;
            output_row.value = BTRIM(REGEXP_REPLACE(raw_text, E'\\s+', ' ', 'g'));

            output_row.search_field = TRUE;
            RETURN NEXT output_row;
            output_row.search_field = FALSE;
        END IF;

    END LOOP;

END;
$func$ LANGUAGE PLPGSQL;


SELECT evergreen.upgrade_deps_block_check('1304', :eg_version);

CREATE OR REPLACE FUNCTION actor.usr_purge_data(
	src_usr  IN INTEGER,
	specified_dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	renamable_row RECORD;
	dest_usr INTEGER;
BEGIN

	IF specified_dest_usr IS NULL THEN
		dest_usr := 1; -- Admin user on stock installs
	ELSE
		dest_usr := specified_dest_usr;
	END IF;

    -- action_trigger.event (even doing this, event_output may--and probably does--contain PII and should have a retention/removal policy)
    UPDATE action_trigger.event SET context_user = dest_usr WHERE context_user = src_usr;

	-- acq.*
	UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.lineitem SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.lineitem SET selector = dest_usr WHERE selector = src_usr;
	UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;
	DELETE FROM acq.lineitem_usr_attr_definition WHERE usr = src_usr;

	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE acq.picklist SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.picklist SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
	UPDATE acq.purchase_order SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.purchase_order SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.claim_event SET creator = dest_usr WHERE creator = src_usr;

	-- action.*
	DELETE FROM action.circulation WHERE usr = src_usr;
	UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
	UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
	UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;
	UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
	UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
	DELETE FROM action.hold_request WHERE usr = src_usr;
	UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
	UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.non_cataloged_circulation WHERE patron = src_usr;
	UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.survey_response WHERE usr = src_usr;
	UPDATE action.fieldset SET owner = dest_usr WHERE owner = src_usr;
	DELETE FROM action.usr_circ_history WHERE usr = src_usr;

	-- actor.*
	DELETE FROM actor.card WHERE usr = src_usr;
	DELETE FROM actor.stat_cat_entry_usr_map WHERE target_usr = src_usr;
	DELETE FROM actor.usr_privacy_waiver WHERE usr = src_usr;

	-- The following update is intended to avoid transient violations of a foreign
	-- key constraint, whereby actor.usr_address references itself.  It may not be
	-- necessary, but it does no harm.
	UPDATE actor.usr_address SET replaces = NULL
		WHERE usr = src_usr AND replaces IS NOT NULL;
	DELETE FROM actor.usr_address WHERE usr = src_usr;
	DELETE FROM actor.usr_org_unit_opt_in WHERE usr = src_usr;
	UPDATE actor.usr_org_unit_opt_in SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM actor.usr_setting WHERE usr = src_usr;
	DELETE FROM actor.usr_standing_penalty WHERE usr = src_usr;
	UPDATE actor.usr_message SET title = 'purged', message = 'purged', read_date = NOW() WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;
	UPDATE actor.usr_standing_penalty SET staff = dest_usr WHERE staff = src_usr;
	UPDATE actor.usr_message SET editor = dest_usr WHERE editor = src_usr;

	-- asset.*
	UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;

	-- auditor.*
	DELETE FROM auditor.actor_usr_address_history WHERE id = src_usr;
	DELETE FROM auditor.actor_usr_history WHERE id = src_usr;
	UPDATE auditor.asset_call_number_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_call_number_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.asset_copy_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_copy_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.biblio_record_entry_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.biblio_record_entry_history SET editor  = dest_usr WHERE editor  = src_usr;

	-- biblio.*
	UPDATE biblio.record_entry SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_entry SET editor = dest_usr WHERE editor = src_usr;
	UPDATE biblio.record_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_note SET editor = dest_usr WHERE editor = src_usr;

	-- container.*
	-- Update buckets with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	DELETE FROM container.user_bucket_item WHERE target_user = src_usr;

	-- money.*
	DELETE FROM money.billable_xact WHERE usr = src_usr;
	DELETE FROM money.collections_tracker WHERE usr = src_usr;
	UPDATE money.collections_tracker SET collector = dest_usr WHERE collector = src_usr;

	-- permission.*
	DELETE FROM permission.usr_grp_map WHERE usr = src_usr;
	DELETE FROM permission.usr_object_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_work_ou_map WHERE usr = src_usr;

	-- reporter.*
	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
	-- do nothing
	END;

	-- vandelay.*
	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- NULL-ify addresses last so other cleanup (e.g. circ anonymization)
    -- can access the information before deletion.
	UPDATE actor.usr SET
		active = FALSE,
		card = NULL,
		mailing_address = NULL,
		billing_address = NULL
	WHERE id = src_usr;

END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION actor.usr_delete(
	src_usr  IN INTEGER,
	dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	old_profile actor.usr.profile%type;
	old_home_ou actor.usr.home_ou%type;
	new_profile actor.usr.profile%type;
	new_home_ou actor.usr.home_ou%type;
	new_name    text;
	new_dob     actor.usr.dob%type;
BEGIN
	SELECT
		id || '-PURGED-' || now(),
		profile,
		home_ou,
		dob
	INTO
		new_name,
		old_profile,
		old_home_ou,
		new_dob
	FROM
		actor.usr
	WHERE
		id = src_usr;
	--
	-- Quit if no such user
	--
	IF old_profile IS NULL THEN
		RETURN;
	END IF;
	--
	perform actor.usr_purge_data( src_usr, dest_usr );
	--
	-- Find the root grp_tree and the root org_unit.  This would be simpler if we 
	-- could assume that there is only one root.  Theoretically, someday, maybe,
	-- there could be multiple roots, so we take extra trouble to get the right ones.
	--
	SELECT
		id
	INTO
		new_profile
	FROM
		permission.grp_ancestors( old_profile )
	WHERE
		parent is null;
	--
	SELECT
		id
	INTO
		new_home_ou
	FROM
		actor.org_unit_ancestors( old_home_ou )
	WHERE
		parent_ou is null;
	--
	-- Truncate date of birth
	--
	IF new_dob IS NOT NULL THEN
		new_dob := date_trunc( 'year', new_dob );
	END IF;
	--
	UPDATE
		actor.usr
		SET
			card = NULL,
			profile = new_profile,
			usrname = new_name,
			email = NULL,
			passwd = random()::text,
			standing = DEFAULT,
			ident_type = 
			(
				SELECT MIN( id )
				FROM config.identification_type
			),
			ident_value = NULL,
			ident_type2 = NULL,
			ident_value2 = NULL,
			net_access_level = DEFAULT,
			photo_url = NULL,
			prefix = NULL,
			first_given_name = new_name,
			second_given_name = NULL,
			family_name = new_name,
			suffix = NULL,
			alias = NULL,
            guardian = NULL,
			day_phone = NULL,
			evening_phone = NULL,
			other_phone = NULL,
			mailing_address = NULL,
			billing_address = NULL,
			home_ou = new_home_ou,
			dob = new_dob,
			active = FALSE,
			master_account = DEFAULT, 
			super_user = DEFAULT,
			barred = FALSE,
			deleted = TRUE,
			juvenile = DEFAULT,
			usrgroup = 0,
			claims_returned_count = DEFAULT,
			credit_forward_balance = DEFAULT,
			last_xact_id = DEFAULT,
			pref_prefix = NULL,
			pref_first_given_name = NULL,
			pref_second_given_name = NULL,
			pref_family_name = NULL,
			pref_suffix = NULL,
			name_keywords = NULL,
			create_date = now(),
			expire_date = now()
	WHERE
		id = src_usr;
END;
$$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1305', :eg_version);

CREATE OR REPLACE FUNCTION actor.usr_merge( src_usr INT, dest_usr INT, del_addrs BOOLEAN, del_cards BOOLEAN, deactivate_cards BOOLEAN ) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	bucket_row RECORD;
	picklist_row RECORD;
	queue_row RECORD;
	folder_row RECORD;
BEGIN

    -- Bail if src_usr equals dest_usr because the result of merging a
    -- user with itself is not what you want.
    IF src_usr = dest_usr THEN
        RETURN;
    END IF;

    -- do some initial cleanup 
    UPDATE actor.usr SET card = NULL WHERE id = src_usr;
    UPDATE actor.usr SET mailing_address = NULL WHERE id = src_usr;
    UPDATE actor.usr SET billing_address = NULL WHERE id = src_usr;

    -- actor.*
    IF del_cards THEN
        DELETE FROM actor.card where usr = src_usr;
    ELSE
        IF deactivate_cards THEN
            UPDATE actor.card SET active = 'f' WHERE usr = src_usr;
        END IF;
        UPDATE actor.card SET usr = dest_usr WHERE usr = src_usr;
    END IF;


    IF del_addrs THEN
        DELETE FROM actor.usr_address WHERE usr = src_usr;
    ELSE
        UPDATE actor.usr_address SET usr = dest_usr WHERE usr = src_usr;
    END IF;

    UPDATE actor.usr_message SET usr = dest_usr WHERE usr = src_usr;
    -- dupes are technically OK in actor.usr_standing_penalty, should manually delete them...
    UPDATE actor.usr_standing_penalty SET usr = dest_usr WHERE usr = src_usr;
    PERFORM actor.usr_merge_rows('actor.usr_org_unit_opt_in', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('actor.usr_setting', 'usr', src_usr, dest_usr);

    -- permission.*
    PERFORM actor.usr_merge_rows('permission.usr_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_object_perm_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_grp_map', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('permission.usr_work_ou_map', 'usr', src_usr, dest_usr);


    -- container.*
	
	-- For each *_bucket table: transfer every bucket belonging to src_usr
	-- into the custody of dest_usr.
	--
	-- In order to avoid colliding with an existing bucket owned by
	-- the destination user, append the source user's id (in parenthesese)
	-- to the name.  If you still get a collision, add successive
	-- spaces to the name and keep trying until you succeed.
	--
	FOR bucket_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR bucket_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = bucket_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE container.user_bucket_item SET target_user = dest_usr WHERE target_user = src_usr;

    -- vandelay.*
	-- transfer queues the same way we transfer buckets (see above)
	FOR queue_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = queue_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- money.*
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'usr', src_usr, dest_usr);
    PERFORM actor.usr_merge_rows('money.collections_tracker', 'collector', src_usr, dest_usr);
    UPDATE money.billable_xact SET usr = dest_usr WHERE usr = src_usr;
    UPDATE money.billing SET voider = dest_usr WHERE voider = src_usr;
    UPDATE money.bnm_payment SET accepting_usr = dest_usr WHERE accepting_usr = src_usr;

    -- action.*
    UPDATE action.circulation SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
    UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
    UPDATE action.usr_circ_history SET usr = dest_usr WHERE usr = src_usr;

    UPDATE action.hold_request SET usr = dest_usr WHERE usr = src_usr;
    UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
    UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
    UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;

    UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.non_cataloged_circulation SET patron = dest_usr WHERE patron = src_usr;
    UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
    UPDATE action.survey_response SET usr = dest_usr WHERE usr = src_usr;

    -- acq.*
    UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.fund_transfer SET transfer_user = dest_usr WHERE transfer_user = src_usr;
    UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;

	-- transfer picklists the same way we transfer buckets (see above)
	FOR picklist_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = picklist_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
    UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.provider_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.provider_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
    UPDATE acq.lineitem_usr_attr_definition SET usr = dest_usr WHERE usr = src_usr;

    -- asset.*
    UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
    UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
    UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;

    -- serial.*
    UPDATE serial.record_entry SET creator = dest_usr WHERE creator = src_usr;
    UPDATE serial.record_entry SET editor = dest_usr WHERE editor = src_usr;

    -- reporter.*
    -- It's not uncommon to define the reporter schema in a replica 
    -- DB only, so don't assume these tables exist in the write DB.
    BEGIN
    	UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
    	UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;
    BEGIN
		-- transfer folders the same way we transfer buckets (see above)
		FOR folder_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = folder_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
    EXCEPTION WHEN undefined_table THEN
        -- do nothing
    END;

    -- propagate preferred name values from the source user to the
    -- destination user, but only when values are not being replaced.
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr)
    UPDATE actor.usr SET 
        pref_prefix = 
            COALESCE(pref_prefix, (SELECT pref_prefix FROM susr)),
        pref_first_given_name = 
            COALESCE(pref_first_given_name, (SELECT pref_first_given_name FROM susr)),
        pref_second_given_name = 
            COALESCE(pref_second_given_name, (SELECT pref_second_given_name FROM susr)),
        pref_family_name = 
            COALESCE(pref_family_name, (SELECT pref_family_name FROM susr)),
        pref_suffix = 
            COALESCE(pref_suffix, (SELECT pref_suffix FROM susr))
    WHERE id = dest_usr;

    -- Copy and deduplicate name keywords
    -- String -> array -> rows -> DISTINCT -> array -> string
    WITH susr AS (SELECT * FROM actor.usr WHERE id = src_usr),
         dusr AS (SELECT * FROM actor.usr WHERE id = dest_usr)
    UPDATE actor.usr SET name_keywords = (
        WITH keywords AS (
            SELECT DISTINCT UNNEST(
                REGEXP_SPLIT_TO_ARRAY(
                    COALESCE((SELECT name_keywords FROM susr), '') || ' ' ||
                    COALESCE((SELECT name_keywords FROM dusr), ''),  E'\\s+'
                )
            ) AS parts
        ) SELECT ARRAY_TO_STRING(ARRAY_AGG(kw.parts), ' ') FROM keywords kw
    ) WHERE id = dest_usr;

    -- Finally, delete the source user
    PERFORM actor.usr_delete(src_usr,dest_usr);

END;
$$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1307', :eg_version);

DROP FUNCTION search.query_parser_fts (
    INT,
    INT,
    TEXT,
    INT[],
    INT[],
    INT,
    INT,
    INT,
    BOOL,
    BOOL,
    BOOL,
    INT 
);

DROP TABLE asset.opac_visible_copies;

DROP FUNCTION IF EXISTS asset.refresh_opac_visible_copies_mat_view();

DROP TYPE search.search_result CASCADE;
DROP TYPE search.search_args;


SELECT evergreen.upgrade_deps_block_check('1308', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.triggers.atevdef', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.triggers.atevdef',
        'Grid Config: eg.grid.admin.local.triggers.atevdef',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.local.triggers.atenv', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.triggers.atenv',
        'Grid Config: eg.grid.admin.local.triggers.atenv',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.local.triggers.atevparam', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.triggers.atevparam',
        'Grid Config: eg.grid.admin.local.triggers.atevparam',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1310', :eg_version);

DROP AGGREGATE IF EXISTS array_accum(anyelement) CASCADE;



SELECT evergreen.upgrade_deps_block_check('1313', :eg_version); -- alynn26

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.cat.bucket.batch_hold.view', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.bucket.batch_hold.view',
        'Grid Config: eg.grid.cat.bucket.batch_hold.view',
        'cwst', 'label'
    )
), (
    'eg.grid.cat.bucket.batch_hold.pending', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.bucket.batch_hold.pending',
        'Grid Config: eg.grid.cat.bucket.batch_hold.pending',
        'cwst', 'label'
    )
), (
    'eg.grid.cat.bucket.batch_hold.events', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.bucket.batch_hold.events',
        'Grid Config: eg.grid.cat.bucket.batch_hold.events',
        'cwst', 'label'
    )
), (
    'eg.grid.cat.bucket.batch_hold.list', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.cat.bucket.batch_hold.list',
        'Grid Config: eg.grid.cat.bucket.batch_hold.list',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1314', :eg_version);

CREATE OR REPLACE FUNCTION authority.generate_overlay_template (source_xml TEXT) RETURNS TEXT AS $f$
DECLARE
    cset                INT;
    main_entry          authority.control_set_authority_field%ROWTYPE;
    bib_field           authority.control_set_bib_field%ROWTYPE;
    auth_id             INT DEFAULT oils_xpath_string('//*[@tag="901"]/*[local-name()="subfield" and @code="c"]', source_xml)::INT;
    tmp_data            XML;
    replace_data        XML[] DEFAULT '{}'::XML[];
    replace_rules       TEXT[] DEFAULT '{}'::TEXT[];
    auth_field          XML[];
    auth_i1             TEXT;
    auth_i2             TEXT;
BEGIN
    IF auth_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Default to the LoC controll set
    SELECT control_set INTO cset FROM authority.record_entry WHERE id = auth_id;

    -- if none, make a best guess
    IF cset IS NULL THEN
        SELECT  control_set INTO cset
          FROM  authority.control_set_authority_field
          WHERE tag IN (
                    SELECT  UNNEST(XPATH('//*[local-name()="datafield" and starts-with(@tag,"1")]/@tag',marc::XML)::TEXT[])
                      FROM  authority.record_entry
                      WHERE id = auth_id
                )
          LIMIT 1;
    END IF;

    -- if STILL none, no-op change
    IF cset IS NULL THEN
        RETURN XMLELEMENT(
            name record,
            XMLATTRIBUTES('http://www.loc.gov/MARC21/slim' AS xmlns),
            XMLELEMENT( name leader, '00881nam a2200193   4500'),
            XMLELEMENT(
                name datafield,
                XMLATTRIBUTES( '905' AS tag, ' ' AS ind1, ' ' AS ind2),
                XMLELEMENT(
                    name subfield,
                    XMLATTRIBUTES('d' AS code),
                    '901c'
                )
            )
        )::TEXT;
    END IF;

    FOR main_entry IN SELECT * FROM authority.control_set_authority_field acsaf WHERE acsaf.control_set = cset AND acsaf.main_entry IS NULL LOOP
        auth_field := XPATH('//*[local-name()="datafield" and @tag="'||main_entry.tag||'"][1]',source_xml::XML);
        auth_i1 := (XPATH('//*[local-name()="datafield"]/@ind1',auth_field[1]))[1];
        auth_i2 := (XPATH('//*[local-name()="datafield"]/@ind2',auth_field[1]))[1];
        IF ARRAY_LENGTH(auth_field,1) > 0 THEN
            FOR bib_field IN SELECT * FROM authority.control_set_bib_field WHERE authority_field = main_entry.id LOOP
                SELECT XMLELEMENT( -- XMLAGG avoids magical <element> creation, but requires unnest subquery
                    name datafield,
                    XMLATTRIBUTES(bib_field.tag AS tag, auth_i1 AS ind1, auth_i2 AS ind2),
                    XMLAGG(UNNEST)
                ) INTO tmp_data FROM UNNEST(XPATH('//*[local-name()="subfield"]', auth_field[1]));
                replace_data := replace_data || tmp_data;
                replace_rules := replace_rules || ( bib_field.tag || main_entry.sf_list || E'[0~\\)' || auth_id || '$]' );
                tmp_data = NULL;
            END LOOP;
            EXIT;
        END IF;
    END LOOP;

    SELECT XMLAGG(UNNEST) INTO tmp_data FROM UNNEST(replace_data);

    RETURN XMLELEMENT(
        name record,
        XMLATTRIBUTES('http://www.loc.gov/MARC21/slim' AS xmlns),
        XMLELEMENT( name leader, '00881nam a2200193   4500'),
        tmp_data,
        XMLELEMENT(
            name datafield,
            XMLATTRIBUTES( '905' AS tag, ' ' AS ind1, ' ' AS ind2),
            XMLELEMENT(
                name subfield,
                XMLATTRIBUTES('r' AS code),
                ARRAY_TO_STRING(replace_rules,',')
            )
        )
    )::TEXT;
END;
$f$ STABLE LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.normalize_heading( marcxml TEXT, no_thesaurus BOOL ) RETURNS TEXT AS $func$
DECLARE
    acsaf           authority.control_set_authority_field%ROWTYPE;
    tag_used        TEXT;
    nfi_used        TEXT;
    sf              TEXT;
    sf_node         TEXT;
    tag_node        TEXT;
    thes_code       TEXT;
    cset            INT;
    heading_text    TEXT;
    tmp_text        TEXT;
    first_sf        BOOL;
    auth_id         INT DEFAULT COALESCE(NULLIF(oils_xpath_string('//*[@tag="901"]/*[local-name()="subfield" and @code="c"]', marcxml), ''), '0')::INT;
BEGIN
    SELECT control_set INTO cset FROM authority.record_entry WHERE id = auth_id;

    IF cset IS NULL THEN
        SELECT  control_set INTO cset
          FROM  authority.control_set_authority_field
          WHERE tag IN (SELECT UNNEST(XPATH('//*[starts-with(@tag,"1")]/@tag',marcxml::XML)::TEXT[]))
          LIMIT 1;
    END IF;

    heading_text := '';
    FOR acsaf IN SELECT * FROM authority.control_set_authority_field WHERE control_set = cset AND main_entry IS NULL LOOP
        tag_used := acsaf.tag;
        nfi_used := acsaf.nfi;
        first_sf := TRUE;

        FOR tag_node IN SELECT unnest(oils_xpath('//*[@tag="'||tag_used||'"]',marcxml))
        LOOP
            FOR sf_node IN SELECT unnest(oils_xpath('//*[local-name() = "subfield" and contains("'||acsaf.sf_list||'",@code)]',tag_node))
            LOOP

                tmp_text := oils_xpath_string('.', sf_node);
                sf := oils_xpath_string('//*/@code', sf_node);

                IF first_sf AND tmp_text IS NOT NULL AND nfi_used IS NOT NULL THEN

                    tmp_text := SUBSTRING(
                        tmp_text FROM
                        COALESCE(
                            NULLIF(
                                REGEXP_REPLACE(
                                    oils_xpath_string('//*[local-name() = "datafield"]/@ind'||nfi_used, tag_node),
                                    $$\D+$$,
                                    '',
                                    'g'
                                ),
                                ''
                            )::INT,
                            0
                        ) + 1
                    );

                END IF;

                first_sf := FALSE;

                IF tmp_text IS NOT NULL AND tmp_text <> '' THEN
                    heading_text := heading_text || E'\u2021' || sf || ' ' || tmp_text;
                END IF;
            END LOOP;

            EXIT WHEN heading_text <> '';
        END LOOP;

        EXIT WHEN heading_text <> '';
    END LOOP;

    IF heading_text <> '' THEN
        IF no_thesaurus IS TRUE THEN
            heading_text := tag_used || ' ' || public.naco_normalize(heading_text);
        ELSE
            thes_code := authority.extract_thesaurus(marcxml);
            heading_text := tag_used || '_' || COALESCE(nfi_used,'-') || '_' || thes_code || ' ' || public.naco_normalize(heading_text);
        END IF;
    ELSE
        heading_text := 'NOHEADING_' || thes_code || ' ' || MD5(marcxml);
    END IF;

    RETURN heading_text;
END;
$func$ LANGUAGE PLPGSQL STABLE STRICT;

CREATE OR REPLACE FUNCTION vandelay.ingest_items ( import_id BIGINT, attr_def_id BIGINT ) RETURNS SETOF vandelay.import_item AS $$
DECLARE

    owning_lib      TEXT;
    circ_lib        TEXT;
    call_number     TEXT;
    copy_number     TEXT;
    status          TEXT;
    location        TEXT;
    circulate       TEXT;
    deposit         TEXT;
    deposit_amount  TEXT;
    ref             TEXT;
    holdable        TEXT;
    price           TEXT;
    barcode         TEXT;
    circ_modifier   TEXT;
    circ_as_type    TEXT;
    alert_message   TEXT;
    opac_visible    TEXT;
    pub_note        TEXT;
    priv_note       TEXT;
    internal_id     TEXT;
    stat_cat_data   TEXT;
    parts_data      TEXT;

    attr_def        RECORD;
    tmp_attr_set    RECORD;
    attr_set        vandelay.import_item%ROWTYPE;

    xpaths          TEXT[];
    tmp_str         TEXT;

BEGIN

    SELECT * INTO attr_def FROM vandelay.import_item_attr_definition WHERE id = attr_def_id;

    IF FOUND THEN

        attr_set.definition := attr_def.id;

        -- Build the combined XPath

        owning_lib :=
            CASE
                WHEN attr_def.owning_lib IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.owning_lib ) = 1 THEN '//*[@code="' || attr_def.owning_lib || '"]'
                ELSE '//*' || attr_def.owning_lib
            END;

        circ_lib :=
            CASE
                WHEN attr_def.circ_lib IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.circ_lib ) = 1 THEN '//*[@code="' || attr_def.circ_lib || '"]'
                ELSE '//*' || attr_def.circ_lib
            END;

        call_number :=
            CASE
                WHEN attr_def.call_number IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.call_number ) = 1 THEN '//*[@code="' || attr_def.call_number || '"]'
                ELSE '//*' || attr_def.call_number
            END;

        copy_number :=
            CASE
                WHEN attr_def.copy_number IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.copy_number ) = 1 THEN '//*[@code="' || attr_def.copy_number || '"]'
                ELSE '//*' || attr_def.copy_number
            END;

        status :=
            CASE
                WHEN attr_def.status IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.status ) = 1 THEN '//*[@code="' || attr_def.status || '"]'
                ELSE '//*' || attr_def.status
            END;

        location :=
            CASE
                WHEN attr_def.location IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.location ) = 1 THEN '//*[@code="' || attr_def.location || '"]'
                ELSE '//*' || attr_def.location
            END;

        circulate :=
            CASE
                WHEN attr_def.circulate IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.circulate ) = 1 THEN '//*[@code="' || attr_def.circulate || '"]'
                ELSE '//*' || attr_def.circulate
            END;

        deposit :=
            CASE
                WHEN attr_def.deposit IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.deposit ) = 1 THEN '//*[@code="' || attr_def.deposit || '"]'
                ELSE '//*' || attr_def.deposit
            END;

        deposit_amount :=
            CASE
                WHEN attr_def.deposit_amount IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.deposit_amount ) = 1 THEN '//*[@code="' || attr_def.deposit_amount || '"]'
                ELSE '//*' || attr_def.deposit_amount
            END;

        ref :=
            CASE
                WHEN attr_def.ref IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.ref ) = 1 THEN '//*[@code="' || attr_def.ref || '"]'
                ELSE '//*' || attr_def.ref
            END;

        holdable :=
            CASE
                WHEN attr_def.holdable IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.holdable ) = 1 THEN '//*[@code="' || attr_def.holdable || '"]'
                ELSE '//*' || attr_def.holdable
            END;

        price :=
            CASE
                WHEN attr_def.price IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.price ) = 1 THEN '//*[@code="' || attr_def.price || '"]'
                ELSE '//*' || attr_def.price
            END;

        barcode :=
            CASE
                WHEN attr_def.barcode IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.barcode ) = 1 THEN '//*[@code="' || attr_def.barcode || '"]'
                ELSE '//*' || attr_def.barcode
            END;

        circ_modifier :=
            CASE
                WHEN attr_def.circ_modifier IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.circ_modifier ) = 1 THEN '//*[@code="' || attr_def.circ_modifier || '"]'
                ELSE '//*' || attr_def.circ_modifier
            END;

        circ_as_type :=
            CASE
                WHEN attr_def.circ_as_type IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.circ_as_type ) = 1 THEN '//*[@code="' || attr_def.circ_as_type || '"]'
                ELSE '//*' || attr_def.circ_as_type
            END;

        alert_message :=
            CASE
                WHEN attr_def.alert_message IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.alert_message ) = 1 THEN '//*[@code="' || attr_def.alert_message || '"]'
                ELSE '//*' || attr_def.alert_message
            END;

        opac_visible :=
            CASE
                WHEN attr_def.opac_visible IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.opac_visible ) = 1 THEN '//*[@code="' || attr_def.opac_visible || '"]'
                ELSE '//*' || attr_def.opac_visible
            END;

        pub_note :=
            CASE
                WHEN attr_def.pub_note IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.pub_note ) = 1 THEN '//*[@code="' || attr_def.pub_note || '"]'
                ELSE '//*' || attr_def.pub_note
            END;
        priv_note :=
            CASE
                WHEN attr_def.priv_note IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.priv_note ) = 1 THEN '//*[@code="' || attr_def.priv_note || '"]'
                ELSE '//*' || attr_def.priv_note
            END;

        internal_id :=
            CASE
                WHEN attr_def.internal_id IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.internal_id ) = 1 THEN '//*[@code="' || attr_def.internal_id || '"]'
                ELSE '//*' || attr_def.internal_id
            END;

        stat_cat_data :=
            CASE
                WHEN attr_def.stat_cat_data IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.stat_cat_data ) = 1 THEN '//*[@code="' || attr_def.stat_cat_data || '"]'
                ELSE '//*' || attr_def.stat_cat_data
            END;

        parts_data :=
            CASE
                WHEN attr_def.parts_data IS NULL THEN 'null()'
                WHEN LENGTH( attr_def.parts_data ) = 1 THEN '//*[@code="' || attr_def.parts_data || '"]'
                ELSE '//*' || attr_def.parts_data
            END;



        xpaths := ARRAY[owning_lib, circ_lib, call_number, copy_number, status, location, circulate,
                        deposit, deposit_amount, ref, holdable, price, barcode, circ_modifier, circ_as_type,
                        alert_message, pub_note, priv_note, internal_id, stat_cat_data, parts_data, opac_visible];

        FOR tmp_attr_set IN
                SELECT  *
                  FROM  oils_xpath_tag_to_table( (SELECT marc FROM vandelay.queued_bib_record WHERE id = import_id), attr_def.tag, xpaths)
                            AS t( ol TEXT, clib TEXT, cn TEXT, cnum TEXT, cs TEXT, cl TEXT, circ TEXT,
                                  dep TEXT, dep_amount TEXT, r TEXT, hold TEXT, pr TEXT, bc TEXT, circ_mod TEXT,
                                  circ_as TEXT, amessage TEXT, note TEXT, pnote TEXT, internal_id TEXT,
                                  stat_cat_data TEXT, parts_data TEXT, opac_vis TEXT )
        LOOP

            attr_set.import_error := NULL;
            attr_set.error_detail := NULL;
            attr_set.deposit_amount := NULL;
            attr_set.copy_number := NULL;
            attr_set.price := NULL;
            attr_set.circ_modifier := NULL;
            attr_set.location := NULL;
            attr_set.barcode := NULL;
            attr_set.call_number := NULL;

            IF tmp_attr_set.pr != '' THEN
                tmp_str = REGEXP_REPLACE(tmp_attr_set.pr, E'[^0-9\\.]', '', 'g');
                IF tmp_str = '' THEN
                    attr_set.import_error := 'import.item.invalid.price';
                    attr_set.error_detail := tmp_attr_set.pr; -- original value
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
                attr_set.price := tmp_str::NUMERIC(8,2);
            END IF;

            IF tmp_attr_set.dep_amount != '' THEN
                tmp_str = REGEXP_REPLACE(tmp_attr_set.dep_amount, E'[^0-9\\.]', '', 'g');
                IF tmp_str = '' THEN
                    attr_set.import_error := 'import.item.invalid.deposit_amount';
                    attr_set.error_detail := tmp_attr_set.dep_amount;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
                attr_set.deposit_amount := tmp_str::NUMERIC(8,2);
            END IF;

            IF tmp_attr_set.cnum != '' THEN
                tmp_str = REGEXP_REPLACE(tmp_attr_set.cnum, E'[^0-9]', '', 'g');
                IF tmp_str = '' THEN
                    attr_set.import_error := 'import.item.invalid.copy_number';
                    attr_set.error_detail := tmp_attr_set.cnum;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
                attr_set.copy_number := tmp_str::INT;
            END IF;

            IF tmp_attr_set.ol != '' THEN
                SELECT id INTO attr_set.owning_lib FROM actor.org_unit WHERE shortname = UPPER(tmp_attr_set.ol); -- INT
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.owning_lib';
                    attr_set.error_detail := tmp_attr_set.ol;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            IF tmp_attr_set.clib != '' THEN
                SELECT id INTO attr_set.circ_lib FROM actor.org_unit WHERE shortname = UPPER(tmp_attr_set.clib); -- INT
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.circ_lib';
                    attr_set.error_detail := tmp_attr_set.clib;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            IF tmp_attr_set.cs != '' THEN
                SELECT id INTO attr_set.status FROM config.copy_status WHERE LOWER(name) = LOWER(tmp_attr_set.cs); -- INT
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.status';
                    attr_set.error_detail := tmp_attr_set.cs;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            IF COALESCE(tmp_attr_set.circ_mod, '') = '' THEN

                -- no circ mod defined, see if we should apply a default
                SELECT INTO attr_set.circ_modifier TRIM(BOTH '"' FROM value)
                    FROM actor.org_unit_ancestor_setting(
                        'vandelay.item.circ_modifier.default',
                        attr_set.owning_lib
                    );

                -- make sure the value from the org setting is still valid
                PERFORM 1 FROM config.circ_modifier WHERE code = attr_set.circ_modifier;
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.circ_modifier';
                    attr_set.error_detail := tmp_attr_set.circ_mod;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;

            ELSE

                SELECT code INTO attr_set.circ_modifier FROM config.circ_modifier WHERE code = tmp_attr_set.circ_mod;
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.circ_modifier';
                    attr_set.error_detail := tmp_attr_set.circ_mod;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            IF tmp_attr_set.circ_as != '' THEN
                SELECT code INTO attr_set.circ_as_type FROM config.coded_value_map WHERE ctype = 'item_type' AND code = tmp_attr_set.circ_as;
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.circ_as_type';
                    attr_set.error_detail := tmp_attr_set.circ_as;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            IF COALESCE(tmp_attr_set.cl, '') = '' THEN
                -- no location specified, see if we should apply a default

                SELECT INTO attr_set.location TRIM(BOTH '"' FROM value)
                    FROM actor.org_unit_ancestor_setting(
                        'vandelay.item.copy_location.default',
                        attr_set.owning_lib
                    );

                -- make sure the value from the org setting is still valid
                PERFORM 1 FROM asset.copy_location
                    WHERE id = attr_set.location AND NOT deleted;
                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.location';
                    attr_set.error_detail := tmp_attr_set.cs;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            ELSE

                -- search up the org unit tree for a matching copy location
                WITH RECURSIVE anscestor_depth AS (
                    SELECT  ou.id,
                        out.depth AS depth,
                        ou.parent_ou
                    FROM  actor.org_unit ou
                        JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                    WHERE ou.id = COALESCE(attr_set.owning_lib, attr_set.circ_lib)
                        UNION ALL
                    SELECT  ou.id,
                        out.depth,
                        ou.parent_ou
                    FROM  actor.org_unit ou
                        JOIN actor.org_unit_type out ON (out.id = ou.ou_type)
                        JOIN anscestor_depth ot ON (ot.parent_ou = ou.id)
                ) SELECT  cpl.id INTO attr_set.location
                    FROM  anscestor_depth a
                        JOIN asset.copy_location cpl ON (cpl.owning_lib = a.id)
                    WHERE LOWER(cpl.name) = LOWER(tmp_attr_set.cl)
                        AND NOT cpl.deleted
                    ORDER BY a.depth DESC
                    LIMIT 1;

                IF NOT FOUND THEN
                    attr_set.import_error := 'import.item.invalid.location';
                    attr_set.error_detail := tmp_attr_set.cs;
                    RETURN NEXT attr_set; CONTINUE;
                END IF;
            END IF;

            attr_set.circulate      :=
                LOWER( SUBSTRING( tmp_attr_set.circ, 1, 1)) IN ('t','y','1')
                OR LOWER(tmp_attr_set.circ) = 'circulating'; -- BOOL

            attr_set.deposit        :=
                LOWER( SUBSTRING( tmp_attr_set.dep, 1, 1 ) ) IN ('t','y','1')
                OR LOWER(tmp_attr_set.dep) = 'deposit'; -- BOOL

            attr_set.holdable       :=
                LOWER( SUBSTRING( tmp_attr_set.hold, 1, 1 ) ) IN ('t','y','1')
                OR LOWER(tmp_attr_set.hold) = 'holdable'; -- BOOL

            attr_set.opac_visible   :=
                LOWER( SUBSTRING( tmp_attr_set.opac_vis, 1, 1 ) ) IN ('t','y','1')
                OR LOWER(tmp_attr_set.opac_vis) = 'visible'; -- BOOL

            attr_set.ref            :=
                LOWER( SUBSTRING( tmp_attr_set.r, 1, 1 ) ) IN ('t','y','1')
                OR LOWER(tmp_attr_set.r) = 'reference'; -- BOOL

            attr_set.call_number    := tmp_attr_set.cn; -- TEXT
            attr_set.barcode        := tmp_attr_set.bc; -- TEXT,
            attr_set.alert_message  := tmp_attr_set.amessage; -- TEXT,
            attr_set.pub_note       := tmp_attr_set.note; -- TEXT,
            attr_set.priv_note      := tmp_attr_set.pnote; -- TEXT,
            attr_set.alert_message  := tmp_attr_set.amessage; -- TEXT,
            attr_set.internal_id    := tmp_attr_set.internal_id::BIGINT;
            attr_set.stat_cat_data  := tmp_attr_set.stat_cat_data; -- TEXT,
            attr_set.parts_data     := tmp_attr_set.parts_data; -- TEXT,

            RETURN NEXT attr_set;

        END LOOP;

    END IF;

    RETURN;

END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION biblio.extract_quality ( marc TEXT, best_lang TEXT, best_type TEXT ) RETURNS INT AS $func$
DECLARE
    qual        INT;
    ldr         TEXT;
    tval        TEXT;
    tval_rec    RECORD;
    bval        TEXT;
    bval_rec    RECORD;
    type_map    RECORD;
    ff_pos      RECORD;
    ff_tag_data TEXT;
BEGIN

    IF marc IS NULL OR marc = '' THEN
        RETURN NULL;
    END IF;

    -- First, the count of tags
    qual := ARRAY_UPPER(oils_xpath('//*[local-name()="datafield"]', marc), 1);

    -- now go through a bunch of pain to get the record type
    IF best_type IS NOT NULL THEN
        ldr := (oils_xpath('//*[local-name()="leader"]/text()', marc))[1];

        IF ldr IS NOT NULL THEN
            SELECT * INTO tval_rec FROM config.marc21_ff_pos_map WHERE fixed_field = 'Type' LIMIT 1; -- They're all the same
            SELECT * INTO bval_rec FROM config.marc21_ff_pos_map WHERE fixed_field = 'BLvl' LIMIT 1; -- They're all the same


            tval := SUBSTRING( ldr, tval_rec.start_pos + 1, tval_rec.length );
            bval := SUBSTRING( ldr, bval_rec.start_pos + 1, bval_rec.length );

            -- RAISE NOTICE 'type %, blvl %, ldr %', tval, bval, ldr;

            SELECT * INTO type_map FROM config.marc21_rec_type_map WHERE type_val LIKE '%' || tval || '%' AND blvl_val LIKE '%' || bval || '%';

            IF type_map.code IS NOT NULL THEN
                IF best_type = type_map.code THEN
                    qual := qual + qual / 2;
                END IF;

                FOR ff_pos IN SELECT * FROM config.marc21_ff_pos_map WHERE fixed_field = 'Lang' AND rec_type = type_map.code ORDER BY tag DESC LOOP
                    ff_tag_data := SUBSTRING((oils_xpath('//*[@tag="' || ff_pos.tag || '"]/text()',marc))[1], ff_pos.start_pos + 1, ff_pos.length);
                    IF ff_tag_data = best_lang THEN
                            qual := qual + 100;
                    END IF;
                END LOOP;
            END IF;
        END IF;
    END IF;

    -- Now look for some quality metrics
    -- DCL record?
    IF ARRAY_UPPER(oils_xpath('//*[@tag="040"]/*[@code="a" and contains(.,"DLC")]', marc), 1) = 1 THEN
        qual := qual + 10;
    END IF;

    -- From OCLC?
    IF (oils_xpath('//*[@tag="003"]/text()', marc))[1] ~* E'oclo?c' THEN
        qual := qual + 10;
    END IF;

    RETURN qual;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION authority.simple_heading_set( marcxml TEXT ) RETURNS SETOF authority.simple_heading AS $func$
DECLARE
    res             authority.simple_heading%ROWTYPE;
    acsaf           authority.control_set_authority_field%ROWTYPE;
    heading_row     authority.heading%ROWTYPE;
    tag_used        TEXT;
    nfi_used        TEXT;
    sf              TEXT;
    cset            INT;
    heading_text    TEXT;
    joiner_text     TEXT;
    sort_text       TEXT;
    tmp_text        TEXT;
    tmp_xml         TEXT;
    first_sf        BOOL;
    auth_id         INT DEFAULT COALESCE(NULLIF(oils_xpath_string('//*[@tag="901"]/*[local-name()="subfield" and @code="c"]', marcxml), ''), '0')::INT;
BEGIN

    SELECT control_set INTO cset FROM authority.record_entry WHERE id = auth_id;

    IF cset IS NULL THEN
        SELECT  control_set INTO cset
          FROM  authority.control_set_authority_field
          WHERE tag IN ( SELECT  UNNEST(XPATH('//*[starts-with(@tag,"1")]/@tag',marcxml::XML)::TEXT[]))
          LIMIT 1;
    END IF;

    res.record := auth_id;
    res.thesaurus := authority.extract_thesaurus(marcxml);

    FOR acsaf IN SELECT * FROM authority.control_set_authority_field WHERE control_set = cset LOOP
        res.atag := acsaf.id;

        IF acsaf.heading_field IS NULL THEN
            tag_used := acsaf.tag;
            nfi_used := acsaf.nfi;
            joiner_text := COALESCE(acsaf.joiner, ' ');

            FOR tmp_xml IN SELECT UNNEST(XPATH('//*[@tag="'||tag_used||'"]', marcxml::XML)::TEXT[]) LOOP

                heading_text := COALESCE(
                    oils_xpath_string('//*[local-name()="subfield" and contains("'||acsaf.display_sf_list||'",@code)]', tmp_xml, joiner_text),
                    ''
                );

                IF nfi_used IS NOT NULL THEN

                    sort_text := SUBSTRING(
                        heading_text FROM
                        COALESCE(
                            NULLIF(
                                REGEXP_REPLACE(
                                    oils_xpath_string('//*[local-name()="datafield"]/@ind'||nfi_used, tmp_xml::TEXT),
                                    $$\D+$$,
                                    '',
                                    'g'
                                ),
                                ''
                            )::INT,
                            0
                        ) + 1
                    );

                ELSE
                    sort_text := heading_text;
                END IF;

                IF heading_text IS NOT NULL AND heading_text <> '' THEN
                    res.value := heading_text;
                    res.sort_value := public.naco_normalize(sort_text);
                    res.index_vector = to_tsvector('keyword'::regconfig, res.sort_value);
                    RETURN NEXT res;
                END IF;

            END LOOP;
        ELSE
            FOR heading_row IN SELECT * FROM authority.extract_headings(marcxml, ARRAY[acsaf.heading_field]) LOOP
                res.value := heading_row.heading;
                res.sort_value := heading_row.normalized_heading;
                res.index_vector = to_tsvector('keyword'::regconfig, res.sort_value);
                RETURN NEXT res;
            END LOOP;
        END IF;
    END LOOP;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL STABLE STRICT;

CREATE OR REPLACE FUNCTION metabib.remap_metarecord_for_bib(
    bib_id bigint,
    fp text,
    bib_is_deleted boolean DEFAULT false,
    retain_deleted boolean DEFAULT false
) RETURNS bigint AS $function$
DECLARE
    new_mapping     BOOL := TRUE;
    source_count    INT;
    old_mr          BIGINT;
    tmp_mr          metabib.metarecord%ROWTYPE;
    deleted_mrs     BIGINT[];
BEGIN

    -- We need to make sure we're not a deleted master record of an MR
    IF bib_is_deleted THEN
        IF NOT retain_deleted THEN -- Go away for any MR that we're master of, unless retained
            DELETE FROM metabib.metarecord_source_map WHERE source = bib_id;
        END IF;

        FOR old_mr IN SELECT id FROM metabib.metarecord WHERE master_record = bib_id LOOP

            -- Now, are there any more sources on this MR?
            SELECT COUNT(*) INTO source_count FROM metabib.metarecord_source_map WHERE metarecord = old_mr;

            IF source_count = 0 AND NOT retain_deleted THEN -- No other records
                deleted_mrs := ARRAY_APPEND(deleted_mrs, old_mr); -- Just in case...
                DELETE FROM metabib.metarecord WHERE id = old_mr;

            ELSE -- indeed there are. Update it with a null cache and recalcualated master record
                UPDATE  metabib.metarecord
                  SET   mods = NULL,
                        master_record = (SELECT id FROM biblio.record_entry WHERE fingerprint = fp AND NOT deleted ORDER BY quality DESC, id ASC LIMIT 1)
                  WHERE id = old_mr;
            END IF;
        END LOOP;

    ELSE -- insert or update

        FOR tmp_mr IN SELECT m.* FROM metabib.metarecord m JOIN metabib.metarecord_source_map s ON (s.metarecord = m.id) WHERE s.source = bib_id LOOP

            -- Find the first fingerprint-matching
            IF old_mr IS NULL AND fp = tmp_mr.fingerprint THEN
                old_mr := tmp_mr.id;
                new_mapping := FALSE;

            ELSE -- Our fingerprint changed ... maybe remove the old MR
                DELETE FROM metabib.metarecord_source_map WHERE metarecord = tmp_mr.id AND source = bib_id; -- remove the old source mapping
                SELECT COUNT(*) INTO source_count FROM metabib.metarecord_source_map WHERE metarecord = tmp_mr.id;
                IF source_count = 0 THEN -- No other records
                    deleted_mrs := ARRAY_APPEND(deleted_mrs, tmp_mr.id);
                    DELETE FROM metabib.metarecord WHERE id = tmp_mr.id;
                END IF;
            END IF;

        END LOOP;

        -- we found no suitable, preexisting MR based on old source maps
        IF old_mr IS NULL THEN
            SELECT id INTO old_mr FROM metabib.metarecord WHERE fingerprint = fp; -- is there one for our current fingerprint?

            IF old_mr IS NULL THEN -- nope, create one and grab its id
                INSERT INTO metabib.metarecord ( fingerprint, master_record ) VALUES ( fp, bib_id );
                SELECT id INTO old_mr FROM metabib.metarecord WHERE fingerprint = fp;

            ELSE -- indeed there is. update it with a null cache and recalcualated master record
                UPDATE  metabib.metarecord
                  SET   mods = NULL,
                        master_record = (SELECT id FROM biblio.record_entry WHERE fingerprint = fp AND NOT deleted ORDER BY quality DESC, id ASC LIMIT 1)
                  WHERE id = old_mr;
            END IF;

        ELSE -- there was one we already attached to, update its mods cache and master_record
            UPDATE  metabib.metarecord
              SET   mods = NULL,
                    master_record = (SELECT id FROM biblio.record_entry WHERE fingerprint = fp AND NOT deleted ORDER BY quality DESC, id ASC LIMIT 1)
              WHERE id = old_mr;
        END IF;

        IF new_mapping THEN
            INSERT INTO metabib.metarecord_source_map (metarecord, source) VALUES (old_mr, bib_id); -- new source mapping
        END IF;

    END IF;

    IF ARRAY_UPPER(deleted_mrs,1) > 0 THEN
        UPDATE action.hold_request SET target = old_mr WHERE target IN ( SELECT unnest(deleted_mrs) ) AND hold_type = 'M'; -- if we had to delete any MRs above, make sure their holds are moved
    END IF;

    RETURN old_mr;

END;
$function$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1315', :eg_version);

CREATE TABLE config.ui_staff_portal_page_entry_type (
    code        TEXT PRIMARY KEY,
    label       TEXT NOT NULL
);

INSERT INTO config.ui_staff_portal_page_entry_type (code, label)
VALUES
    ('link', oils_i18n_gettext('link', 'Link', 'cusppet', 'label')),
    ('menuitem', oils_i18n_gettext('menuitem', 'Menu Item', 'cusppet', 'label')),
    ('text', oils_i18n_gettext('text', 'Text and/or HTML', 'cusppet', 'label')),
    ('header', oils_i18n_gettext('header', 'Header', 'cusppet', 'label')),
    ('catalogsearch', oils_i18n_gettext('catalogsearch', 'Catalog Search Box', 'cusppet', 'label'));


CREATE TABLE config.ui_staff_portal_page_entry (
    id          SERIAL PRIMARY KEY,
    page_col    INTEGER NOT NULL,
    col_pos     INTEGER NOT NULL,
    entry_type  TEXT NOT NULL, -- REFERENCES config.ui_staff_portal_page_entry_type(code)
    label       TEXT,
    image_url   TEXT,
    target_url  TEXT,
    entry_text  TEXT,
    owner       INT NOT NULL -- REFERENCES actor.org_unit (id)
);

ALTER TABLE config.ui_staff_portal_page_entry ADD CONSTRAINT cusppe_entry_type_fkey
    FOREIGN KEY (entry_type) REFERENCES  config.ui_staff_portal_page_entry_type(code) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE config.ui_staff_portal_page_entry ADD CONSTRAINT cusppe_owner_fkey
    FOREIGN KEY (owner) REFERENCES  actor.org_unit(id) ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


SELECT evergreen.upgrade_deps_block_check('1316', :eg_version);

INSERT INTO config.ui_staff_portal_page_entry
    (id, page_col, col_pos, entry_type, label, image_url, target_url, owner)
VALUES
    ( 1, 1, 0, 'header',        oils_i18n_gettext( 1, 'Circulation and Patrons', 'cusppe', 'label'), NULL, NULL, 1)
,   ( 2, 1, 1, 'menuitem',      oils_i18n_gettext( 2, 'Check Out Items', 'cusppe', 'label'), '/images/portal/forward.png', '/eg/staff/circ/patron/bcsearch', 1)
,   ( 3, 1, 2, 'menuitem',      oils_i18n_gettext( 3, 'Check In Items', 'cusppe', 'label'), '/images/portal/back.png', '/eg/staff/circ/checkin/index', 1)
,   ( 4, 1, 3, 'menuitem',      oils_i18n_gettext( 4, 'Search For Patron By Name', 'cusppe', 'label'), '/images/portal/retreivepatron.png', '/eg/staff/circ/patron/search', 1)
,   ( 5, 2, 0, 'header',        oils_i18n_gettext( 5, 'Item Search and Cataloging', 'cusppe', 'label'), NULL, NULL, 1)
,   ( 6, 2, 1, 'catalogsearch', oils_i18n_gettext( 6, 'Search Catalog', 'cusppe', 'label'), NULL, NULL, 1)
,   ( 7, 2, 2, 'menuitem',      oils_i18n_gettext( 7, 'Record Buckets', 'cusppe', 'label'), '/images/portal/bucket.png', '/eg/staff/cat/bucket/record/', 1)
,   ( 8, 2, 3, 'menuitem',      oils_i18n_gettext( 8, 'Item Buckets', 'cusppe', 'label'), '/images/portal/bucket.png', '/eg/staff/cat/bucket/copy/', 1)
,   ( 9, 3, 0, 'header',        oils_i18n_gettext( 9, 'Administration', 'cusppe', 'label'), NULL, NULL, 1)
,   (10, 3, 1, 'link',          oils_i18n_gettext(10, 'Evergreen Documentation', 'cusppe', 'label'), '/images/portal/helpdesk.png', 'https://docs.evergreen-ils.org', 1)
,   (11, 3, 2, 'menuitem',      oils_i18n_gettext(11, 'Workstation Administration', 'cusppe', 'label'), '/images/portal/helpdesk.png', '/eg/staff/admin/workstation/index', 1)
,   (12, 3, 3, 'menuitem',      oils_i18n_gettext(12, 'Reports', 'cusppe', 'label'), '/images/portal/reports.png', '/eg/staff/reporter/legacy/main', 1)
;

SELECT setval('config.ui_staff_portal_page_entry_id_seq', 100);


INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.config.ui_staff_portal_page_entry', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.config.ui_staff_portal_page_entry',
        'Grid Config: admin.config.ui_staff_portal_page_entry',
        'cwst', 'label'
    )
);



SELECT evergreen.upgrade_deps_block_check('1317', :eg_version);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
( 636, 'ADMIN_STAFF_PORTAL_PAGE', oils_i18n_gettext( 636,
   'Update the staff client portal page', 'ppl', 'description' ))
;


-- check whether patch can be applied
SELECT evergreen.upgrade_deps_block_check('1318', :eg_version);

-- 950.data.seed-values.sql

INSERT INTO config.global_flag (name, value, enabled, label)
VALUES (
    'opac.cover_upload_compression',
    0,
    TRUE,
    oils_i18n_gettext(
        'opac.cover_upload_compression',
        'Cover image uploads are converted to PNG files with this compression, on a scale of 0 (no compression) to 9 (maximum compression), or -1 for the zlib default.',
        'cgf', 'label'
    )
);

INSERT INTO config.org_unit_setting_type (name, label, grp, description, datatype)
VALUES (
    'opac.cover_upload_max_file_size',
    oils_i18n_gettext('opac.cover_upload_max_file_size',
        'Maximum file size for uploaded cover image files (at time of upload, prior to rescaling).',
        'coust', 'label'),
    'opac',
    oils_i18n_gettext('opac.cover_upload_max_file_size',
        'The number of bytes to allow for a cover image upload.  If unset, defaults to 10737418240 (roughly 10GB).',
        'coust', 'description'),
    'integer'
);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 637, 'UPLOAD_COVER_IMAGE', oils_i18n_gettext(637,
    'Upload local cover images for added content.', 'ppl', 'description'))
;


SELECT evergreen.upgrade_deps_block_check('1319', :eg_version);

DO $SQL$
BEGIN
    
    PERFORM TRUE FROM config.usr_setting_type WHERE name = 'cat.copy.templates';

    IF NOT FOUND THEN -- no matching user setting

        PERFORM TRUE FROM config.workstation_setting_type WHERE name = 'cat.copy.templates';

        IF NOT FOUND THEN
            -- no matching workstation setting
            -- Migrate the existing user setting and its data to the new name.

            UPDATE config.usr_setting_type 
            SET name = 'cat.copy.templates' 
            WHERE name = 'webstaff.cat.copy.templates';

            UPDATE actor.usr_setting
            SET name = 'cat.copy.templates' 
            WHERE name = 'webstaff.cat.copy.templates';

        END IF;
    END IF;

END; 
$SQL$;



SELECT evergreen.upgrade_deps_block_check('1320', :eg_version); -- jboyer /  / 

ALTER TABLE reporter.template_folder ADD COLUMN simple_reporter BOOLEAN DEFAULT FALSE;
ALTER TABLE reporter.report_folder ADD COLUMN simple_reporter BOOLEAN DEFAULT FALSE;
ALTER TABLE reporter.output_folder ADD COLUMN simple_reporter BOOLEAN DEFAULT FALSE;

DROP INDEX reporter.rpt_template_folder_once_idx;
DROP INDEX reporter.rpt_report_folder_once_idx;
DROP INDEX reporter.rpt_output_folder_once_idx;

CREATE UNIQUE INDEX rpt_template_folder_once_idx ON reporter.template_folder (name,owner,simple_reporter) WHERE parent IS NULL;
CREATE UNIQUE INDEX rpt_report_folder_once_idx ON reporter.report_folder (name,owner,simple_reporter) WHERE parent IS NULL;
CREATE UNIQUE INDEX rpt_output_folder_once_idx ON reporter.output_folder (name,owner,simple_reporter) WHERE parent IS NULL;

-- Private "transform" to allow for simple report permissions verification
CREATE OR REPLACE FUNCTION reporter.intersect_user_perm_ou(context_ou BIGINT, staff_id BIGINT, perm_code TEXT)
RETURNS BOOLEAN AS $$
  SELECT CASE WHEN context_ou IN (SELECT * FROM permission.usr_has_perm_at_all(staff_id::INT, perm_code)) THEN TRUE ELSE FALSE END;
$$ LANGUAGE SQL;

-- Hey committer, make sure this id is good to go and also in 950.data.seed-values.sql
INSERT INTO permission.perm_list (id, code, description) VALUES
 ( 638, 'RUN_SIMPLE_REPORTS', oils_i18n_gettext(638,
    'Build and run simple reports', 'ppl', 'description'));


INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.reporter.simple.reports', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.reporter.simple.reports',
        'Grid Config: eg.grid.reporter.simple.reports',
        'cwst', 'label'
    )
), (
    'eg.grid.reporter.simple.outputs', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.reporter.simple.outputs',
        'Grid Config: eg.grid.reporter.simple.outputs',
        'cwst', 'label'
    )
);

-- new view parallel to reporter.currently_running
-- and reporter.overdue_reports
CREATE OR REPLACE VIEW reporter.completed_reports AS
  SELECT s.id AS run,
         r.id AS report,
         t.id AS template,
         t.owner AS template_owner,
         r.owner AS report_owner,
         s.runner AS runner,
         t.folder AS template_folder,
         r.folder AS report_folder,
         s.folder AS output_folder,
         r.name AS report_name,
         t.name AS template_name,
         s.start_time,
         s.run_time,
         s.complete_time,
         s.error_code,
         s.error_text
  FROM reporter.schedule s
    JOIN reporter.report r ON r.id = s.report
    JOIN reporter.template t ON t.id = r.template
  WHERE s.complete_time IS NOT NULL;



SELECT evergreen.upgrade_deps_block_check('1321', :eg_version);

CREATE TABLE asset.copy_inventory (
    id                          SERIAL                      PRIMARY KEY,
    inventory_workstation       INTEGER                     REFERENCES actor.workstation (id) DEFERRABLE INITIALLY DEFERRED,
    inventory_date              TIMESTAMP WITH TIME ZONE    NOT NULL DEFAULT NOW(),
    copy                        BIGINT                      NOT NULL
);
CREATE INDEX copy_inventory_copy_idx ON asset.copy_inventory (copy);
CREATE UNIQUE INDEX asset_copy_inventory_date_once_per_copy ON asset.copy_inventory (inventory_date, copy);

CREATE OR REPLACE FUNCTION evergreen.asset_copy_inventory_copy_inh_fkey() RETURNS TRIGGER AS $f$
BEGIN
        PERFORM 1 FROM asset.copy WHERE id = NEW.copy;
        IF NOT FOUND THEN
                RAISE foreign_key_violation USING MESSAGE = FORMAT(
                        $$Referenced asset.copy id not found, copy:%s$$, NEW.copy
                );
        END IF;
        RETURN NEW;
END;
$f$ LANGUAGE PLPGSQL VOLATILE COST 50;

CREATE CONSTRAINT TRIGGER inherit_asset_copy_inventory_copy_fkey
        AFTER UPDATE OR INSERT ON asset.copy_inventory
        DEFERRABLE FOR EACH ROW EXECUTE PROCEDURE evergreen.asset_copy_inventory_copy_inh_fkey();

CREATE OR REPLACE FUNCTION asset.copy_may_float_to_inventory_workstation() RETURNS TRIGGER AS $func$
DECLARE
    copy asset.copy%ROWTYPE;
    workstation actor.workstation%ROWTYPE;
BEGIN
    SELECT * INTO copy FROM asset.copy WHERE id = NEW.copy;
    IF FOUND THEN
        SELECT * INTO workstation FROM actor.workstation WHERE id = NEW.inventory_workstation;
        IF FOUND THEN
           IF copy.floating IS NULL THEN
              IF copy.circ_lib <> workstation.owning_lib THEN
                 RAISE EXCEPTION 'Inventory workstation owning lib (%) does not match copy circ lib (%).',
                       workstation.owning_lib, copy.circ_lib;
              END IF;
           ELSE
              IF NOT evergreen.can_float(copy.floating, copy.circ_lib, workstation.owning_lib) THEN
                 RAISE EXCEPTION 'Copy (%) cannot float to inventory workstation owning lib (%).',
                       copy.id, workstation.owning_lib;
              END IF;
           END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$func$ LANGUAGE PLPGSQL VOLATILE COST 50;

CREATE CONSTRAINT TRIGGER asset_copy_inventory_allowed_trig
        AFTER UPDATE OR INSERT ON asset.copy_inventory
        DEFERRABLE FOR EACH ROW EXECUTE PROCEDURE asset.copy_may_float_to_inventory_workstation();

INSERT INTO asset.copy_inventory
(inventory_workstation, inventory_date, copy)
SELECT DISTINCT ON (inventory_date, copy) inventory_workstation, inventory_date, copy
FROM asset.latest_inventory
JOIN asset.copy acp ON acp.id = latest_inventory.copy
JOIN actor.workstation ON workstation.id = latest_inventory.inventory_workstation
WHERE acp.circ_lib = workstation.owning_lib
UNION
SELECT DISTINCT ON (inventory_date, copy) inventory_workstation, inventory_date, copy
FROM asset.latest_inventory
JOIN asset.copy acp ON acp.id = latest_inventory.copy
JOIN actor.workstation ON workstation.id = latest_inventory.inventory_workstation
WHERE acp.circ_lib <> workstation.owning_lib
AND acp.floating IS NOT NULL
AND evergreen.can_float(acp.floating, acp.circ_lib, workstation.owning_lib)
ORDER by inventory_date;

DROP TABLE asset.latest_inventory;

CREATE VIEW asset.latest_inventory (id, inventory_workstation, inventory_date, copy) AS
SELECT DISTINCT ON (copy) id, inventory_workstation, inventory_date, copy
FROM asset.copy_inventory
ORDER BY copy, inventory_date DESC;

DROP FUNCTION evergreen.asset_latest_inventory_copy_inh_fkey();


SELECT evergreen.upgrade_deps_block_check('1322', :eg_version);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'opac.patron.custom_jquery', 'opac',
    oils_i18n_gettext('opac.patron.custom_jquery',
        'Custom jQuery for the OPAC',
        'coust', 'label'),
    oils_i18n_gettext('opac.patron.custom_jquery',
        'Custom jQuery for the OPAC',
        'coust', 'description'),
    'string', NULL);


SELECT evergreen.upgrade_deps_block_check('1323', :eg_version);

-- VIEWS for the oai service
CREATE SCHEMA oai;

-- The view presents a lean table with unique bre.tc-numbers for oai paging;
CREATE VIEW oai.biblio AS
  SELECT
    bre.id                             AS rec_id,
    bre.edit_date AT TIME ZONE 'UTC'   AS datestamp,
    bre.deleted                        AS deleted
  FROM
    biblio.record_entry bre
  ORDER BY
    bre.id;

-- The view presents a lean table with unique are.tc-numbers for oai paging;
CREATE VIEW oai.authority AS
  SELECT
    are.id                           AS rec_id,
    are.edit_date AT TIME ZONE 'UTC' AS datestamp,
    are.deleted                      AS deleted
  FROM
    authority.record_entry AS are
  ORDER BY
    are.id;

CREATE OR REPLACE function oai.bib_is_visible_at_org_by_copy(bib BIGINT, org INT) RETURNS BOOL AS $F$
WITH corgs AS (SELECT array_agg(id) AS list FROM actor.org_unit_descendants(org))
  SELECT EXISTS (SELECT 1 FROM asset.copy_vis_attr_cache, corgs WHERE vis_attr_vector @@ search.calculate_visibility_attribute_test('circ_lib', corgs.list)::query_int AND bib=record)
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE function oai.bib_is_visible_at_org_by_luri(bib BIGINT, org INT) RETURNS BOOL AS $F$
WITH lorgs AS(SELECT array_agg(id) AS list FROM actor.org_unit_ancestors(org))
  SELECT EXISTS (SELECT 1 FROM biblio.record_entry, lorgs WHERE vis_attr_vector @@ search.calculate_visibility_attribute_test('luri_org', lorgs.list)::query_int AND bib=id)
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE function oai.bib_is_visible_by_source(bib BIGINT, src TEXT) RETURNS BOOL AS $F$
  SELECT EXISTS (SELECT 1 FROM biblio.record_entry b JOIN config.bib_source s ON (b.source = s.id) WHERE transcendant AND s.source = src AND bib=b.id)
$F$ LANGUAGE SQL STABLE;

CREATE OR REPLACE function oai.auth_is_visible_by_axis(auth BIGINT, ax TEXT) RETURNS BOOL AS $F$
  SELECT EXISTS (SELECT 1 FROM authority.browse_axis_authority_field_map m JOIN authority.simple_heading r on (r.atag = m.field AND r.record = auth AND m.axis = ax))
$F$ LANGUAGE SQL STABLE;



SELECT evergreen.upgrade_deps_block_check('1324', :eg_version);

CREATE TABLE action_trigger.alternate_template (
      id               SERIAL,
      event_def        INTEGER REFERENCES action_trigger.event_definition(id) INITIALLY DEFERRED,
      template         TEXT,
      active           BOOLEAN DEFAULT TRUE,
      message_title    TEXT,
      message_template TEXT,
      locale           TEXT REFERENCES config.i18n_locale(code) INITIALLY DEFERRED,
      UNIQUE (event_def,locale)
);

ALTER TABLE actor.usr ADD COLUMN locale TEXT REFERENCES config.i18n_locale(code) INITIALLY DEFERRED;

ALTER TABLE action_trigger.event_output ADD COLUMN locale TEXT;


SELECT evergreen.upgrade_deps_block_check('1326', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.config.idl_field_doc', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.config.idl_field_doc',
        'Grid Config: admin.config.idl_field_doc',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1327', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.orgselect.show_combined_names', 'gui', 'bool',
    oils_i18n_gettext(
        'eg.orgselect.show_combined_names',
        'Library Selector Show Combined Names',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1328', :eg_version);

CREATE OR REPLACE FUNCTION asset.check_delete_copy_location(acpl_id INTEGER)
    RETURNS VOID AS $FUNK$
BEGIN
    PERFORM TRUE FROM asset.copy WHERE location = acpl_id AND NOT deleted LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Copy location % contains active copies and cannot be deleted', acpl_id;
    END IF;
END;
$FUNK$ LANGUAGE plpgsql;

DROP RULE protect_copy_location_delete ON asset.copy_location;

CREATE RULE protect_copy_location_delete AS
    ON DELETE TO asset.copy_location DO INSTEAD (
        SELECT asset.check_delete_copy_location(OLD.id);
        UPDATE asset.copy_location SET deleted = TRUE WHERE OLD.id = asset.copy_location.id;
        UPDATE acq.lineitem_detail SET location = NULL WHERE location = OLD.id;
        DELETE FROM asset.copy_location_order WHERE location = OLD.id;
        DELETE FROM asset.copy_location_group_map WHERE location = OLD.id;
        DELETE FROM config.circ_limit_set_copy_loc_map WHERE copy_loc = OLD.id;
    );



SELECT evergreen.upgrade_deps_block_check('1329', :eg_version);

CREATE TABLE config.openathens_uid_field (
    id      SERIAL  PRIMARY KEY,
    name    TEXT    NOT NULL
);

INSERT INTO config.openathens_uid_field
    (id, name)
VALUES
    (1,'id'),
    (2,'usrname')
;

SELECT SETVAL('config.openathens_uid_field_id_seq'::TEXT, 100);

CREATE TABLE config.openathens_name_field (
    id      SERIAL  PRIMARY KEY,
    name    TEXT    NOT NULL
);

INSERT INTO config.openathens_name_field
    (id, name)
VALUES
    (1,'id'),
    (2,'usrname'),
    (3,'fullname')
;

SELECT SETVAL('config.openathens_name_field_id_seq'::TEXT, 100);

CREATE TABLE config.openathens_identity (
    id                          SERIAL  PRIMARY KEY,
    active                      BOOL    NOT NULL DEFAULT true,
    org_unit                    INT     NOT NULL REFERENCES actor.org_unit (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    api_key                     TEXT    NOT NULL,
    connection_id               TEXT    NOT NULL,
    connection_uri              TEXT    NOT NULL,
    auto_signon_enabled         BOOL    NOT NULL DEFAULT true,
    auto_signout_enabled        BOOL    NOT NULL DEFAULT false,
    unique_identifier           INT     NOT NULL REFERENCES config.openathens_uid_field (id) DEFAULT 1,
    display_name                INT     NOT NULL REFERENCES config.openathens_name_field (id) DEFAULT 1,
    release_prefix              BOOL    NOT NULL DEFAULT false,
    release_first_given_name    BOOL    NOT NULL DEFAULT false,
    release_second_given_name   BOOL    NOT NULL DEFAULT false,
    release_family_name         BOOL    NOT NULL DEFAULT false,
    release_suffix              BOOL    NOT NULL DEFAULT false,
    release_email               BOOL    NOT NULL DEFAULT false,
    release_home_ou             BOOL    NOT NULL DEFAULT false,
    release_barcode             BOOL    NOT NULL DEFAULT false
);


INSERT INTO permission.perm_list ( id, code, description) VALUES 
  ( 639, 'ADMIN_OPENATHENS', oils_i18n_gettext(639,
     'Allow a user to administer OpenAthens authentication service', 'ppl', 'description'));



SELECT evergreen.upgrade_deps_block_check('1330', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.negative_balances', 'gui', 'object', 
    oils_i18n_gettext(
        'eg.grid.admin.local.negative_balances',
        'Patrons With Negative Balances Grid Settings',
        'cwst', 'label'
    )
), (
    'eg.orgselect.admin.local.negative_balances', 'gui', 'integer',
    oils_i18n_gettext(
        'eg.orgselect.admin.local.negative_balances',
        'Default org unit for patron negative balances interface',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1331', :eg_version);

INSERT into config.org_unit_setting_type
    (name, datatype, grp, label, description)
VALUES (
    'ui.staff.traditional_catalog.enabled', 'bool', 'gui',
    oils_i18n_gettext(
        'ui.staff.traditional_catalog.enabled',
        'GUI: Enable Traditional Staff Catalog',
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'ui.staff.traditional_catalog.enabled',
        'Display an entry point in the browser client for the ' ||
        'traditional staff catalog.',
        'coust', 'description'
    )
);




SELECT evergreen.upgrade_deps_block_check('1332', :eg_version);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES

( 'acq.default_owning_lib_for_auto_lids_strategy', 'acq',
    oils_i18n_gettext('acq.default_owning_lib_for_auto_lids_strategy',
        'How to set default owning library for auto-created line item items',
        'coust', 'label'),
    oils_i18n_gettext('acq.default_owning_lib_for_auto_lids_strategy',
        'Stategy to use to set default owning library to set when line item items are auto-created because the provider''s default copy count has been set. Valid values are "workstation" to use the workstation library, "blank" to leave it blank, and "use_setting" to use the "Default owning library for auto-created line item items" setting. If not set, the workstation library will be used.',
        'coust', 'description'),
    'string', null)
,( 'acq.default_owning_lib_for_auto_lids', 'acq',
    oils_i18n_gettext('acq.default_owning_lib_for_auto_lids',
        'Default owning library for auto-created line item items',
        'coust', 'label'),
    oils_i18n_gettext('acq.default_owning_lib_for_auto_lids',
        'The default owning library to set when line item items are auto-created because the provider''s default copy count has been set. This applies if the "How to set default owning library for auto-created line item items" setting is set to "use_setting".',
        'coust', 'description'),
    'link', 'aou')
;


SELECT evergreen.upgrade_deps_block_check('1333', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.acq.lineitem.history', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.lineitem.history',
        'Grid Config: Acq Lineitem History',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.po.history', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.po.history',
        'Grid Config: Acq PO History',
        'cwst', 'label'
    )
), (
    'eg.grid.acq.po.edi_messages', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.acq.po.edi_messages',
        'Grid Config: Acq PO EDI Messages',
        'cwst', 'label'
    )
), (
    'acq.lineitem.page_size', 'gui', 'integer',
    oils_i18n_gettext(
        'acq.lineitem.page_size',
        'ACQ Lineitem List Page Size',
        'cwst', 'label'
    )
), (
    'ui.staff.angular_acq_search.enabled', 'gui', 'bool',
    oils_i18n_gettext(
        'ui.staff.angular_acq_search.enabled',
        'Enable Experimental ACQ Selection/Purchase Search Interface Links',
        'cwst', 'label'
    )
);

INSERT INTO config.print_template
    (id, name, label, owner, active, locale, template)
VALUES (
    5, 'lineitem_worksheet', 'Lineitem Worksheet', 1, TRUE, 'en-US',
$TEMPLATE$
[%- 
  USE money=format('%.2f');
  USE date;
  SET li = template_data.lineitem;
  SET title = '';
  SET author = '';
  FOREACH attr IN li.attributes;
    IF attr.attr_type == 'lineitem_marc_attr_definition';
      IF attr.attr_name == 'title';
        title = attr.attr_value;
      ELSIF attr.attr_name == 'author';
        author = attr.attr_value;
      END;
    END;
  END;
-%]

<div class="wrapper">
    <div class="summary" style='font-size:110%; font-weight:bold;'>
        <div>Title: [% title.substr(0, 80) %][% IF title.length > 80 %]...[% END %]</div>
        <div>Author: [% author %]</div>
        <div>Item Count: [% li.lineitem_details.size %]</div>
        <div>Lineitem ID: [% li.id %]</div>
        <div>PO # : [% li.purchase_order %]</div>
        <div>Est. Price: [% money(li.estimated_unit_price) %]</div>
        <div>Open Holds: [% template_data.hold_count %]</div>
        [% IF li.cancel_reason.label %]
        <div>[% li.cancel_reason.label %]</div>
        [% END %]

        [% IF li.distribution_formulas.size > 0 %]
            [% SET forms = [] %]
            [% FOREACH form IN li.distribution_formulas; forms.push(form.formula.name); END %]
            <div>Distribution Formulas: [% forms.join(',') %]</div>
        [% END %]

        [% IF li.lineitem_notes.size > 0 %]
            Lineitem Notes:
            <ul>
                [%- FOR note IN li.lineitem_notes -%]
                    <li>
                    [% IF note.alert_text %]
                        [% note.alert_text.code -%] 
                        [% IF note.value -%]
                            : [% note.value %]
                        [% END %]
                    [% ELSE %]
                        [% note.value -%] 
                    [% END %]
                    </li>
                [% END %]
            </ul>
        [% END %]
    </div>
    <br/>
    <table>
        <thead>
            <tr>
                <th>Branch</th>
                <th>Barcode</th>
                <th>Call Number</th>
                <th>Fund</th>
                <th>Shelving Location</th>
                <th>Recd.</th>
                <th>Notes</th>
                <th>Delayed / Canceled</th>
            </tr>
        </thead>
        <tbody>
        <!-- set detail.owning_lib from fm object to org name -->
        [% FOREACH detail IN li.lineitem_details %]
            [% detail.owning_lib = detail.owning_lib.shortname %]
        [% END %]

        [% FOREACH detail IN li.lineitem_details.sort('owning_lib') %]
            [% 
                IF detail.eg_copy_id;
                    SET copy = detail.eg_copy_id;
                    SET cn_label = copy.call_number.label;
                ELSE; 
                    SET copy = detail; 
                    SET cn_label = detail.cn_label;
                END 
            %]
            <tr>
                <!-- acq.lineitem_detail.id = [%- detail.id -%] -->
                <td style='padding:5px;'>[% detail.owning_lib %]</td>
                <td style='padding:5px;'>[% IF copy.barcode   %]<span class="barcode"  >[% detail.barcode   %]</span>[% END %]</td>
                <td style='padding:5px;'>[% IF cn_label %]<span class="cn_label" >[% cn_label  %]</span>[% END %]</td>
                <td style='padding:5px;'>[% IF detail.fund %]<span class="fund">[% detail.fund.code %] ([% detail.fund.year %])</span>[% END %]</td>
                <td style='padding:5px;'>[% copy.location.name %]</td>
                <td style='padding:5px;'>[% IF detail.recv_time %]<span class="recv_time">[% date.format(helpers.format_date(detail.recv_time, staff_org_timezone), '%x %r', locale) %]</span>[% END %]</td>
                <td style='padding:5px;'>[% detail.note %]</td>
                <td style='padding:5px;'>[% detail.cancel_reason.label %]</td>
            </tr>
        [% END %]
        </tbody>
    </table>
</div>
$TEMPLATE$
);

INSERT INTO config.print_template
    (id, name, label, owner, active, locale, template)
VALUES (6, 'purchase_order', 'Purchase Order', 1, TRUE, 'en-US', 
$TEMPLATE$

[%- 
  USE date;
  USE String;
  USE money=format('%.2f');
  SET po = template_data.po;

  # find a lineitem attribute by name and optional type
  BLOCK get_li_attr;
    FOR attr IN li.attributes;
      IF attr.attr_name == attr_name;
        IF !attr_type OR attr_type == attr.attr_type;
          attr.attr_value;
          LAST;
        END;
      END;
    END;
  END;

  BLOCK get_li_order_attr_value;
    FOR attr IN li.attributes;
      IF attr.order_ident == 't';
        attr.attr_value;
        LAST;
      END;
    END;
  END;
-%]

<table style="width:100%">
  <thead>
    <tr>
      <th>PO#</th>
      <th>Line#</th>
      <th>ISBN / Item # / Charge Type</th>
      <th>Title</th>
      <th>Author</th>
      <th>Pub Info</th>
      <th>Quantity</th>
      <th>Unit Price</th>
      <th>Line Total</th>
    </tr>
  </thead>
  <tbody>
[% 
  SET subtotal = 0;
  FOR li IN po.lineitems;

    SET idval = '';
    IF vendnum != '';
      idval = PROCESS get_li_attr attr_name = 'vendor_num';
    END;
    IF !idval;
      idval = PROCESS get_li_order_attr_value;
    END;
-%]
    <tr>
      <td>[% po.id %]</td>
      <td>[% li.id %]</td>
      <td>[% idval %]</td>
      <td>[% PROCESS get_li_attr attr_name = 'title' %]</td>
      <td>[% PROCESS get_li_attr attr_name = 'author' %]</td>
      <td>
        <div>
          [% PROCESS get_li_attr attr_name = 'publisher' %], 
          [% PROCESS get_li_attr attr_name = 'pubdate' %]
        </div>
        <div>Edition: [% PROCESS get_li_attr attr_name = 'edition' %]</div>
      </td>
      [%- 
        SET count = li.lineitem_details.size;
        SET price = li.estimated_unit_price;
        SET itotal = (price * count);
      %]
      <td>[% count %]</td>
      <td>[% money(price) %]</td>
      <td>[% money(litotal) %]</td>
    </tr>
  [% END %]

  </tbody>
</table>



$TEMPLATE$
);





SELECT evergreen.upgrade_deps_block_check('1334', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.acq.picklist.upload.templates','acq','object',
    oils_i18n_gettext(
        'eg.acq.picklist.upload.templates',
        'Acq Picklist Uploader Templates',
        'cwst','label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1335', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'acq.lineitem.sort_order', 'gui', 'integer',
    oils_i18n_gettext(
        'acq.lineitem.sort_order',
        'ACQ Lineitem List Sort Order',
        'cwst', 'label'
    )
);

INSERT INTO config.org_unit_setting_type (name, grp, datatype, label)
VALUES (
    'ui.staff.acq.show_deprecated_links', 'gui', 'bool',
    oils_i18n_gettext(
        'ui.staff.acq.show_deprecated_links',
        'Display Links to Deprecated Acquisitions Interfaces',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1336', :eg_version);

INSERT INTO config.workstation_setting_type (name, grp, datatype, label) 
VALUES (
    'eg.grid.admin.actor.org_unit_settings', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.actor.org_unit_settings',
        'Grid Config: admin.actor.org_unit_settings',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1337', :eg_version);

INSERT into config.org_unit_setting_type
( name, grp, label, description, datatype, fm_class ) VALUES
( 'cat.require_call_number_labels', 'cat',
  oils_i18n_gettext('cat.require_call_number_labels',
    'Require call number labels in Copy Editor',
    'coust', 'label'),
  oils_i18n_gettext('cat.require_call_number_labels',
    'Define whether Copy Editor requires Call Number labels',
    'coust', 'description'),
  'bool', null);

INSERT INTO actor.org_unit_setting (org_unit, name, value) VALUES
  (1, 'cat.require_call_number_labels', 'true');

-- remove invalid search attribute Item Type from LC Z39.50 target


SELECT evergreen.upgrade_deps_block_check('1338', :eg_version);

DELETE FROM config.z3950_attr WHERE source = 'loc' AND code = 1001;


SELECT evergreen.upgrade_deps_block_check('1339', :eg_version);

ALTER TABLE asset.course_module_course_materials
    ADD COLUMN original_circ_lib INT REFERENCES actor.org_unit (id);


SELECT evergreen.upgrade_deps_block_check('1340', :eg_version);

-- INSERT-only table that catches dictionary updates to be reconciled
CREATE UNLOGGED TABLE search.symspell_dictionary_updates (
    transaction_id          BIGINT,
    keyword_count           INT     NOT NULL DEFAULT 0,
    title_count             INT     NOT NULL DEFAULT 0,
    author_count            INT     NOT NULL DEFAULT 0,
    subject_count           INT     NOT NULL DEFAULT 0,
    series_count            INT     NOT NULL DEFAULT 0,
    identifier_count        INT     NOT NULL DEFAULT 0,

    prefix_key              TEXT    NOT NULL,

    keyword_suggestions     TEXT[],
    title_suggestions       TEXT[],
    author_suggestions      TEXT[],
    subject_suggestions     TEXT[],
    series_suggestions      TEXT[],
    identifier_suggestions  TEXT[]
);
CREATE INDEX symspell_dictionary_updates_tid_idx ON search.symspell_dictionary_updates (transaction_id);

-- Function that collects this transactions additions to the unlogged update table
CREATE OR REPLACE FUNCTION search.symspell_dictionary_reify () RETURNS SETOF search.symspell_dictionary AS $f$
 WITH new_rows AS (
    DELETE FROM search.symspell_dictionary_updates WHERE transaction_id = txid_current() RETURNING *
 ), computed_rows AS ( -- this collapses the rows deleted into the format we need for UPSERT
    SELECT  SUM(keyword_count)    AS keyword_count,
            SUM(title_count)      AS title_count,
            SUM(author_count)     AS author_count,
            SUM(subject_count)    AS subject_count,
            SUM(series_count)     AS series_count,
            SUM(identifier_count) AS identifier_count,

            prefix_key,

            ARRAY_REMOVE(ARRAY_AGG(DISTINCT keyword_suggestions[1]), NULL)    AS keyword_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT title_suggestions[1]), NULL)      AS title_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT author_suggestions[1]), NULL)     AS author_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT subject_suggestions[1]), NULL)    AS subject_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT series_suggestions[1]), NULL)     AS series_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT identifier_suggestions[1]), NULL) AS identifier_suggestions
      FROM  new_rows
      GROUP BY prefix_key
 )
 INSERT INTO search.symspell_dictionary AS d SELECT * FROM computed_rows
 ON CONFLICT (prefix_key) DO UPDATE SET
    keyword_count = GREATEST(0, d.keyword_count + EXCLUDED.keyword_count),
    keyword_suggestions = evergreen.text_array_merge_unique(EXCLUDED.keyword_suggestions,d.keyword_suggestions),

    title_count = GREATEST(0, d.title_count + EXCLUDED.title_count),
    title_suggestions = evergreen.text_array_merge_unique(EXCLUDED.title_suggestions,d.title_suggestions),

    author_count = GREATEST(0, d.author_count + EXCLUDED.author_count),
    author_suggestions = evergreen.text_array_merge_unique(EXCLUDED.author_suggestions,d.author_suggestions),

    subject_count = GREATEST(0, d.subject_count + EXCLUDED.subject_count),
    subject_suggestions = evergreen.text_array_merge_unique(EXCLUDED.subject_suggestions,d.subject_suggestions),

    series_count = GREATEST(0, d.series_count + EXCLUDED.series_count),
    series_suggestions = evergreen.text_array_merge_unique(EXCLUDED.series_suggestions,d.series_suggestions),

    identifier_count = GREATEST(0, d.identifier_count + EXCLUDED.identifier_count),
    identifier_suggestions = evergreen.text_array_merge_unique(EXCLUDED.identifier_suggestions,d.identifier_suggestions)
 RETURNING *;
$f$ LANGUAGE SQL;

-- simplified metabib.*_field_entry trigger that stages updates for reification in one go
CREATE OR REPLACE FUNCTION search.symspell_maintain_entries () RETURNS TRIGGER AS $f$
DECLARE
    search_class    TEXT;
    new_value       TEXT := NULL;
    old_value       TEXT := NULL;
BEGIN
    search_class := COALESCE(TG_ARGV[0], SPLIT_PART(TG_TABLE_NAME,'_',1));

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_value := NEW.value;
    END IF;

    IF TG_OP IN ('DELETE', 'UPDATE') THEN
        old_value := OLD.value;
    END IF;

    IF new_value = old_value THEN
        -- same, move along
    ELSE
        INSERT INTO search.symspell_dictionary_updates
            SELECT  txid_current(), *
              FROM  search.symspell_build_entries(
                        new_value,
                        search_class,
                        old_value
                    );
    END IF;

    RETURN NULL; -- always fired AFTER
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries(
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE,
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE,
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                -- RAISE NOTICE 'Emptying out %', fclass.name;
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id;
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

    -- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN
            -- A caveat about this SELECT: this should take care of replacing
            -- old mbe rows when data changes, but not if normalization (by
            -- which I mean specifically the output of
            -- evergreen.oils_tsearch2()) changes.  It may or may not be
            -- expensive to add a comparison of index_vector to index_vector
            -- to the WHERE clause below.

            CONTINUE WHEN ind_data.sort_value IS NULL;

            value_prepped := metabib.browse_normalize(ind_data.value, ind_data.field);
            IF ind_data.browse_nocase THEN
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE evergreen.lowercase(value) = evergreen.lowercase(value_prepped) AND sort_value = ind_data.sort_value
                    ORDER BY sort_value, value LIMIT 1; -- gotta pick something, I guess
            ELSE
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE value = value_prepped AND sort_value = ind_data.sort_value;
            END IF;

            IF FOUND THEN
                mbe_id := mbe_row.id;
            ELSE
                INSERT INTO metabib.browse_entry
                    ( value, sort_value ) VALUES
                    ( value_prepped, ind_data.sort_value );

                mbe_id := CURRVAL('metabib.browse_entry_id_seq'::REGCLASS);
            END IF;

            INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
                VALUES (mbe_id, ind_data.field, ind_data.source, ind_data.authority);
        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
        PERFORM search.symspell_dictionary_reify();
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;



SELECT evergreen.upgrade_deps_block_check('1341', :eg_version);

CREATE OR REPLACE FUNCTION search.disable_symspell_reification () RETURNS VOID AS $f$
    INSERT INTO config.internal_flag (name,enabled)
      VALUES ('ingest.disable_symspell_reification',TRUE)
    ON CONFLICT (name) DO UPDATE SET enabled = TRUE;
$f$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION search.enable_symspell_reification () RETURNS VOID AS $f$
    UPDATE config.internal_flag SET enabled = FALSE WHERE name = 'ingest.disable_symspell_reification';
$f$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION search.symspell_dictionary_full_reify () RETURNS SETOF search.symspell_dictionary AS $f$
 WITH new_rows AS (
    DELETE FROM search.symspell_dictionary_updates RETURNING *
 ), computed_rows AS ( -- this collapses the rows deleted into the format we need for UPSERT
    SELECT  SUM(keyword_count)    AS keyword_count,
            SUM(title_count)      AS title_count,
            SUM(author_count)     AS author_count,
            SUM(subject_count)    AS subject_count,
            SUM(series_count)     AS series_count,
            SUM(identifier_count) AS identifier_count,

            prefix_key,

            ARRAY_REMOVE(ARRAY_AGG(DISTINCT keyword_suggestions[1]), NULL)    AS keyword_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT title_suggestions[1]), NULL)      AS title_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT author_suggestions[1]), NULL)     AS author_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT subject_suggestions[1]), NULL)    AS subject_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT series_suggestions[1]), NULL)     AS series_suggestions,
            ARRAY_REMOVE(ARRAY_AGG(DISTINCT identifier_suggestions[1]), NULL) AS identifier_suggestions
      FROM  new_rows
      GROUP BY prefix_key
 )
 INSERT INTO search.symspell_dictionary AS d SELECT * FROM computed_rows
 ON CONFLICT (prefix_key) DO UPDATE SET
    keyword_count = GREATEST(0, d.keyword_count + EXCLUDED.keyword_count),
    keyword_suggestions = evergreen.text_array_merge_unique(EXCLUDED.keyword_suggestions,d.keyword_suggestions),

    title_count = GREATEST(0, d.title_count + EXCLUDED.title_count),
    title_suggestions = evergreen.text_array_merge_unique(EXCLUDED.title_suggestions,d.title_suggestions),

    author_count = GREATEST(0, d.author_count + EXCLUDED.author_count),
    author_suggestions = evergreen.text_array_merge_unique(EXCLUDED.author_suggestions,d.author_suggestions),

    subject_count = GREATEST(0, d.subject_count + EXCLUDED.subject_count),
    subject_suggestions = evergreen.text_array_merge_unique(EXCLUDED.subject_suggestions,d.subject_suggestions),

    series_count = GREATEST(0, d.series_count + EXCLUDED.series_count),
    series_suggestions = evergreen.text_array_merge_unique(EXCLUDED.series_suggestions,d.series_suggestions),

    identifier_count = GREATEST(0, d.identifier_count + EXCLUDED.identifier_count),
    identifier_suggestions = evergreen.text_array_merge_unique(EXCLUDED.identifier_suggestions,d.identifier_suggestions)
 RETURNING *;
$f$ LANGUAGE SQL;

-- Updated again to check for delayed symspell reification
CREATE OR REPLACE FUNCTION metabib.reingest_metabib_field_entries(
    bib_id BIGINT,
    skip_facet BOOL DEFAULT FALSE,
    skip_display BOOL DEFAULT FALSE,
    skip_browse BOOL DEFAULT FALSE,
    skip_search BOOL DEFAULT FALSE,
    only_fields INT[] DEFAULT '{}'::INT[]
) RETURNS VOID AS $func$
DECLARE
    fclass          RECORD;
    ind_data        metabib.field_entry_template%ROWTYPE;
    mbe_row         metabib.browse_entry%ROWTYPE;
    mbe_id          BIGINT;
    b_skip_facet    BOOL;
    b_skip_display    BOOL;
    b_skip_browse   BOOL;
    b_skip_search   BOOL;
    value_prepped   TEXT;
    field_list      INT[] := only_fields;
    field_types     TEXT[] := '{}'::TEXT[];
BEGIN

    IF field_list = '{}'::INT[] THEN
        SELECT ARRAY_AGG(id) INTO field_list FROM config.metabib_field;
    END IF;

    SELECT COALESCE(NULLIF(skip_facet, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_facet_indexing' AND enabled)) INTO b_skip_facet;
    SELECT COALESCE(NULLIF(skip_display, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_display_indexing' AND enabled)) INTO b_skip_display;
    SELECT COALESCE(NULLIF(skip_browse, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_browse_indexing' AND enabled)) INTO b_skip_browse;
    SELECT COALESCE(NULLIF(skip_search, FALSE), EXISTS (SELECT enabled FROM config.internal_flag WHERE name =  'ingest.skip_search_indexing' AND enabled)) INTO b_skip_search;

    IF NOT b_skip_facet THEN field_types := field_types || '{facet}'; END IF;
    IF NOT b_skip_display THEN field_types := field_types || '{display}'; END IF;
    IF NOT b_skip_browse THEN field_types := field_types || '{browse}'; END IF;
    IF NOT b_skip_search THEN field_types := field_types || '{search}'; END IF;

    PERFORM * FROM config.internal_flag WHERE name = 'ingest.assume_inserts_only' AND enabled;
    IF NOT FOUND THEN
        IF NOT b_skip_search THEN
            FOR fclass IN SELECT * FROM config.metabib_class LOOP
                -- RAISE NOTICE 'Emptying out %', fclass.name;
                EXECUTE $$DELETE FROM metabib.$$ || fclass.name || $$_field_entry WHERE source = $$ || bib_id;
            END LOOP;
        END IF;
        IF NOT b_skip_facet THEN
            DELETE FROM metabib.facet_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_display THEN
            DELETE FROM metabib.display_entry WHERE source = bib_id;
        END IF;
        IF NOT b_skip_browse THEN
            DELETE FROM metabib.browse_entry_def_map WHERE source = bib_id;
        END IF;
    END IF;

    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( bib_id, ' ', field_types, field_list ) LOOP

    -- don't store what has been normalized away
        CONTINUE WHEN ind_data.value IS NULL;

        IF ind_data.field < 0 THEN
            ind_data.field = -1 * ind_data.field;
        END IF;

        IF ind_data.facet_field AND NOT b_skip_facet THEN
            INSERT INTO metabib.facet_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;

        IF ind_data.display_field AND NOT b_skip_display THEN
            INSERT INTO metabib.display_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;


        IF ind_data.browse_field AND NOT b_skip_browse THEN
            -- A caveat about this SELECT: this should take care of replacing
            -- old mbe rows when data changes, but not if normalization (by
            -- which I mean specifically the output of
            -- evergreen.oils_tsearch2()) changes.  It may or may not be
            -- expensive to add a comparison of index_vector to index_vector
            -- to the WHERE clause below.

            CONTINUE WHEN ind_data.sort_value IS NULL;

            value_prepped := metabib.browse_normalize(ind_data.value, ind_data.field);
            IF ind_data.browse_nocase THEN
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE evergreen.lowercase(value) = evergreen.lowercase(value_prepped) AND sort_value = ind_data.sort_value
                    ORDER BY sort_value, value LIMIT 1; -- gotta pick something, I guess
            ELSE
                SELECT INTO mbe_row * FROM metabib.browse_entry
                    WHERE value = value_prepped AND sort_value = ind_data.sort_value;
            END IF;

            IF FOUND THEN
                mbe_id := mbe_row.id;
            ELSE
                INSERT INTO metabib.browse_entry
                    ( value, sort_value ) VALUES
                    ( value_prepped, ind_data.sort_value );

                mbe_id := CURRVAL('metabib.browse_entry_id_seq'::REGCLASS);
            END IF;

            INSERT INTO metabib.browse_entry_def_map (entry, def, source, authority)
                VALUES (mbe_id, ind_data.field, ind_data.source, ind_data.authority);
        END IF;

        IF ind_data.search_field AND NOT b_skip_search THEN
            -- Avoid inserting duplicate rows
            EXECUTE 'SELECT 1 FROM metabib.' || ind_data.field_class ||
                '_field_entry WHERE field = $1 AND source = $2 AND value = $3'
                INTO mbe_id USING ind_data.field, ind_data.source, ind_data.value;
                -- RAISE NOTICE 'Search for an already matching row returned %', mbe_id;
            IF mbe_id IS NULL THEN
                EXECUTE $$
                INSERT INTO metabib.$$ || ind_data.field_class || $$_field_entry (field, source, value)
                    VALUES ($$ ||
                        quote_literal(ind_data.field) || $$, $$ ||
                        quote_literal(ind_data.source) || $$, $$ ||
                        quote_literal(ind_data.value) ||
                    $$);$$;
            END IF;
        END IF;

    END LOOP;

    IF NOT b_skip_search THEN
        PERFORM metabib.update_combined_index_vectors(bib_id);
        PERFORM * FROM config.internal_flag WHERE name = 'ingest.disable_symspell_reification' AND enabled;
        IF NOT FOUND THEN
            PERFORM search.symspell_dictionary_reify();
        END IF;
    END IF;

    RETURN;
END;
$func$ LANGUAGE PLPGSQL;



SELECT evergreen.upgrade_deps_block_check('1342', :eg_version);

INSERT INTO config.org_unit_setting_type
    (name, label, datatype, description, grp, update_perm, view_perm) 
VALUES (
    'circ.permit_renew_when_exceeds_fines',
    oils_i18n_gettext(
        'circ.permit_renew_when_exceeds_fines',
        'Permit renewals when patron exceeds max fine threshold',
        'coust',
        'label'
    ),
    'bool',
    oils_i18n_gettext(
        'circ.permit_renew_when_exceeds_fines',
        'Permit renewals even when the patron exceeds the maximum fine threshold',
        'coust',
        'description'
    ),
    'opac',
    93,
    NULL
);

CREATE OR REPLACE FUNCTION action.item_user_circ_test( circ_ou INT, match_item BIGINT, match_user INT, renewal BOOL ) RETURNS SETOF action.circ_matrix_test_result AS $func$
DECLARE
    user_object             actor.usr%ROWTYPE;
    standing_penalty        config.standing_penalty%ROWTYPE;
    item_object             asset.copy%ROWTYPE;
    item_status_object      config.copy_status%ROWTYPE;
    item_location_object    asset.copy_location%ROWTYPE;
    result                  action.circ_matrix_test_result;
    circ_test               action.found_circ_matrix_matchpoint;
    circ_matchpoint         config.circ_matrix_matchpoint%ROWTYPE;
    circ_limit_set          config.circ_limit_set%ROWTYPE;
    hold_ratio              action.hold_stats%ROWTYPE;
    penalty_type            TEXT;
    items_out               INT;
    context_org_list        INT[];
    permit_renew            TEXT;
    done                    BOOL := FALSE;
BEGIN
    -- Assume success unless we hit a failure condition
    result.success := TRUE;

    -- Need user info to look up matchpoints
    SELECT INTO user_object * FROM actor.usr WHERE id = match_user AND NOT deleted;

    -- (Insta)Fail if we couldn't find the user
    IF user_object.id IS NULL THEN
        result.fail_part := 'no_user';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    -- Need item info to look up matchpoints
    SELECT INTO item_object * FROM asset.copy WHERE id = match_item AND NOT deleted;

    -- (Insta)Fail if we couldn't find the item 
    IF item_object.id IS NULL THEN
        result.fail_part := 'no_item';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    SELECT INTO circ_test * FROM action.find_circ_matrix_matchpoint(circ_ou, item_object, user_object, renewal);

    circ_matchpoint             := circ_test.matchpoint;
    result.matchpoint           := circ_matchpoint.id;
    result.circulate            := circ_matchpoint.circulate;
    result.duration_rule        := circ_matchpoint.duration_rule;
    result.recurring_fine_rule  := circ_matchpoint.recurring_fine_rule;
    result.max_fine_rule        := circ_matchpoint.max_fine_rule;
    result.hard_due_date        := circ_matchpoint.hard_due_date;
    result.renewals             := circ_matchpoint.renewals;
    result.grace_period         := circ_matchpoint.grace_period;
    result.buildrows            := circ_test.buildrows;

    -- (Insta)Fail if we couldn't find a matchpoint
    IF circ_test.success = false THEN
        result.fail_part := 'no_matchpoint';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
        RETURN;
    END IF;

    -- All failures before this point are non-recoverable
    -- Below this point are possibly overridable failures

    -- Fail if the user is barred
    IF user_object.barred IS TRUE THEN
        result.fail_part := 'actor.usr.barred';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate
    IF item_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item isn't in a circulateable status on a non-renewal
    IF NOT renewal AND item_object.status NOT IN ( 0, 7, 8 ) THEN 
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    -- Alternately, fail if the item isn't checked out on a renewal
    ELSIF renewal AND item_object.status <> 1 THEN
        result.fail_part := 'asset.copy.status';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the item can't circulate because of the shelving location
    SELECT INTO item_location_object * FROM asset.copy_location WHERE id = item_object.location;
    IF item_location_object.circulate IS FALSE THEN
        result.fail_part := 'asset.copy_location.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Use Circ OU for penalties and such
    SELECT INTO context_org_list ARRAY_AGG(id) FROM actor.org_unit_full_path( circ_ou );

    IF renewal THEN
        penalty_type = '%RENEW%';
    ELSE
        penalty_type = '%CIRC%';
    END IF;

    FOR standing_penalty IN
        SELECT  DISTINCT csp.*
          FROM  actor.usr_standing_penalty usp
                JOIN config.standing_penalty csp ON (csp.id = usp.standing_penalty)
          WHERE usr = match_user
                AND usp.org_unit IN ( SELECT * FROM unnest(context_org_list) )
                AND (usp.stop_date IS NULL or usp.stop_date > NOW())
                AND csp.block_list LIKE penalty_type LOOP

        -- override PATRON_EXCEEDS_FINES penalty for renewals based on org setting
        IF renewal AND standing_penalty.name = 'PATRON_EXCEEDS_FINES' THEN
            SELECT INTO permit_renew value FROM actor.org_unit_ancestor_setting('circ.permit_renew_when_exceeds_fines', circ_ou);
            IF permit_renew IS NOT NULL AND permit_renew ILIKE 'true' THEN
                CONTINUE;
            END IF;
        END IF;

        result.fail_part := standing_penalty.name;
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END LOOP;

    -- Fail if the test is set to hard non-circulating
    IF circ_matchpoint.circulate IS FALSE THEN
        result.fail_part := 'config.circ_matrix_test.circulate';
        result.success := FALSE;
        done := TRUE;
        RETURN NEXT result;
    END IF;

    -- Fail if the total copy-hold ratio is too low
    IF circ_matchpoint.total_copy_hold_ratio IS NOT NULL THEN
        SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        IF hold_ratio.total_copy_ratio IS NOT NULL AND hold_ratio.total_copy_ratio < circ_matchpoint.total_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.total_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    -- Fail if the available copy-hold ratio is too low
    IF circ_matchpoint.available_copy_hold_ratio IS NOT NULL THEN
        IF hold_ratio.hold_count IS NULL THEN
            SELECT INTO hold_ratio * FROM action.copy_related_hold_stats(match_item);
        END IF;
        IF hold_ratio.available_copy_ratio IS NOT NULL AND hold_ratio.available_copy_ratio < circ_matchpoint.available_copy_hold_ratio THEN
            result.fail_part := 'config.circ_matrix_test.available_copy_hold_ratio';
            result.success := FALSE;
            done := TRUE;
            RETURN NEXT result;
        END IF;
    END IF;

    -- Fail if the user has too many items out by defined limit sets
    FOR circ_limit_set IN SELECT ccls.* FROM config.circ_limit_set ccls
      JOIN config.circ_matrix_limit_set_map ccmlsm ON ccmlsm.limit_set = ccls.id
      WHERE ccmlsm.active AND ( ccmlsm.matchpoint = circ_matchpoint.id OR
        ( ccmlsm.matchpoint IN (SELECT * FROM unnest(result.buildrows)) AND ccmlsm.fallthrough )
        ) LOOP
            IF circ_limit_set.items_out > 0 AND NOT renewal THEN
                SELECT INTO context_org_list ARRAY_AGG(aou.id)
                  FROM actor.org_unit_full_path( circ_ou ) aou
                    JOIN actor.org_unit_type aout ON aou.ou_type = aout.id
                  WHERE aout.depth >= circ_limit_set.depth;
                IF circ_limit_set.global THEN
                    WITH RECURSIVE descendant_depth AS (
                        SELECT  ou.id,
                            ou.parent_ou
                        FROM  actor.org_unit ou
                        WHERE ou.id IN (SELECT * FROM unnest(context_org_list))
                            UNION
                        SELECT  ou.id,
                            ou.parent_ou
                        FROM  actor.org_unit ou
                            JOIN descendant_depth ot ON (ot.id = ou.parent_ou)
                    ) SELECT INTO context_org_list ARRAY_AGG(ou.id) FROM actor.org_unit ou JOIN descendant_depth USING (id);
                END IF;
                SELECT INTO items_out COUNT(DISTINCT circ.id)
                  FROM action.circulation circ
                    JOIN asset.copy copy ON (copy.id = circ.target_copy)
                    LEFT JOIN action.circulation_limit_group_map aclgm ON (circ.id = aclgm.circ)
                  WHERE circ.usr = match_user
                    AND circ.circ_lib IN (SELECT * FROM unnest(context_org_list))
                    AND circ.checkin_time IS NULL
                    AND (circ.stop_fines IN ('MAXFINES','LONGOVERDUE') OR circ.stop_fines IS NULL)
                    AND (copy.circ_modifier IN (SELECT circ_mod FROM config.circ_limit_set_circ_mod_map WHERE limit_set = circ_limit_set.id)
                        OR copy.location IN (SELECT copy_loc FROM config.circ_limit_set_copy_loc_map WHERE limit_set = circ_limit_set.id)
                        OR aclgm.limit_group IN (SELECT limit_group FROM config.circ_limit_set_group_map WHERE limit_set = circ_limit_set.id)
                    );
                IF items_out >= circ_limit_set.items_out THEN
                    result.fail_part := 'config.circ_matrix_circ_mod_test';
                    result.success := FALSE;
                    done := TRUE;
                    RETURN NEXT result;
                END IF;
            END IF;
            SELECT INTO result.limit_groups result.limit_groups || ARRAY_AGG(limit_group) FROM config.circ_limit_set_group_map WHERE limit_set = circ_limit_set.id AND NOT check_only;
    END LOOP;

    -- If we passed everything, return the successful matchpoint
    IF NOT done THEN
        RETURN NEXT result;
    END IF;

    RETURN;
END;
$func$ LANGUAGE plpgsql;



SELECT evergreen.upgrade_deps_block_check('1343', :eg_version);

ALTER TABLE actor.hours_of_operation
    ADD COLUMN dow_0_note TEXT,
    ADD COLUMN dow_1_note TEXT,
    ADD COLUMN dow_2_note TEXT,
    ADD COLUMN dow_3_note TEXT,
    ADD COLUMN dow_4_note TEXT,
    ADD COLUMN dow_5_note TEXT,
    ADD COLUMN dow_6_note TEXT;

SELECT evergreen.upgrade_deps_block_check('1344', :eg_version);

-- This function is used to help clean up facet labels. Due to quirks in
-- MARC parsing, some facet labels may be generated with periods or commas
-- at the end.  This will strip a trailing commas off all the time, and
-- periods when they don't look like they are part of initials or dotted
-- abbreviations.
--      Smith, John                 =>  no change
--      Smith, John,                =>  Smith, John
--      Smith, John.                =>  Smith, John
--      Public, John Q.             => no change
--      Public, John, Ph.D.         => no change
--      Atlanta -- Georgia -- U.S.  => no change
--      Atlanta -- Georgia.         => Atlanta, Georgia
--      The fellowship of the rings / => The fellowship of the rings
--      Some title ;                  => Some title
CREATE OR REPLACE FUNCTION metabib.trim_trailing_punctuation ( TEXT ) RETURNS TEXT AS $$
DECLARE
    result    TEXT;
    last_char TEXT;
BEGIN
    result := $1;
    last_char = substring(result from '.$');

    IF last_char = ',' THEN
        result := substring(result from '^(.*),$');

    ELSIF last_char = '.' THEN
        -- must have a single word-character following at least one non-word character
        IF substring(result from '\W\w\.$') IS NULL THEN
            result := substring(result from '^(.*)\.$');
        END IF;

    ELSIF last_char IN ('/',':',';','=') THEN -- Dangling subtitle/SoR separator
        IF substring(result from ' .$') IS NOT NULL THEN -- must have a space before last_char
            result := substring(result from '^(.*) .$');
        END IF;
    END IF;

    RETURN result;

END;
$$ language 'plpgsql';


INSERT INTO config.metabib_field_index_norm_map (field,norm,pos)
    SELECT  m.id,
            i.id,
            -1
      FROM  config.metabib_field m,
            config.index_normalizer i
      WHERE i.func = 'metabib.trim_trailing_punctuation'
            AND m.field_class='title' AND (m.browse_field OR m.facet_field OR m.display_field)
            AND NOT EXISTS (SELECT 1 FROM config.metabib_field_index_norm_map WHERE field = m.id AND norm = i.id);



SELECT evergreen.upgrade_deps_block_check('1345', :eg_version);

CREATE TABLE acq.shipment_notification (
    id              SERIAL      PRIMARY KEY,
    receiver        INT         NOT NULL REFERENCES actor.org_unit (id),
    provider        INT         NOT NULL REFERENCES acq.provider (id),
    shipper         INT         NOT NULL REFERENCES acq.provider (id),
    recv_date       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    recv_method     TEXT        NOT NULL REFERENCES acq.invoice_method (code) DEFAULT 'EDI',
    process_date    TIMESTAMPTZ,
    processed_by    INT         REFERENCES actor.usr(id) ON DELETE SET NULL,
    container_code  TEXT        NOT NULL, -- vendor-supplied super-barcode
    lading_number   TEXT,       -- informational
    note            TEXT,
    CONSTRAINT      container_code_once_per_provider UNIQUE(provider, container_code)
);

CREATE INDEX acq_asn_container_code_idx ON acq.shipment_notification (container_code);

CREATE TABLE acq.shipment_notification_entry (
    id                      SERIAL  PRIMARY KEY,
    shipment_notification   INT NOT NULL REFERENCES acq.shipment_notification (id)
                            ON DELETE CASCADE,
    lineitem                INT REFERENCES acq.lineitem (id)
                            ON UPDATE CASCADE ON DELETE SET NULL,
    item_count              INT NOT NULL -- How many items the provider shipped
);

/* TODO alter valid_message_type constraint */

ALTER TABLE acq.edi_message DROP CONSTRAINT valid_message_type;
ALTER TABLE acq.edi_message ADD CONSTRAINT valid_message_type
CHECK (
    message_type IN (
        'ORDERS',
        'ORDRSP',
        'INVOIC',
        'OSTENQ',
        'OSTRPT',
        'DESADV'
    )
);


/* UNDO

DELETE FROM acq.edi_message WHERE message_type = 'DESADV';

DELETE FROM acq.shipment_notification_entry;
DELETE FROM acq.shipment_notification;

ALTER TABLE acq.edi_message DROP CONSTRAINT valid_message_type;
ALTER TABLE acq.edi_message ADD CONSTRAINT valid_message_type
CHECK (
    message_type IN (
        'ORDERS',
        'ORDRSP',
        'INVOIC',
        'OSTENQ',
        'OSTRPT'
    )
);

DROP TABLE acq.shipment_notification_entry;
DROP TABLE acq.shipment_notification;

*/


SELECT evergreen.upgrade_deps_block_check('1346', :eg_version); 

-- insert then update for easier iterative development tweaks
INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('items_out', 'Patron Items Out', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  circulations = template_data.circulations;
%]
<div>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You have the following items:</div>
  <hr/>
  <ol>
  [% FOR checkout IN circulations %]
    <li>
      <div>[% checkout.title %]</div>
      <div>
      [% IF checkout.copy %]Barcode: [% checkout.copy.barcode %][% END %]
    Due: [% date.format(helpers.format_date(checkout.dueDate, staff_org_timezone), '%x %r') %]
      </div>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>[% staff_org.name %] [% date.format(date.now, '%x %r') %]</div>
  <div>You were helped by [% staff.first_given_name %]</div>
  <br/>
</div>
$TEMPLATE$ WHERE name = 'items_out';

UPDATE config.print_template SET active = TRUE WHERE name = 'patron_address';

-- insert then update for easier iterative development tweaks
INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('bills_current', 'Bills, Current', 1, TRUE, 'en-US', 'text/html', '');


UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET xacts = template_data.xacts;
%]
<div>
  <style>td { padding: 1px 3px 1px 3px; }</style>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You have the following bills:</div>
  <hr/>
  <ol>
  [% FOR xact IN xacts %]
    <li>
      <table>
        <tr>
          <td>Bill #:</td>
          <td>[% xact.id %]</td>
        </tr>
        <tr>
          <td>Date:</td>
          <td>[% date.format(helpers.format_date(
            xact.xact_start, staff_org_timezone), '%x %r') %]
          </td>
        </tr>
        <tr>
          <td>Last Billing:</td>
          <td>[% xact.last_billing_type %]</td>
        </tr>
        <tr>
          <td>Total Billed:</td>
          <td>[% money(xact.total_owed) %]</td>
        </tr>
        <tr>
          <td>Last Payment:</td>
          <td>
            [% xact.last_payment_type %]
            [% IF xact.last_payment_ts %]
              at [% date.format(
                    helpers.format_date(
                        xact.last_payment_ts, staff_org_timezone), '%x %r') %]
            [% END %]
          </td>
        </tr>
        <tr>
          <td>Total Paid:</td>
          <td>[% money(xact.total_paid) %]</td>
        </tr>
        <tr>
          <td>Balance:</td>
          <td>[% money(xact.balance_owed) %]</td>
        </tr>
      </table>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>[% staff_org.name %] [% date.format(date.now, '%x %r') %]</div>
  <div>You were helped by [% staff.first_given_name %]</div>
  <br/>
</div>
$TEMPLATE$ WHERE name = 'bills_current';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('bills_payment', 'Bills, Payment', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET payments = template_data.payments;
  SET previous_balance = template_data.previous_balance;
  SET new_balance = template_data.new_balance;
  SET payment_type = template_data.payment_type;
  SET payment_total = template_data.payment_total;
  SET payment_applied = template_data.payment_applied;
  SET amount_voided = template_data.amount_voided;
  SET change_given = template_data.change_given;
  SET payment_note = template_data.payment_note;
  SET copy_barcode = template_data.copy_barcode;
  SET title = template_data.title;
%]
<div>
  <style>td { padding: 1px 3px 1px 3px; }</style>
  <div>Welcome to [% staff_org.name %]</div>
  <div>A receipt of your transaction:</div>
  <hr/>

  <table style="width:100%"> 
    <tr> 
      <td>Original Balance:</td> 
      <td align="right">[% money(previous_balance) %]</td> 
    </tr> 
    <tr> 
      <td>Payment Method:</td> 
      <td align="right">
        [% SWITCH payment_type %]
          [% CASE "cash_payment" %]Cash
          [% CASE "check_payment" %]Check
          [% CASE "credit_card_payment" %]Credit Card
          [% CASE "debit_card_payment" %]Debit Card
          [% CASE "credit_payment" %]Patron Credit
          [% CASE "work_payment" %]Work
          [% CASE "forgive_payment" %]Forgive
          [% CASE "goods_payment" %]Goods
        [% END %]
      </td>
    </tr> 
    <tr> 
      <td>Payment Received:</td> 
      <td align="right">[% money(payment_total) %]</td> 
    </tr> 
    <tr> 
      <td>Payment Applied:</td> 
      <td align="right">[% money(payment_applied) %]</td> 
    </tr> 
    <tr> 
      <td>Billings Voided:</td> 
      <td align="right">[% money(amount_voided) %]</td> 
    </tr> 
    <tr> 
      <td>Change Given:</td> 
      <td align="right">[% money(change_given) %]</td> 
    </tr> 
    <tr> 
      <td>New Balance:</td> 
      <td align="right">[% money(new_balance) %]</td> 
    </tr> 
  </table> 
  <p>Note: [% payment_note %]</p>
  <p>
    Specific Bills
    <blockquote>
      [% FOR payment IN payments %]
        <table style="width:100%">
          <tr>
            <td>Bill # [% payment.xact.id %]</td>
            <td>[% payment.xact.summary.last_billing_type %]</td>
            <td>Received: [% money(payment.amount) %]</td>
          </tr>
          [% IF payment.copy_barcode %]
          <tr>
            <td colspan="5">[% payment.copy_barcode %] [% payment.title %]</td>
          </tr>
          [% END %]
        </table>
        <br/>
      [% END %]
    </blockquote>
  </p> 
  <hr/>
  <br/><br/> 
  <div>[% staff_org.name %] [% date.format(date.now, '%x %r') %]</div>
  <div>You were helped by [% staff.first_given_name %]</div>
</div>
$TEMPLATE$ WHERE name = 'bills_payment';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('patron_data', 'Patron Data', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET patron = template_data.patron;
%]
<table>
  <tr><td>Barcode:</td><td>[% patron.card.barcode %]</td></tr>
  <tr><td>Patron's Username:</td><td>[% patron.usrname %]</td></tr>
  <tr><td>Prefix/Title:</td><td>[% patron.prefix %]</td></tr>
  <tr><td>First Name:</td><td>[% patron.first_given_name %]</td></tr>
  <tr><td>Middle Name:</td><td>[% patron.second_given_name %]</td></tr>
  <tr><td>Last Name:</td><td>[% patron.family_name %]</td></tr>
  <tr><td>Suffix:</td><td>[% patron.suffix %]</td></tr>
  <tr><td>Holds Alias:</td><td>[% patron.alias %]</td></tr>
  <tr><td>Date of Birth:</td><td>[% patron.dob %]</td></tr>
  <tr><td>Juvenile:</td><td>[% patron.juvenile %]</td></tr>
  <tr><td>Primary Identification Type:</td><td>[% patron.ident_type.name %]</td></tr>
  <tr><td>Primary Identification:</td><td>[% patron.ident_value %]</td></tr>
  <tr><td>Secondary Identification Type:</td><td>[% patron.ident_type2.name %]</td></tr>
  <tr><td>Secondary Identification:</td><td>[% patron.ident_value2 %]</td></tr>
  <tr><td>Email Address:</td><td>[% patron.email %]</td></tr>
  <tr><td>Daytime Phone:</td><td>[% patron.day_phone %]</td></tr>
  <tr><td>Evening Phone:</td><td>[% patron.evening_phone %]</td></tr>
  <tr><td>Other Phone:</td><td>[% patron.other_phone %]</td></tr>
  <tr><td>Home Library:</td><td>[% patron.home_ou.name %]</td></tr>
  <tr><td>Main (Profile) Permission Group:</td><td>[% patron.profile.name %]</td></tr>
  <tr><td>Privilege Expiration Date:</td><td>[% patron.expire_date %]</td></tr>
  <tr><td>Internet Access Level:</td><td>[% patron.net_access_level.name %]</td></tr>
  <tr><td>Active:</td><td>[% patron.active %]</td></tr>
  <tr><td>Barred:</td><td>[% patron.barred %]</td></tr>
  <tr><td>Is Group Lead Account:</td><td>[% patron.master_account %]</td></tr>
  <tr><td>Claims-Returned Count:</td><td>[% patron.claims_returned_count %]</td></tr>
  <tr><td>Claims-Never-Checked-Out Count:</td><td>[% patron.claims_never_checked_out_count %]</td></tr>
  <tr><td>Alert Message:</td><td>[% patron.alert_message %]</td></tr>

  [% FOR addr IN patron.addresses %]
    <tr><td colspan="2">----------</td></tr>
    <tr><td>Type:</td><td>[% addr.address_type %]</td></tr>
    <tr><td>Street (1):</td><td>[% addr.street1 %]</td></tr>
    <tr><td>Street (2):</td><td>[% addr.street2 %]</td></tr>
    <tr><td>City:</td><td>[% addr.city %]</td></tr>
    <tr><td>County:</td><td>[% addr.county %]</td></tr>
    <tr><td>State:</td><td>[% addr.state %]</td></tr>
    <tr><td>Postal Code:</td><td>[% addr.post_code %]</td></tr>
    <tr><td>Country:</td><td>[% addr.country %]</td></tr>
    <tr><td>Valid Address?:</td><td>[% addr.valid %]</td></tr>
    <tr><td>Within City Limits?:</td><td>[% addr.within_city_limits %]</td></tr>
  [% END %]

  [% FOR entry IN patron.stat_cat_entries %]
    <tr><td>-----------</td></tr>
    <tr><td>[% entry.stat_cat.name %]</td><td>[% entry.stat_cat_entry %]</td></tr>
  [% END %]

</table>

$TEMPLATE$ WHERE name = 'patron_data';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('hold_shelf_slip', 'Hold Shelf Slip', 1, TRUE, 'en-US', 'text/html', '');


UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET copy = template_data.checkin.copy;
  SET hold = template_data.checkin.hold;
  SET volume = template_data.checkin.volume;
  SET hold = template_data.checkin.hold;
  SET record = template_data.checkin.record;
  SET patron = template_data.checkin.patron;
%] 

<div>
  [% IF hold.behind_desk == 't' %]
    This item needs to be routed to the <strong>Private Holds Shelf</strong>.
  [% ELSE %]
    This item needs to be routed to the <strong>Public Holds Shelf</strong>.
  [% END %]
</div>
<br/>

<div>Barcode: [% copy.barcode %]</div>
<div>Title: [% checkin.title %]</div>
<div>Call Number: [% volume.prefix.label %] [% volume.label %] [% volume.suffix.label %]</div>

<br/>

<div>Hold for patron: [% patron.family_name %], 
  [% patron.first_given_name %] [% patron.second_given_name %]</div>
<div>Barcode: [% patron.card.barcode %]</div>

[% IF hold.phone_notify %]
  <div>Notify by phone: [% hold.phone_notify %]</div>
[% END %]
[% IF hold.sms_notify %]
  <div>Notify by text: [% hold.sms_notify %]</div>
[% END %]
[% IF hold.email_notify %]
  <div>Notify by email: [% patron.email %]</div>
[% END %]

[% FOR note IN hold.notes %]
  <ul>
  [% IF note.slip == 't' %]
    <li><strong>[% note.title %]</strong> - [% note.body %]</li>
  [% END %]
  </ul>
[% END %]
<br/>

<div>Request Date: [% 
  date.format(helpers.format_date(hold.request_time, staff_org_timezone), '%x %r') %]</div>
<div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
<div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>

</div>

$TEMPLATE$ WHERE name = 'hold_shelf_slip';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('transit_slip', 'Transit Slip', 1, TRUE, 'en-US', 'text/html', '');


UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET checkin = template_data.checkin;
  SET copy = checkin.copy;
  SET destOrg = checkin.destOrg;
  SET destAddress = checkin.destAddress;
  SET destCourierCode = checkin.destCourierCode;
%] 
<div>
  <div>This item needs to be routed to <b>[% destOrg.shortname %]</b></div>
  <div>[% destOrg.name %]</div>
  [% IF destCourierCode %]Courier Code: [% destCourierCode %][% END %]

  [% IF destAddress %]
    <div>[% destAddress.street1 %]</div>
    <div>[% destAddress.street2 %]</div>
    <div>[% destAddress.city %],
    [% destAddress.state %]
    [% destAddress.post_code %]</div>
  [% ELSE %]
    <div>We do not have a holds address for this library.</div>
  [% END %]
  
  <br/>
  <div>Barcode: [% copy.barcode %]</div>
  <div>Title: [% checkin.title %]</div>
  <div>Author: [% checkin.author %]</div>
  
  <br/>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'transit_slip';

 
INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('hold_transit_slip', 'Hold Transit Slip', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET checkin = template_data.checkin;
  SET copy = checkin.copy;
  SET hold = checkin.hold;
  SET patron = checkin.patron;
  SET destOrg = checkin.destOrg;
  SET destAddress = checkin.destAddress;
  SET destCourierCode = checkin.destCourierCode;
%] 
<div>
  <div>This item needs to be routed to <b>[% destOrg.shortname %]</b></div>
  <div>[% destOrg.name %]</div>
  [% IF destCourierCode %]Courier Code: [% destCourierCode %][% END %]

  [% IF destAddress %]
    <div>[% destAddress.street1 %]</div>
    <div>[% destAddress.street2 %]</div>
    <div>[% destAddress.city %],
    [% destAddress.state %]
    [% destAddress.post_code %]</div>
  [% ELSE %]
    <div>We do not have a holds address for this library.</div>
  [% END %]
  
  <br/>
  <div>Barcode: [% copy.barcode %]</div>
  <div>Title: [% checkin.title %]</div>
  <div>Author: [% checkin.author %]</div>

  <br/>
  <div>Hold for patron [% patron.card.barcode %]</div>
  
  <br/>
  <div>Request Date: [% 
    date.format(helpers.format_date(hold.request_time, staff_org_timezone), '%x %r') %]
  </div>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'transit_slip';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('checkin', 'Checkin', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET checkins = template_data.checkins;
%] 

<div>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You checked in the following items:</div>
  <hr/>
  <ol>
	[% FOR checkin IN checkins %]
    <li>
      <div>[% checkin.title %]</div>
      <span>Barcode: </span>
      <span>[% checkin.copy.barcode %]</span>
      <span>Call Number: </span>
      <span>
      [% IF checkin.volume %]
	    [% volume.prefix.label %] [% volume.label %] [% volume.suffix.label %]
      [% ELSE %]
        Not Cataloged
      [% END %]
      </span>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'checkin';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('holds_for_patron', 'Holds For Patron', 1, TRUE, 'en-US', 'text/html', '');


UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET holds = template_data;
%] 

<div>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You have the following items on hold:</div>
  <hr/>
  <ol>
	[% FOR hold IN holds %]
    <li>
      <div>[% hold.title %]</div>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'holds_for_patron';


INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('bills_historical', 'Bills, Historical', 1, TRUE, 'en-US', 'text/html', '');


UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET xacts = template_data.xacts;
%]
<div>
  <style>td { padding: 1px 3px 1px 3px; }</style>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You have the following bills:</div>
  <hr/>
  <ol>
  [% FOR xact IN xacts %]
    <li>
      <table>
        <tr>
          <td>Bill #:</td>
          <td>[% xact.id %]</td>
        </tr>
        <tr>
          <td>Date:</td>
          <td>[% date.format(helpers.format_date(
            xact.xact_start, staff_org_timezone), '%x %r') %]
          </td>
        </tr>
        <tr>
          <td>Last Billing:</td>
          <td>[% xact.last_billing_type %]</td>
        </tr>
        <tr>
          <td>Total Billed:</td>
          <td>[% money(xact.total_owed) %]</td>
        </tr>
        <tr>
          <td>Last Payment:</td>
          <td>
            [% xact.last_payment_type %]
            [% IF xact.last_payment_ts %]
              at [% date.format(
                    helpers.format_date(
                        xact.last_payment_ts, staff_org_timezone), '%x %r') %]
            [% END %]
          </td>
        </tr>
        <tr>
          <td>Total Paid:</td>
          <td>[% money(xact.total_paid) %]</td>
        </tr>
        <tr>
          <td>Balance:</td>
          <td>[% money(xact.balance_owed) %]</td>
        </tr>
      </table>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>[% staff_org.name %] [% date.format(date.now, '%x %r') %]</div>
  <div>You were helped by [% staff.first_given_name %]</div>
  <br/>
</div>
$TEMPLATE$ WHERE name = 'bills_historical';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('checkout', 'Checkout', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET checkouts = template_data.checkouts;
%] 

<div>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You checked out the following items:</div>
  <hr/>
  <ol>
	[% FOR checkout IN checkouts %]
    <li>
      <div>[% checkout.title %]</div>
      <span>Barcode: </span>
      <span>[% checkout.copy.barcode %]</span>
      <span>Call Number: </span>
      <span>
      [% IF checkout.volume %]
	    [% volume.prefix.label %] [% volume.label %] [% volume.suffix.label %]
      [% ELSE %]
        Not Cataloged
      [% END %]
      </span>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'checkout';

INSERT INTO config.print_template 
    (name, label, owner, active, locale, content_type, template)
VALUES ('renew', 'renew', 1, TRUE, 'en-US', 'text/html', '');

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET renewals = template_data.renewals;
%] 

<div>
  <div>Welcome to [% staff_org.name %]</div>
  <div>You renewed the following items:</div>
  <hr/>
  <ol>
	[% FOR renewal IN renewals %]
    <li>
      <div>[% renewal.title %]</div>
      <span>Barcode: </span>
      <span>[% renewal.copy.barcode %]</span>
      <span>Call Number: </span>
      <span>
      [% IF renewal.volume %]
	    [% volume.prefix.label %] [% volume.label %] [% volume.suffix.label %]
      [% ELSE %]
        Not Cataloged
      [% END %]
      </span>
    </li>
  [% END %]
  </ol>
  <hr/>
  <div>Slip Date: [% date.format(date.now, '%x %r') %]</div>
  <div>Printed by [% staff.first_given_name %] at [% staff_org.shortname %]</div>
</div>

$TEMPLATE$ WHERE name = 'renew';

INSERT INTO config.org_unit_setting_type (name, grp, datatype, label, description)
VALUES (
    'ui.staff.angular_circ.enabled', 'gui', 'bool',
    oils_i18n_gettext(
        'ui.staff.angular_circ.enabled',
        'Enable Angular Circulation Menu',
        'coust', 'label'
    ),
    oils_i18n_gettext(
        'ui.staff.angular_circ.enabled',
        'Enable Angular Circulation Menu',
        'coust', 'description'
    )
);

INSERT INTO permission.perm_list ( id, code, description ) VALUES
 ( 640, 'ACCESS_ANGULAR_CIRC', oils_i18n_gettext(640,
    'Allow a user to access the experimental Angular circulation interfaces', 'ppl', 'description'))
;





SELECT evergreen.upgrade_deps_block_check('1347', :eg_version);   

CREATE OR REPLACE FUNCTION actor.usr_purge_data(
	src_usr  IN INTEGER,
	specified_dest_usr IN INTEGER
) RETURNS VOID AS $$
DECLARE
	suffix TEXT;
	renamable_row RECORD;
	dest_usr INTEGER;
BEGIN

	IF specified_dest_usr IS NULL THEN
		dest_usr := 1; -- Admin user on stock installs
	ELSE
		dest_usr := specified_dest_usr;
	END IF;

    -- action_trigger.event (even doing this, event_output may--and probably does--contain PII and should have a retention/removal policy)
    UPDATE action_trigger.event SET context_user = dest_usr WHERE context_user = src_usr;

	-- acq.*
	UPDATE acq.fund_allocation SET allocator = dest_usr WHERE allocator = src_usr;
	UPDATE acq.lineitem SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.lineitem SET selector = dest_usr WHERE selector = src_usr;
	UPDATE acq.lineitem_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.lineitem_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.invoice SET closed_by = dest_usr WHERE closed_by = src_usr;
	DELETE FROM acq.lineitem_usr_attr_definition WHERE usr = src_usr;

	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   acq.picklist
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  acq.picklist
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	UPDATE acq.picklist SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.picklist SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.po_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.po_note SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.purchase_order SET owner = dest_usr WHERE owner = src_usr;
	UPDATE acq.purchase_order SET creator = dest_usr WHERE creator = src_usr;
	UPDATE acq.purchase_order SET editor = dest_usr WHERE editor = src_usr;
	UPDATE acq.claim_event SET creator = dest_usr WHERE creator = src_usr;

	-- action.*
	DELETE FROM action.circulation WHERE usr = src_usr;
	UPDATE action.circulation SET circ_staff = dest_usr WHERE circ_staff = src_usr;
	UPDATE action.circulation SET checkin_staff = dest_usr WHERE checkin_staff = src_usr;
	UPDATE action.hold_notification SET notify_staff = dest_usr WHERE notify_staff = src_usr;
	UPDATE action.hold_request SET fulfillment_staff = dest_usr WHERE fulfillment_staff = src_usr;
	UPDATE action.hold_request SET requestor = dest_usr WHERE requestor = src_usr;
	DELETE FROM action.hold_request WHERE usr = src_usr;
	UPDATE action.in_house_use SET staff = dest_usr WHERE staff = src_usr;
	UPDATE action.non_cat_in_house_use SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.non_cataloged_circulation WHERE patron = src_usr;
	UPDATE action.non_cataloged_circulation SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM action.survey_response WHERE usr = src_usr;
	UPDATE action.fieldset SET owner = dest_usr WHERE owner = src_usr;
	DELETE FROM action.usr_circ_history WHERE usr = src_usr;
	UPDATE action.curbside SET notes = NULL WHERE patron = src_usr;

	-- actor.*
	DELETE FROM actor.card WHERE usr = src_usr;
	DELETE FROM actor.stat_cat_entry_usr_map WHERE target_usr = src_usr;
	DELETE FROM actor.usr_privacy_waiver WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;

	-- The following update is intended to avoid transient violations of a foreign
	-- key constraint, whereby actor.usr_address references itself.  It may not be
	-- necessary, but it does no harm.
	UPDATE actor.usr_address SET replaces = NULL
		WHERE usr = src_usr AND replaces IS NOT NULL;
	DELETE FROM actor.usr_address WHERE usr = src_usr;
	DELETE FROM actor.usr_org_unit_opt_in WHERE usr = src_usr;
	UPDATE actor.usr_org_unit_opt_in SET staff = dest_usr WHERE staff = src_usr;
	DELETE FROM actor.usr_setting WHERE usr = src_usr;
	DELETE FROM actor.usr_standing_penalty WHERE usr = src_usr;
	UPDATE actor.usr_message SET title = 'purged', message = 'purged', read_date = NOW() WHERE usr = src_usr;
	DELETE FROM actor.usr_message WHERE usr = src_usr;
	UPDATE actor.usr_standing_penalty SET staff = dest_usr WHERE staff = src_usr;
	UPDATE actor.usr_message SET editor = dest_usr WHERE editor = src_usr;

	-- asset.*
	UPDATE asset.call_number SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.call_number SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.call_number_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET creator = dest_usr WHERE creator = src_usr;
	UPDATE asset.copy SET editor = dest_usr WHERE editor = src_usr;
	UPDATE asset.copy_note SET creator = dest_usr WHERE creator = src_usr;

	-- auditor.*
	DELETE FROM auditor.actor_usr_address_history WHERE id = src_usr;
	DELETE FROM auditor.actor_usr_history WHERE id = src_usr;
	UPDATE auditor.asset_call_number_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_call_number_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.asset_copy_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.asset_copy_history SET editor  = dest_usr WHERE editor  = src_usr;
	UPDATE auditor.biblio_record_entry_history SET creator = dest_usr WHERE creator = src_usr;
	UPDATE auditor.biblio_record_entry_history SET editor  = dest_usr WHERE editor  = src_usr;

	-- biblio.*
	UPDATE biblio.record_entry SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_entry SET editor = dest_usr WHERE editor = src_usr;
	UPDATE biblio.record_note SET creator = dest_usr WHERE creator = src_usr;
	UPDATE biblio.record_note SET editor = dest_usr WHERE editor = src_usr;

	-- container.*
	-- Update buckets with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   container.biblio_record_entry_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.biblio_record_entry_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.call_number_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.call_number_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.copy_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.copy_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	FOR renamable_row in
		SELECT id, name
		FROM   container.user_bucket
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  container.user_bucket
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

	DELETE FROM container.user_bucket_item WHERE target_user = src_usr;

	-- money.*
	DELETE FROM money.billable_xact WHERE usr = src_usr;
	DELETE FROM money.collections_tracker WHERE usr = src_usr;
	UPDATE money.collections_tracker SET collector = dest_usr WHERE collector = src_usr;

	-- permission.*
	DELETE FROM permission.usr_grp_map WHERE usr = src_usr;
	DELETE FROM permission.usr_object_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_perm_map WHERE usr = src_usr;
	DELETE FROM permission.usr_work_ou_map WHERE usr = src_usr;

	-- reporter.*
	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.output_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.output_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.report SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.report_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.report_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.schedule SET runner = dest_usr WHERE runner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	BEGIN
		UPDATE reporter.template SET owner = dest_usr WHERE owner = src_usr;
	EXCEPTION WHEN undefined_table THEN
		-- do nothing
	END;

	-- Update with a rename to avoid collisions
	BEGIN
		FOR renamable_row in
			SELECT id, name
			FROM   reporter.template_folder
			WHERE  owner = src_usr
		LOOP
			suffix := ' (' || src_usr || ')';
			LOOP
				BEGIN
					UPDATE  reporter.template_folder
					SET     owner = dest_usr, name = name || suffix
					WHERE   id = renamable_row.id;
				EXCEPTION WHEN unique_violation THEN
					suffix := suffix || ' ';
					CONTINUE;
				END;
				EXIT;
			END LOOP;
		END LOOP;
	EXCEPTION WHEN undefined_table THEN
	-- do nothing
	END;

	-- vandelay.*
	-- Update with a rename to avoid collisions
	FOR renamable_row in
		SELECT id, name
		FROM   vandelay.queue
		WHERE  owner = src_usr
	LOOP
		suffix := ' (' || src_usr || ')';
		LOOP
			BEGIN
				UPDATE  vandelay.queue
				SET     owner = dest_usr, name = name || suffix
				WHERE   id = renamable_row.id;
			EXCEPTION WHEN unique_violation THEN
				suffix := suffix || ' ';
				CONTINUE;
			END;
			EXIT;
		END LOOP;
	END LOOP;

    UPDATE vandelay.session_tracker SET usr = dest_usr WHERE usr = src_usr;

    -- NULL-ify addresses last so other cleanup (e.g. circ anonymization)
    -- can access the information before deletion.
	UPDATE actor.usr SET
		active = FALSE,
		card = NULL,
		mailing_address = NULL,
		billing_address = NULL
	WHERE id = src_usr;

END;
$$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1348', :eg_version);

ALTER TABLE config.circ_matrix_matchpoint
    ADD COLUMN renew_extends_due_date BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN renew_extend_min_interval INTERVAL;


SELECT evergreen.upgrade_deps_block_check('1349', :eg_version);

UPDATE config.org_unit_setting_type
    SET label = 'Rollover encumbrances only',
        description = 'Rollover encumbrances only when doing fiscal year end.  This makes money left in the old fund disappear, modeling its return to some outside entity.'
    WHERE name = 'acq.fund.allow_rollover_without_money'
    AND label = 'Allow funds to be rolled over without bringing the money along'
    AND description = 'Allow funds to be rolled over without bringing the money along.  This makes money left in the old fund disappear, modeling its return to some outside entity.';


SELECT evergreen.upgrade_deps_block_check('1350', :eg_version);

CREATE OR REPLACE FUNCTION asset.merge_record_assets( target_record BIGINT, source_record BIGINT ) RETURNS INT AS $func$
DECLARE
    moved_objects INT := 0;
    source_cn     asset.call_number%ROWTYPE;
    target_cn     asset.call_number%ROWTYPE;
    metarec       metabib.metarecord%ROWTYPE;
    hold          action.hold_request%ROWTYPE;
    ser_rec       serial.record_entry%ROWTYPE;
    ser_sub       serial.subscription%ROWTYPE;
    acq_lineitem  acq.lineitem%ROWTYPE;
    acq_request   acq.user_request%ROWTYPE;
    booking       booking.resource_type%ROWTYPE;
    source_part   biblio.monograph_part%ROWTYPE;
    target_part   biblio.monograph_part%ROWTYPE;
    multi_home    biblio.peer_bib_copy_map%ROWTYPE;
    uri_count     INT := 0;
    counter       INT := 0;
    uri_datafield TEXT;
    uri_text      TEXT := '';
BEGIN

    -- we don't merge bib -1
    IF target_record = -1 OR source_record = -1 THEN
       RETURN 0;
    END IF;

    -- move any 856 entries on records that have at least one MARC-mapped URI entry
    SELECT  INTO uri_count COUNT(*)
      FROM  asset.uri_call_number_map m
            JOIN asset.call_number cn ON (m.call_number = cn.id)
      WHERE cn.record = source_record;

    IF uri_count > 0 THEN
        
        -- This returns more nodes than you might expect:
        -- 7 instead of 1 for an 856 with $u $y $9
        SELECT  COUNT(*) INTO counter
          FROM  oils_xpath_table(
                    'id',
                    'marc',
                    'biblio.record_entry',
                    '//*[@tag="856"]',
                    'id=' || source_record
                ) as t(i int,c text);
    
        FOR i IN 1 .. counter LOOP
            SELECT  '<datafield xmlns="http://www.loc.gov/MARC21/slim"' || 
			' tag="856"' ||
			' ind1="' || FIRST(ind1) || '"'  ||
			' ind2="' || FIRST(ind2) || '">' ||
                        STRING_AGG(
                            '<subfield code="' || subfield || '">' ||
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(data,'&','&amp;','g'),
                                    '>', '&gt;', 'g'
                                ),
                                '<', '&lt;', 'g'
                            ) || '</subfield>', ''
                        ) || '</datafield>' INTO uri_datafield
              FROM  oils_xpath_table(
                        'id',
                        'marc',
                        'biblio.record_entry',
                        '//*[@tag="856"][position()=' || i || ']/@ind1|' ||
                        '//*[@tag="856"][position()=' || i || ']/@ind2|' ||
                        '//*[@tag="856"][position()=' || i || ']/*/@code|' ||
                        '//*[@tag="856"][position()=' || i || ']/*[@code]',
                        'id=' || source_record
                    ) as t(id int,ind1 text, ind2 text,subfield text,data text);

            -- As most of the results will be NULL, protect against NULLifying
            -- the valid content that we do generate
            uri_text := uri_text || COALESCE(uri_datafield, '');
        END LOOP;

        IF uri_text <> '' THEN
            UPDATE  biblio.record_entry
              SET   marc = regexp_replace(marc,'(</[^>]*record>)', uri_text || E'\\1')
              WHERE id = target_record;
        END IF;

    END IF;

	-- Find and move metarecords to the target record
	SELECT	INTO metarec *
	  FROM	metabib.metarecord
	  WHERE	master_record = source_record;

	IF FOUND THEN
		UPDATE	metabib.metarecord
		  SET	master_record = target_record,
			mods = NULL
		  WHERE	id = metarec.id;

		moved_objects := moved_objects + 1;
	END IF;

	-- Find call numbers attached to the source ...
	FOR source_cn IN SELECT * FROM asset.call_number WHERE record = source_record LOOP

		SELECT	INTO target_cn *
		  FROM	asset.call_number
		  WHERE	label = source_cn.label
            AND prefix = source_cn.prefix
            AND suffix = source_cn.suffix
			AND owning_lib = source_cn.owning_lib
			AND record = target_record
			AND NOT deleted;

		-- ... and if there's a conflicting one on the target ...
		IF FOUND THEN

			-- ... move the copies to that, and ...
			UPDATE	asset.copy
			  SET	call_number = target_cn.id
			  WHERE	call_number = source_cn.id;

			-- ... move V holds to the move-target call number
			FOR hold IN SELECT * FROM action.hold_request WHERE target = source_cn.id AND hold_type = 'V' LOOP
		
				UPDATE	action.hold_request
				  SET	target = target_cn.id
				  WHERE	id = hold.id;
		
				moved_objects := moved_objects + 1;
			END LOOP;
        
            UPDATE asset.call_number SET deleted = TRUE WHERE id = source_cn.id;

		-- ... if not ...
		ELSE
			-- ... just move the call number to the target record
			UPDATE	asset.call_number
			  SET	record = target_record
			  WHERE	id = source_cn.id;
		END IF;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find T holds targeting the source record ...
	FOR hold IN SELECT * FROM action.hold_request WHERE target = source_record AND hold_type = 'T' LOOP

		-- ... and move them to the target record
		UPDATE	action.hold_request
		  SET	target = target_record
		  WHERE	id = hold.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find serial records targeting the source record ...
	FOR ser_rec IN SELECT * FROM serial.record_entry WHERE record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	serial.record_entry
		  SET	record = target_record
		  WHERE	id = ser_rec.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find serial subscriptions targeting the source record ...
	FOR ser_sub IN SELECT * FROM serial.subscription WHERE record_entry = source_record LOOP
		-- ... and move them to the target record
		UPDATE	serial.subscription
		  SET	record_entry = target_record
		  WHERE	id = ser_sub.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find booking resource types targeting the source record ...
	FOR booking IN SELECT * FROM booking.resource_type WHERE record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	booking.resource_type
		  SET	record = target_record
		  WHERE	id = booking.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find acq lineitems targeting the source record ...
	FOR acq_lineitem IN SELECT * FROM acq.lineitem WHERE eg_bib_id = source_record LOOP
		-- ... and move them to the target record
		UPDATE	acq.lineitem
		  SET	eg_bib_id = target_record
		  WHERE	id = acq_lineitem.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find acq user purchase requests targeting the source record ...
	FOR acq_request IN SELECT * FROM acq.user_request WHERE eg_bib = source_record LOOP
		-- ... and move them to the target record
		UPDATE	acq.user_request
		  SET	eg_bib = target_record
		  WHERE	id = acq_request.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find parts attached to the source ...
	FOR source_part IN SELECT * FROM biblio.monograph_part WHERE record = source_record LOOP

		SELECT	INTO target_part *
		  FROM	biblio.monograph_part
		  WHERE	label = source_part.label
			AND record = target_record;

		-- ... and if there's a conflicting one on the target ...
		IF FOUND THEN

			-- ... move the copy-part maps to that, and ...
			UPDATE	asset.copy_part_map
			  SET	part = target_part.id
			  WHERE	part = source_part.id;

			-- ... move P holds to the move-target part
			FOR hold IN SELECT * FROM action.hold_request WHERE target = source_part.id AND hold_type = 'P' LOOP
		
				UPDATE	action.hold_request
				  SET	target = target_part.id
				  WHERE	id = hold.id;
		
				moved_objects := moved_objects + 1;
			END LOOP;

		-- ... if not ...
		ELSE
			-- ... just move the part to the target record
			UPDATE	biblio.monograph_part
			  SET	record = target_record
			  WHERE	id = source_part.id;
		END IF;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- Find multi_home items attached to the source ...
	FOR multi_home IN SELECT * FROM biblio.peer_bib_copy_map WHERE peer_record = source_record LOOP
		-- ... and move them to the target record
		UPDATE	biblio.peer_bib_copy_map
		  SET	peer_record = target_record
		  WHERE	id = multi_home.id;

		moved_objects := moved_objects + 1;
	END LOOP;

	-- And delete mappings where the item's home bib was merged with the peer bib
	DELETE FROM biblio.peer_bib_copy_map WHERE peer_record = (
		SELECT (SELECT record FROM asset.call_number WHERE id = call_number)
		FROM asset.copy WHERE id = target_copy
	);

    -- Apply merge tracking
    UPDATE biblio.record_entry 
        SET merge_date = NOW() WHERE id = target_record;

    UPDATE biblio.record_entry
        SET merge_date = NOW(), merged_to = target_record
        WHERE id = source_record;

    -- replace book bag entries of source_record with target_record
    UPDATE container.biblio_record_entry_bucket_item
        SET target_biblio_record_entry = target_record
        WHERE bucket IN (SELECT id FROM container.biblio_record_entry_bucket WHERE btype = 'bookbag')
        AND target_biblio_record_entry = source_record;

    -- move over record notes 
    UPDATE biblio.record_note 
        SET record = target_record, value = CONCAT(value,'; note merged from ',source_record::TEXT) 
        WHERE record = source_record
        AND NOT deleted;

    -- add note to record merge 
    INSERT INTO biblio.record_note (record, value) 
        VALUES (target_record,CONCAT('record ',source_record::TEXT,' merged on ',NOW()::TEXT));

    -- Finally, "delete" the source record
    UPDATE biblio.record_entry SET active = FALSE WHERE id = source_record;
    DELETE FROM biblio.record_entry WHERE id = source_record;

	-- That's all, folks!
	RETURN moved_objects;
END;
$func$ LANGUAGE plpgsql;


SELECT evergreen.upgrade_deps_block_check('1351', :eg_version);

INSERT INTO permission.perm_list ( id, code, description )
    VALUES (
        641,
        'ADMIN_FUND_ROLLOVER',
        oils_i18n_gettext(
            641,
            'Allow a user to perform fund propagation and rollover',
            'ppl',
            'description'
        )
    );

-- ensure that permission groups that are able to
-- rollover funds can continue to do so
WITH perms_to_add AS
    (SELECT id FROM
    permission.perm_list
    WHERE code IN ('ADMIN_FUND_ROLLOVER'))
INSERT INTO permission.grp_perm_map (grp, perm, depth, grantable)
    SELECT grp, perms_to_add.id as perm, depth, grantable
        FROM perms_to_add,
        permission.grp_perm_map
        
        --- Don't add the permissions if they have already been assigned
        WHERE grp NOT IN
            (SELECT DISTINCT grp FROM permission.grp_perm_map
            INNER JOIN perms_to_add ON perm=perms_to_add.id)
            
        --- Anybody who can view resources should also see reservations
        --- at the same level
        AND perm = (
            SELECT id
                FROM permission.perm_list
                WHERE code = 'ADMIN_FUND'
        );


SELECT evergreen.upgrade_deps_block_check('1352', :eg_version);

INSERT into config.workstation_setting_type (name, grp, datatype, label)
VALUES (
    'eg.grid.admin.local.cash_reports.desk_payments', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.cash_reports.desk_payments',
        'Grid Config: admin.local.cash_reports.desk_payments',
        'cwst', 'label'
    )
), (
    'eg.grid.admin.local.cash_reports.user_payments', 'gui', 'object',
    oils_i18n_gettext(
        'eg.grid.admin.local.cash_reports.user_payments',
        'Grid Config: admin.local.cash_reports.user_payments',
        'cwst', 'label'
    )
);


SELECT evergreen.upgrade_deps_block_check('1353', :eg_version);

UPDATE config.org_unit_setting_type SET description = oils_i18n_gettext('cat.default_classification_scheme',
        'Defines the default classification scheme for new call numbers.',
        'coust', 'description')
    WHERE name = 'cat.default_classification_scheme'
    AND description =
        'Defines the default classification scheme for new call numbers: 1 = Generic; 2 = Dewey; 3 = LC';


SELECT evergreen.upgrade_deps_block_check('1355', :eg_version); 

UPDATE config.print_template SET template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET patron = template_data.patron;
%]
<table>
  <tr><td>Barcode:</td><td>[% patron.card.barcode %]</td></tr>
  <tr><td>Patron's Username:</td><td>[% patron.usrname %]</td></tr>
  <tr><td>Prefix/Title:</td><td>[% patron.prefix %]</td></tr>
  <tr><td>First Name:</td><td>[% patron.first_given_name %]</td></tr>
  <tr><td>Middle Name:</td><td>[% patron.second_given_name %]</td></tr>
  <tr><td>Last Name:</td><td>[% patron.family_name %]</td></tr>
  <tr><td>Suffix:</td><td>[% patron.suffix %]</td></tr>
  <tr><td>Holds Alias:</td><td>[% patron.alias %]</td></tr>
  <tr><td>Date of Birth:</td><td>[% patron.dob %]</td></tr>
  <tr><td>Juvenile:</td><td>[% patron.juvenile %]</td></tr>
  <tr><td>Primary Identification Type:</td><td>[% patron.ident_type.name %]</td></tr>
  <tr><td>Primary Identification:</td><td>[% patron.ident_value %]</td></tr>
  <tr><td>Secondary Identification Type:</td><td>[% patron.ident_type2.name %]</td></tr>
  <tr><td>Secondary Identification:</td><td>[% patron.ident_value2 %]</td></tr>
  <tr><td>Email Address:</td><td>[% patron.email %]</td></tr>
  <tr><td>Daytime Phone:</td><td>[% patron.day_phone %]</td></tr>
  <tr><td>Evening Phone:</td><td>[% patron.evening_phone %]</td></tr>
  <tr><td>Other Phone:</td><td>[% patron.other_phone %]</td></tr>
  <tr><td>Home Library:</td><td>[% patron.home_ou.name %]</td></tr>
  <tr><td>Main (Profile) Permission Group:</td><td>[% patron.profile.name %]</td></tr>
  <tr><td>Privilege Expiration Date:</td><td>[% patron.expire_date %]</td></tr>
  <tr><td>Internet Access Level:</td><td>[% patron.net_access_level.name %]</td></tr>
  <tr><td>Active:</td><td>[% patron.active %]</td></tr>
  <tr><td>Barred:</td><td>[% patron.barred %]</td></tr>
  <tr><td>Is Group Lead Account:</td><td>[% patron.master_account %]</td></tr>
  <tr><td>Claims-Returned Count:</td><td>[% patron.claims_returned_count %]</td></tr>
  <tr><td>Claims-Never-Checked-Out Count:</td><td>[% patron.claims_never_checked_out_count %]</td></tr>

  [% FOR addr IN patron.addresses %]
    <tr><td colspan="2">----------</td></tr>
    <tr><td>Type:</td><td>[% addr.address_type %]</td></tr>
    <tr><td>Street (1):</td><td>[% addr.street1 %]</td></tr>
    <tr><td>Street (2):</td><td>[% addr.street2 %]</td></tr>
    <tr><td>City:</td><td>[% addr.city %]</td></tr>
    <tr><td>County:</td><td>[% addr.county %]</td></tr>
    <tr><td>State:</td><td>[% addr.state %]</td></tr>
    <tr><td>Postal Code:</td><td>[% addr.post_code %]</td></tr>
    <tr><td>Country:</td><td>[% addr.country %]</td></tr>
    <tr><td>Valid Address?:</td><td>[% addr.valid %]</td></tr>
    <tr><td>Within City Limits?:</td><td>[% addr.within_city_limits %]</td></tr>
  [% END %]

  [% FOR entry IN patron.stat_cat_entries %]
    <tr><td>-----------</td></tr>
    <tr><td>[% entry.stat_cat.name %]</td><td>[% entry.stat_cat_entry %]</td></tr>
  [% END %]

</table>

$TEMPLATE$ WHERE name = 'patron_data' AND template = $TEMPLATE$
[% 
  USE date;
  USE money = format('$%.2f');
  SET patron = template_data.patron;
%]
<table>
  <tr><td>Barcode:</td><td>[% patron.card.barcode %]</td></tr>
  <tr><td>Patron's Username:</td><td>[% patron.usrname %]</td></tr>
  <tr><td>Prefix/Title:</td><td>[% patron.prefix %]</td></tr>
  <tr><td>First Name:</td><td>[% patron.first_given_name %]</td></tr>
  <tr><td>Middle Name:</td><td>[% patron.second_given_name %]</td></tr>
  <tr><td>Last Name:</td><td>[% patron.family_name %]</td></tr>
  <tr><td>Suffix:</td><td>[% patron.suffix %]</td></tr>
  <tr><td>Holds Alias:</td><td>[% patron.alias %]</td></tr>
  <tr><td>Date of Birth:</td><td>[% patron.dob %]</td></tr>
  <tr><td>Juvenile:</td><td>[% patron.juvenile %]</td></tr>
  <tr><td>Primary Identification Type:</td><td>[% patron.ident_type.name %]</td></tr>
  <tr><td>Primary Identification:</td><td>[% patron.ident_value %]</td></tr>
  <tr><td>Secondary Identification Type:</td><td>[% patron.ident_type2.name %]</td></tr>
  <tr><td>Secondary Identification:</td><td>[% patron.ident_value2 %]</td></tr>
  <tr><td>Email Address:</td><td>[% patron.email %]</td></tr>
  <tr><td>Daytime Phone:</td><td>[% patron.day_phone %]</td></tr>
  <tr><td>Evening Phone:</td><td>[% patron.evening_phone %]</td></tr>
  <tr><td>Other Phone:</td><td>[% patron.other_phone %]</td></tr>
  <tr><td>Home Library:</td><td>[% patron.home_ou.name %]</td></tr>
  <tr><td>Main (Profile) Permission Group:</td><td>[% patron.profile.name %]</td></tr>
  <tr><td>Privilege Expiration Date:</td><td>[% patron.expire_date %]</td></tr>
  <tr><td>Internet Access Level:</td><td>[% patron.net_access_level.name %]</td></tr>
  <tr><td>Active:</td><td>[% patron.active %]</td></tr>
  <tr><td>Barred:</td><td>[% patron.barred %]</td></tr>
  <tr><td>Is Group Lead Account:</td><td>[% patron.master_account %]</td></tr>
  <tr><td>Claims-Returned Count:</td><td>[% patron.claims_returned_count %]</td></tr>
  <tr><td>Claims-Never-Checked-Out Count:</td><td>[% patron.claims_never_checked_out_count %]</td></tr>
  <tr><td>Alert Message:</td><td>[% patron.alert_message %]</td></tr>

  [% FOR addr IN patron.addresses %]
    <tr><td colspan="2">----------</td></tr>
    <tr><td>Type:</td><td>[% addr.address_type %]</td></tr>
    <tr><td>Street (1):</td><td>[% addr.street1 %]</td></tr>
    <tr><td>Street (2):</td><td>[% addr.street2 %]</td></tr>
    <tr><td>City:</td><td>[% addr.city %]</td></tr>
    <tr><td>County:</td><td>[% addr.county %]</td></tr>
    <tr><td>State:</td><td>[% addr.state %]</td></tr>
    <tr><td>Postal Code:</td><td>[% addr.post_code %]</td></tr>
    <tr><td>Country:</td><td>[% addr.country %]</td></tr>
    <tr><td>Valid Address?:</td><td>[% addr.valid %]</td></tr>
    <tr><td>Within City Limits?:</td><td>[% addr.within_city_limits %]</td></tr>
  [% END %]

  [% FOR entry IN patron.stat_cat_entries %]
    <tr><td>-----------</td></tr>
    <tr><td>[% entry.stat_cat.name %]</td><td>[% entry.stat_cat_entry %]</td></tr>
  [% END %]

</table>

$TEMPLATE$;

COMMIT;

SELECT evergreen.upgrade_deps_block_check('1312', :eg_version);

CREATE INDEX aum_editor ON actor.usr_message (editor);

\qecho A partial reingest is necessary to get the full benefit of this change.
\qecho It will take a while. You can cancel now withoug losing the effect of
\qecho the rest of the upgrade script, and arrange the reingest later.
\qecho 

SELECT metabib.reingest_metabib_field_entries(
    id, TRUE, FALSE, FALSE, TRUE, 
    (SELECT ARRAY_AGG(id) FROM config.metabib_field WHERE field_class='title' AND (browse_field OR facet_field OR display_field))
) FROM biblio.record_entry;

-- Update auditor tables to catch changes to source tables.
-- Can be removed/skipped if there were no schema changes.
SELECT auditor.update_auditors();
